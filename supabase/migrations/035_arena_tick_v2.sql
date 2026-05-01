-- Migration 035: process_arena_tick() Phase B — ability effects + stacking
--
-- Replaces the Phase A function. Key changes:
--   1. Decays expired trigger effects from active_effects each tick.
--   2. Injects/updates the Conditioning passive for Athlete players.
--   3. Computes effective modifiers per player using the stacking formula:
--        trigger stacking:   Base × (1 + ln(1 + N))  where Base = geometric mean of N values
--        passive multiply:   product of passive modifier values (applied separately)
--        opponent_efficiency: multiplicative product, floored at 0.4 (60% suppression cap)
--   4. Score formula: (flow_rate × flow_mult × passive_mult × opp_eff_mult)
--                    + (heat_influence × heat_mult × heat_passive_mult)
--                    − suppression
--   5. trigger-type arena_events were inserted with processed=true by arena_trigger().
--      This loop only touches processed=false back events.
--
-- Stacking formula rationale (documented per CLAUDE.md spec):
--   N=1 Sprint: 1.35 × (1+ln(2)) ≈ 2.285×  (single use is meaningful)
--   N=2 Sprint: 1.35 × (1+ln(3)) ≈ 2.83×   (less than naive 2.7 linear)
--   The logarithm prevents exponential abuse with many stacks.
--   Passives use direct multiplication (not log stacking) because they can't
--   be triggered by users and have no meaningful "stack count" concept.
--
-- Conditioning passive:
--   Injected into active_effects each tick with effect_id='conditioning_p1'/'conditioning_p2'.
--   Old Conditioning effect is removed and re-injected with the current ramp value.
--   This ensures the modifier updates continuously without creating duplicate rows.

CREATE OR REPLACE FUNCTION public.process_arena_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_heat_weight     CONSTANT numeric  := 0.5;
  c_flow_factor     CONSTANT numeric  := 0.9;
  c_match_duration  CONSTANT interval := '5 minutes';
  c_winner_share    CONSTANT numeric  := 0.90;
  c_creator_share   CONSTANT numeric  := 0.05;
  c_opp_eff_floor   CONSTANT numeric  := 0.40;  -- 60% max suppression

  v_match           record;
  v_state           record;
  v_event           record;
  v_backer          record;

  v_p1_heat         numeric;
  v_p2_heat         numeric;
  v_heat_inf_p1     numeric;
  v_heat_inf_p2     numeric;
  v_delta_flow_p1   numeric;
  v_delta_flow_p2   numeric;
  v_idx_p1          int;
  v_idx_p2          int;
  v_new_flow_p1     numeric;
  v_new_flow_p2     numeric;
  v_new_score_p1    numeric;
  v_new_score_p2    numeric;
  v_winner_id       uuid;
  v_total_pool      numeric;
  v_winner_pool     numeric;
  v_creator_tokens  int;
  v_win_side_total  numeric;
  v_payout          int;

  -- Effect processing
  v_elapsed_secs    numeric;
  v_active_effects  jsonb;
  v_clean_effects   jsonb;
  v_effect          jsonb;
  v_cond_ramp       numeric;

  -- Effective modifiers (per player)
  -- Triggers use log stacking; passives multiply in directly.
  v_trg_flow_p1     numeric;  -- trigger log-stacked flow multiplier, P1
  v_trg_flow_p2     numeric;
  v_pas_flow_p1     numeric;  -- passive product flow multiplier, P1
  v_pas_flow_p2     numeric;
  v_trg_heat_p1     numeric;
  v_trg_heat_p2     numeric;
  v_pas_heat_p1     numeric;
  v_pas_heat_p2     numeric;
  v_opp_eff_p1      numeric;  -- opponent_efficiency on P1 (debuffs targeting P1)
  v_opp_eff_p2      numeric;
  v_supp_p1         numeric;
  v_supp_p2         numeric;
  v_momentum_p1     boolean;
  v_momentum_p2     boolean;

  v_trg_cnt         int;
  v_trg_geomean     numeric;
  v_opp_product     numeric;
  v_opp_cnt         int;

BEGIN
  -- ── a. Flip pre_match → live ─────────────────────────────────────────────────
  UPDATE public.arena_matches
  SET state        = 'live',
      actual_start = now()
  WHERE state            = 'pre_match'
    AND scheduled_start <= now();

  -- ── b. Process each live match ───────────────────────────────────────────────
  FOR v_match IN
    SELECT * FROM public.arena_matches WHERE state = 'live'
    ORDER BY actual_start ASC
  LOOP
    SELECT * INTO v_state
    FROM public.arena_state
    WHERE match_id = v_match.id;

    IF NOT FOUND THEN
      RAISE WARNING 'process_arena_tick: no arena_state for match %', v_match.id;
      CONTINUE;
    END IF;

    v_elapsed_secs := CASE
      WHEN v_match.actual_start IS NOT NULL
        THEN EXTRACT(EPOCH FROM (now() - v_match.actual_start))
      ELSE 0
    END;

    -- Heat influence
    SELECT COALESCE(MAX(heat_score), 0) INTO v_p1_heat
    FROM public.platform_metrics WHERE user_id = v_match.player_1_id;

    SELECT COALESCE(MAX(heat_score), 0) INTO v_p2_heat
    FROM public.platform_metrics WHERE user_id = v_match.player_2_id;

    v_heat_inf_p1 := v_p1_heat * c_heat_weight;
    v_heat_inf_p2 := v_p2_heat * c_heat_weight;

    -- ── Decay expired trigger effects ────────────────────────────────────────
    -- Passives have no expires_at; they survive decay and are updated below.
    v_active_effects := v_state.active_effects;
    v_clean_effects  := '[]'::jsonb;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects)
    LOOP
      IF (v_effect->>'expires_at') IS NULL  -- passive: always keep
         OR (v_effect->>'expires_at')::timestamptz > now()  -- active trigger: keep
      THEN
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
      END IF;
    END LOOP;
    v_active_effects := v_clean_effects;

    -- ── Inject / update Conditioning passive ─────────────────────────────────
    -- For each Athlete player: remove stale Conditioning row, re-inject with
    -- the current ramp value. Uses a deterministic effect_id so the UI can
    -- track it without flickering.

    IF v_match.player_1_archetype = 'athlete' THEN
      v_cond_ramp := LEAST(v_elapsed_secs / 10.0 * 0.005, 0.15);

      -- Remove previous conditioning row for P1
      v_clean_effects := '[]'::jsonb;
      FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
        IF NOT (v_effect->>'ability_id' = 'athlete:conditioning'
                AND (v_effect->>'target_player')::int = 1) THEN
          v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
        END IF;
      END LOOP;
      v_active_effects := v_clean_effects;

      -- Re-inject with current ramp (no expires_at → kept by decay filter)
      v_active_effects := v_active_effects || jsonb_build_array(jsonb_build_object(
        'effect_id',      'conditioning_p1',
        'ability_id',     'athlete:conditioning',
        'target_player',  1,
        'modifier',       'flow_rate_multiplier',
        'value',          1.0 + v_cond_ramp,
        'is_passive',     true
      ));
    END IF;

    IF v_match.player_2_archetype = 'athlete' THEN
      v_cond_ramp := LEAST(v_elapsed_secs / 10.0 * 0.005, 0.15);

      v_clean_effects := '[]'::jsonb;
      FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
        IF NOT (v_effect->>'ability_id' = 'athlete:conditioning'
                AND (v_effect->>'target_player')::int = 2) THEN
          v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
        END IF;
      END LOOP;
      v_active_effects := v_clean_effects;

      v_active_effects := v_active_effects || jsonb_build_array(jsonb_build_object(
        'effect_id',      'conditioning_p2',
        'ability_id',     'athlete:conditioning',
        'target_player',  2,
        'modifier',       'flow_rate_multiplier',
        'value',          1.0 + v_cond_ramp,
        'is_passive',     true
      ));
    END IF;

    -- ── Compute effective modifiers ───────────────────────────────────────────
    -- flow_rate_multiplier P1 — triggers (log stacking)
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)) / COUNT(*))
           END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false);

    v_trg_flow_p1 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt))
                     END;

    -- flow_rate_multiplier P1 — passives (direct product)
    SELECT COALESCE(EXP(SUM(LN((e->>'value')::numeric))), 1.0)
    INTO v_pas_flow_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND COALESCE((e->>'is_passive')::boolean, false);

    -- flow_rate_multiplier P2 — triggers
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)) / COUNT(*))
           END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false);

    v_trg_flow_p2 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt))
                     END;

    -- flow_rate_multiplier P2 — passives
    SELECT COALESCE(EXP(SUM(LN((e->>'value')::numeric))), 1.0)
    INTO v_pas_flow_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND COALESCE((e->>'is_passive')::boolean, false);

    -- heat_influence_multiplier P1 — triggers
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)) / COUNT(*))
           END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false);

    v_trg_heat_p1 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt))
                     END;

    SELECT COALESCE(EXP(SUM(LN((e->>'value')::numeric))), 1.0)
    INTO v_pas_heat_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND COALESCE((e->>'is_passive')::boolean, false);

    -- heat_influence_multiplier P2 — triggers
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)) / COUNT(*))
           END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false);

    v_trg_heat_p2 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt))
                     END;

    SELECT COALESCE(EXP(SUM(LN((e->>'value')::numeric))), 1.0)
    INTO v_pas_heat_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND COALESCE((e->>'is_passive')::boolean, false);

    -- opponent_efficiency P1 — multiplicative product with 0.4 floor (60% suppression cap)
    -- Effects with target_player=1 and modifier='opponent_efficiency' debuff P1's output.
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)))  -- product of all opp_eff values
           END
    INTO v_opp_cnt, v_opp_product
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'opponent_efficiency';

    v_opp_eff_p1 := CASE WHEN v_opp_cnt = 0 THEN 1.0
                         ELSE GREATEST(c_opp_eff_floor, v_opp_product)
                    END;

    -- opponent_efficiency P2
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN((e->>'value')::numeric)))
           END
    INTO v_opp_cnt, v_opp_product
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'opponent_efficiency';

    v_opp_eff_p2 := CASE WHEN v_opp_cnt = 0 THEN 1.0
                         ELSE GREATEST(c_opp_eff_floor, v_opp_product)
                    END;

    -- suppression_level (additive; not present in Athlete but handled for future archetypes)
    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0)
    INTO v_supp_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'suppression_level';

    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0)
    INTO v_supp_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'suppression_level';

    -- momentum_window flag (set by Game Winner; preserved across ticks once set)
    v_momentum_p1 := v_state.momentum_window_p1;
    v_momentum_p2 := v_state.momentum_window_p2;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects)
    LOOP
      IF v_effect->>'modifier' = 'momentum_window' THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
      -- Game Winner also_sets momentum_window via its metadata
      IF v_effect->>'ability_id' = 'athlete:game_winner' THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
    END LOOP;

    -- ── Accumulate BaseFlow from unprocessed back events ──────────────────────
    -- trigger events were inserted with processed=true in arena_trigger(), so
    -- this loop only sees back events.
    v_delta_flow_p1 := 0;
    v_delta_flow_p2 := 0;
    v_idx_p1        := 0;
    v_idx_p2        := 0;

    FOR v_event IN
      SELECT * FROM public.arena_events
      WHERE match_id = v_match.id AND processed = false
      ORDER BY created_at ASC
    LOOP
      IF v_event.target_id = v_match.player_1_id THEN
        v_delta_flow_p1 := v_delta_flow_p1 + v_event.value * (c_flow_factor ^ v_idx_p1);
        v_idx_p1 := v_idx_p1 + 1;
      ELSIF v_event.target_id = v_match.player_2_id THEN
        v_delta_flow_p2 := v_delta_flow_p2 + v_event.value * (c_flow_factor ^ v_idx_p2);
        v_idx_p2 := v_idx_p2 + 1;
      END IF;
    END LOOP;

    v_new_flow_p1 := v_state.flow_rate_p1 + v_delta_flow_p1;
    v_new_flow_p2 := v_state.flow_rate_p2 + v_delta_flow_p2;

    -- ── Score per tick ────────────────────────────────────────────────────────
    -- = (flow_rate × trigger_flow_mult × passive_flow_mult × opp_eff)
    --   + (heat_influence × trigger_heat_mult × passive_heat_mult)
    --   - suppression
    -- Scores floor at 0.
    v_new_score_p1 := GREATEST(0,
      v_state.score_p1
      + (v_new_flow_p1 * v_trg_flow_p1 * v_pas_flow_p1 * v_opp_eff_p1)
      + (v_heat_inf_p1 * v_trg_heat_p1 * v_pas_heat_p1)
      - v_supp_p1
    );

    v_new_score_p2 := GREATEST(0,
      v_state.score_p2
      + (v_new_flow_p2 * v_trg_flow_p2 * v_pas_flow_p2 * v_opp_eff_p2)
      + (v_heat_inf_p2 * v_trg_heat_p2 * v_pas_heat_p2)
      - v_supp_p2
    );

    -- ── Upsert arena_state ────────────────────────────────────────────────────
    UPDATE public.arena_state
    SET tick               = tick + 1,
        score_p1           = v_new_score_p1,
        score_p2           = v_new_score_p2,
        flow_rate_p1       = v_new_flow_p1,
        flow_rate_p2       = v_new_flow_p2,
        heat_influence_p1  = v_heat_inf_p1,
        heat_influence_p2  = v_heat_inf_p2,
        active_effects     = v_active_effects,
        suppression_p1     = v_supp_p1,
        suppression_p2     = v_supp_p2,
        momentum_window_p1 = v_momentum_p1,
        momentum_window_p2 = v_momentum_p2,
        updated_at         = now()
    WHERE match_id = v_match.id;

    -- Mark back events processed
    UPDATE public.arena_events
    SET processed = true
    WHERE match_id = v_match.id AND processed = false;

    -- ── c. Resolve if time is up ──────────────────────────────────────────────
    CONTINUE WHEN v_match.actual_start IS NULL;
    CONTINUE WHEN now() < v_match.actual_start + c_match_duration;

    v_winner_id := CASE
      WHEN v_new_score_p1 >= v_new_score_p2 THEN v_match.player_1_id
      ELSE v_match.player_2_id
    END;

    UPDATE public.arena_matches
    SET state          = 'resolved',
        actual_end     = now(),
        winner_id      = v_winner_id,
        final_score_p1 = v_new_score_p1,
        final_score_p2 = v_new_score_p2
    WHERE id = v_match.id;

    v_total_pool := v_state.total_pool_p1 + v_state.total_pool_p2;
    IF v_total_pool <= 0 THEN CONTINUE; END IF;

    v_win_side_total := CASE
      WHEN v_winner_id = v_match.player_1_id THEN v_state.total_pool_p1
      ELSE v_state.total_pool_p2
    END;

    v_winner_pool    := FLOOR(v_total_pool * c_winner_share);
    v_creator_tokens := FLOOR(v_total_pool * c_creator_share);

    IF v_creator_tokens > 0 THEN
      PERFORM public.increment_token_balance(v_winner_id, v_creator_tokens);
      INSERT INTO public.token_transactions
        (user_id, type, amount, reference_id, description)
      VALUES (v_winner_id, 'arena_win', v_creator_tokens, v_match.id,
              'Arena match — creator reward');
    END IF;

    IF v_win_side_total > 0 THEN
      FOR v_backer IN
        SELECT ae.user_id, SUM(ae.value) AS backed_amount
        FROM public.arena_events ae
        WHERE ae.match_id  = v_match.id
          AND ae.type      = 'back'
          AND ae.target_id = v_winner_id
        GROUP BY ae.user_id
      LOOP
        v_payout := FLOOR(v_winner_pool * (v_backer.backed_amount / v_win_side_total));
        IF v_payout > 0 THEN
          PERFORM public.increment_token_balance(v_backer.user_id, v_payout);
          INSERT INTO public.token_transactions
            (user_id, type, amount, reference_id, description)
          VALUES (v_backer.user_id, 'arena_win', v_payout, v_match.id,
                  'Arena match — backing reward');
        END IF;
      END LOOP;
    END IF;

  END LOOP;
END;
$$;
