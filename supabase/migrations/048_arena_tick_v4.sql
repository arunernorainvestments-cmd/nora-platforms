-- Migration 048: process_arena_tick() v4 — Phase D additions
--
-- Changes from v3 (migration 047):
--   1. MomentumCarry term in score formula.
--        momentum_carry_p1 = LEAST(match.momentum_score_p1_at_start × 0.3, 50)
--        Added each tick — players with high momentum have a persistent advantage.
--        Constant weight (0.3) and cap (50) are tunable post-balance pass.
--        Momentum is LOCKED at match creation (stored in arena_matches) so
--        mid-match changes to other players' momentum don't bleed in.
--   2. At match resolution:
--        a. momentum_score update: winner += round points (R1:+5, R2:+10, R3:+25);
--           loser momentum_score × 0.95 (5% decay per loss).
--        b. arena_weekly_points upsert: winner += round points (R1:+1, R2:+2, R3:+5).
--        c. arena_rating Elo update (Round 2 ONLY; K=32):
--             E_a = 1/(1+10^((R_b−R_a)/400)), delta = ROUND(32×(S−E_a)), floor=100.
--        d. arena_round3_results bracket state check (Round 3 ONLY):
--             If this was the final match of the bracket round, check whether the
--             bracket is complete and mark it as such.
--
-- All v3 logic (archetype passives, subcategory modifiers, ramping effects,
-- ability stacking, suppression resistance/immunity, telemetry) is preserved unchanged.

CREATE OR REPLACE FUNCTION public.process_arena_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- ── Phase A/B/C constants (unchanged) ─────────────────────────────────────
  c_heat_weight     CONSTANT numeric  := 0.5;
  c_flow_factor     CONSTANT numeric  := 0.9;
  c_match_duration  CONSTANT interval := '5 minutes';
  c_winner_share    CONSTANT numeric  := 0.90;
  c_creator_share   CONSTANT numeric  := 0.05;
  c_opp_eff_floor   CONSTANT numeric  := 0.40;

  -- ── Phase D constants ──────────────────────────────────────────────────────
  c_momentum_carry_weight CONSTANT numeric := 0.3;   -- tunable post-balance pass
  c_momentum_carry_max    CONSTANT numeric := 50.0;  -- cap per tick
  c_elo_k                 CONSTANT numeric := 32.0;

  v_match           record;
  v_state           record;
  v_event           record;
  v_backer          record;
  v_sub_mod         record;

  v_p1_heat         numeric;
  v_p2_heat         numeric;
  v_heat_inf_p1     numeric;
  v_heat_inf_p2     numeric;
  v_delta_flow_p1   numeric;
  v_delta_flow_p2   numeric;
  v_idx_p1          int;
  v_idx_p2          int;
  v_flow_factor_p1  numeric;
  v_flow_factor_p2  numeric;
  v_new_flow_p1     numeric;
  v_new_flow_p2     numeric;
  v_new_score_p1    numeric;
  v_new_score_p2    numeric;
  v_momentum_carry_p1 numeric;
  v_momentum_carry_p2 numeric;
  v_winner_id       uuid;
  v_total_pool      numeric;
  v_winner_pool     numeric;
  v_creator_tokens  int;
  v_win_side_total  numeric;
  v_payout          int;

  -- Effect processing
  v_elapsed_secs      numeric;
  v_active_effects    jsonb;
  v_clean_effects     jsonb;
  v_expired_effects   jsonb;
  v_effect            jsonb;
  v_ramp_pct          numeric;
  v_ramp_value        numeric;
  v_apm_count         int;
  v_network_count     int;
  v_framework_active_p1 boolean;
  v_framework_active_p2 boolean;

  -- Effective modifiers (per player)
  v_trg_flow_p1     numeric;
  v_trg_flow_p2     numeric;
  v_pas_flow_p1     numeric;
  v_pas_flow_p2     numeric;
  v_trg_heat_p1     numeric;
  v_trg_heat_p2     numeric;
  v_pas_heat_p1     numeric;
  v_pas_heat_p2     numeric;
  v_opp_eff_p1      numeric;
  v_opp_eff_p2      numeric;
  v_supp_p1         numeric;
  v_supp_p2         numeric;
  v_supp_resistance_p1 numeric;
  v_supp_resistance_p2 numeric;
  v_supp_immune_p1  boolean;
  v_supp_immune_p2  boolean;
  v_ceil_p1         numeric;
  v_ceil_p2         numeric;
  v_momentum_p1     boolean;
  v_momentum_p2     boolean;
  v_momentum_suppress_p1 boolean;
  v_momentum_suppress_p2 boolean;

  v_trg_cnt         int;
  v_trg_geomean     numeric;
  v_opp_product     numeric;
  v_opp_cnt         int;

  -- Telemetry
  v_tel_back_p1       numeric;
  v_tel_back_p2       numeric;
  v_tel_trigger_p1    numeric;
  v_tel_trigger_p2    numeric;
  v_tel_backers_p1    int;
  v_tel_backers_p2    int;
  v_tel_abilities_p1  jsonb;
  v_tel_abilities_p2  jsonb;

  -- Phase D resolution variables
  v_week_start        date;
  v_round_points      int;
  v_p1_rating         int;
  v_p2_rating         int;
  v_expected_p1       numeric;
  v_actual_p1         numeric;
  v_elo_delta         int;
  v_bracket_id        uuid;
  v_round_in_bracket  int;
  v_max_round         int;
  v_unresolved_count  int;
  v_match_count       int;

BEGIN
  -- ── a. Flip pre_match → live ─────────────────────────────────────────────
  UPDATE public.arena_matches
  SET state        = 'live',
      actual_start = now()
  WHERE state            = 'pre_match'
    AND scheduled_start <= now();

  -- ── b. Process each live match ───────────────────────────────────────────
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

    -- ── Phase D: MomentumCarry (locked at match creation) ────────────────
    v_momentum_carry_p1 := LEAST(v_match.momentum_score_p1_at_start * c_momentum_carry_weight, c_momentum_carry_max);
    v_momentum_carry_p2 := LEAST(v_match.momentum_score_p2_at_start * c_momentum_carry_weight, c_momentum_carry_max);

    -- ── Decay expired trigger effects ─────────────────────────────────────
    v_active_effects  := v_state.active_effects;
    v_expired_effects := v_state.expired_effects;
    v_clean_effects   := '[]'::jsonb;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF COALESCE((v_effect->>'is_passive')::boolean, false)
         OR (v_effect->>'source') = 'subcategory'
      THEN
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
        CONTINUE;
      END IF;

      IF (v_effect->>'expires_at') IS NULL
         OR (v_effect->>'expires_at')::timestamptz > now()
      THEN
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
      ELSE
        IF jsonb_array_length(v_expired_effects) >= 10 THEN
          v_expired_effects := (
            SELECT jsonb_agg(e) FROM (
              SELECT e FROM jsonb_array_elements(v_expired_effects) WITH ORDINALITY AS t(e, ord)
              WHERE ord < 10
            ) sub
          );
        END IF;
        v_expired_effects := jsonb_build_array(v_effect) || v_expired_effects;
      END IF;
    END LOOP;
    v_active_effects := v_clean_effects;

    -- ── Inject / update archetype passives (unchanged from v3) ───────────

    -- ATHLETE: Conditioning (ramp +0.5%/10s, cap 15%)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'athlete' THEN
        DECLARE v_ramp numeric := LEAST(v_elapsed_secs / 10.0 * 0.005, 0.15);
        BEGIN
          v_clean_effects := '[]'::jsonb;
          FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
            IF NOT (v_effect->>'ability_id' = 'athlete:conditioning'
                    AND (v_effect->>'target_player')::int = v_idx_p1) THEN
              v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
            END IF;
          END LOOP;
          v_active_effects := v_clean_effects;
          v_active_effects := v_active_effects || jsonb_build_array(jsonb_build_object(
            'effect_id',     'conditioning_p' || v_idx_p1,
            'ability_id',    'athlete:conditioning',
            'target_player', v_idx_p1,
            'modifier',      'flow_rate_multiplier',
            'value',         1.0 + v_ramp,
            'is_passive',    true
          ));
        END;
      END IF;
    END LOOP;

    -- MUSICIAN: Replay Value (+25% ability effectiveness, static)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'musician' THEN
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'musician:replay_value'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',     'replay_value_p' || v_idx_p1,
          'ability_id',    'musician:replay_value',
          'target_player', v_idx_p1,
          'modifier',      'ability_effectiveness',
          'value',         1.25,
          'is_passive',    true,
          'ability_metadata', '{"duration_multiplier": 1.25}'::jsonb
        ));
      END IF;
    END LOOP;

    -- HEALTHCARE: Stability (suppression_resistance, static)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'healthcare' THEN
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'healthcare:stability'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',      'stability_p' || v_idx_p1,
          'ability_id',     'healthcare:stability',
          'target_player',  v_idx_p1,
          'modifier',       'suppression_level',
          'value',          0.0,
          'is_passive',     true,
          'ability_metadata', '{"suppression_resistance": 0.3}'::jsonb
        ));
      END IF;
    END LOOP;

    -- PERFORMER: Crowd Reaction (deterministic jitter)
    v_framework_active_p1 := false;
    v_framework_active_p2 := false;
    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF v_effect->>'ability_id' = 'educator:framework'
         AND NOT COALESCE((v_effect->>'is_passive')::boolean, false) THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_framework_active_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_framework_active_p2 := true; END IF;
      END IF;
    END LOOP;

    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'performer' THEN
        DECLARE v_jitter_amp numeric := 0.10;
        BEGIN
          IF (v_idx_p1 = 1 AND v_framework_active_p1) OR (v_idx_p1 = 2 AND v_framework_active_p2) THEN
            v_jitter_amp := v_jitter_amp * 0.5;
          END IF;
          v_ramp_value := 1.0 + SIN(v_state.tick::numeric * 0.7) * v_jitter_amp;
          v_clean_effects := '[]'::jsonb;
          FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
            IF NOT (v_effect->>'ability_id' = 'performer:crowd_reaction'
                    AND (v_effect->>'target_player')::int = v_idx_p1) THEN
              v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
            END IF;
          END LOOP;
          v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
            'effect_id',     'crowd_reaction_p' || v_idx_p1,
            'ability_id',    'performer:crowd_reaction',
            'target_player', v_idx_p1,
            'modifier',      'flow_rate_multiplier',
            'value',         v_ramp_value,
            'is_passive',    true
          ));
        END;
      END IF;
    END LOOP;

    -- GAMER: APM Scaling (dynamic)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'gamer' THEN
        DECLARE
          v_gamer_target_id uuid := CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_id ELSE v_match.player_2_id END;
        BEGIN
          SELECT COUNT(*)::int INTO v_apm_count
          FROM public.arena_events
          WHERE match_id = v_match.id AND target_id = v_gamer_target_id
            AND created_at > now() - interval '30 seconds';
          v_ramp_value := 1.0 + LEAST(v_apm_count * 0.05, 0.50);
          v_clean_effects := '[]'::jsonb;
          FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
            IF NOT (v_effect->>'ability_id' = 'gamer:apm_scaling'
                    AND (v_effect->>'target_player')::int = v_idx_p1) THEN
              v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
            END IF;
          END LOOP;
          v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
            'effect_id',     'apm_scaling_p' || v_idx_p1,
            'ability_id',    'gamer:apm_scaling',
            'target_player', v_idx_p1,
            'modifier',      'ability_effectiveness',
            'value',         v_ramp_value,
            'is_passive',    true
          ));
        END;
      END IF;
    END LOOP;

    -- INFLUENCER: Network Effect (dynamic)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'influencer' THEN
        DECLARE
          v_inf_target_id uuid := CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_id ELSE v_match.player_2_id END;
        BEGIN
          SELECT COUNT(DISTINCT user_id)::int INTO v_network_count
          FROM public.arena_events
          WHERE match_id = v_match.id AND target_id = v_inf_target_id AND type = 'back';
          v_ramp_value := 1.0 + LEAST(v_network_count * 0.005, 0.30);
          v_clean_effects := '[]'::jsonb;
          FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
            IF NOT (v_effect->>'ability_id' = 'influencer:network_effect'
                    AND (v_effect->>'target_player')::int = v_idx_p1) THEN
              v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
            END IF;
          END LOOP;
          v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
            'effect_id',     'network_effect_p' || v_idx_p1,
            'ability_id',    'influencer:network_effect',
            'target_player', v_idx_p1,
            'modifier',      'flow_rate_multiplier',
            'value',         v_ramp_value,
            'is_passive',    true
          ));
        END;
      END IF;
    END LOOP;

    -- EDUCATOR: Efficiency (+15% flow, static)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'educator' THEN
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'educator:efficiency'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',     'efficiency_p' || v_idx_p1,
          'ability_id',    'educator:efficiency',
          'target_player', v_idx_p1,
          'modifier',      'flow_rate_multiplier',
          'value',         1.15,
          'is_passive',    true
        ));
      END IF;
    END LOOP;

    -- POLITICIAN: Influence (+10% ability effectiveness, static)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'politician' THEN
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'politician:influence'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',     'influence_p' || v_idx_p1,
          'ability_id',    'politician:influence',
          'target_player', v_idx_p1,
          'modifier',      'ability_effectiveness',
          'value',         1.1,
          'is_passive',    true
        ));
      END IF;
    END LOOP;

    -- RELIGION: Faith (time-ramp, up to +10% at 5 min)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'religion' THEN
        v_ramp_value := 1.0 + LEAST(v_elapsed_secs / 300.0 * 0.1, 0.1);
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'religion:faith'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',     'faith_p' || v_idx_p1,
          'ability_id',    'religion:faith',
          'target_player', v_idx_p1,
          'modifier',      'flow_rate_multiplier',
          'value',         v_ramp_value,
          'is_passive',    true
        ));
      END IF;
    END LOOP;

    -- BUSINESS: Leverage (decay override marker)
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'business' THEN
        v_clean_effects := '[]'::jsonb;
        FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
          IF NOT (v_effect->>'ability_id' = 'business:leverage'
                  AND (v_effect->>'target_player')::int = v_idx_p1) THEN
            v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
          END IF;
        END LOOP;
        v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
          'effect_id',      'leverage_p' || v_idx_p1,
          'ability_id',     'business:leverage',
          'target_player',  v_idx_p1,
          'modifier',       'flow_rate_multiplier',
          'value',          1.0,
          'is_passive',     true,
          'ability_metadata', '{"decay_factor_override": 0.95}'::jsonb
        ));
      END IF;
    END LOOP;

    -- Inject subcategory modifiers
    FOR v_idx_p1 IN 1..2 LOOP
      DECLARE
        v_sub text := CASE WHEN v_idx_p1 = 1 THEN v_match.subcategory_p1 ELSE v_match.subcategory_p2 END;
      BEGIN
        IF v_sub IS NOT NULL THEN
          SELECT * INTO v_sub_mod FROM public.arena_subcategory_modifiers WHERE subcategory = v_sub;
          IF FOUND THEN
            v_clean_effects := '[]'::jsonb;
            FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
              IF NOT ((v_effect->>'source') = 'subcategory'
                      AND (v_effect->>'target_player')::int = v_idx_p1) THEN
                v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
              END IF;
            END LOOP;
            v_active_effects := v_clean_effects || jsonb_build_array(jsonb_build_object(
              'effect_id',     'subcategory_p' || v_idx_p1,
              'ability_id',    'subcategory:' || v_sub,
              'target_player', v_idx_p1,
              'modifier',      v_sub_mod.modifier,
              'value',         v_sub_mod.modifier_value,
              'is_passive',    true,
              'source',        'subcategory'
            ));
          END IF;
        END IF;
      END;
    END LOOP;

    -- Handle ramping effects (unchanged from v3)
    v_clean_effects := '[]'::jsonb;
    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF (v_effect->'ability_metadata'->'ramp') IS NOT NULL
         AND NOT COALESCE((v_effect->>'is_passive')::boolean, false)
         AND (v_effect->>'expires_at') IS NOT NULL
         AND (v_effect->>'expires_at')::timestamptz > now()
      THEN
        DECLARE
          v_ramp_start    numeric;
          v_ramp_end      numeric;
          v_total_dur     numeric;
          v_age_sec       numeric;
          v_ramp_frac     numeric;
          v_updated_eff   jsonb;
        BEGIN
          v_ramp_start := (v_effect->'ability_metadata'->'ramp'->>'start')::numeric;
          v_ramp_end   := (v_effect->'ability_metadata'->'ramp'->>'end')::numeric;
          v_total_dur  := COALESCE((v_effect->>'original_duration_secs')::numeric, 10.0);
          v_age_sec    := EXTRACT(EPOCH FROM (now() - (v_effect->>'expires_at')::timestamptz + (v_total_dur || ' seconds')::interval));
          v_ramp_frac  := LEAST(GREATEST(v_age_sec / v_total_dur, 0.0), 1.0);
          v_ramp_value := v_ramp_start + (v_ramp_end - v_ramp_start) * v_ramp_frac;
          v_updated_eff := v_effect || jsonb_build_object('value', v_ramp_value);
          v_clean_effects := v_clean_effects || jsonb_build_array(v_updated_eff);
        END;
      ELSE
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
      END IF;
    END LOOP;
    v_active_effects := v_clean_effects;

    -- ── Compute effective modifiers (unchanged from v3) ───────────────────
    v_supp_resistance_p1   := 0.0;
    v_supp_resistance_p2   := 0.0;
    v_supp_immune_p1       := false;
    v_supp_immune_p2       := false;
    v_ceil_p1              := NULL;
    v_ceil_p2              := NULL;
    v_momentum_suppress_p1 := false;
    v_momentum_suppress_p2 := false;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF (v_effect->>'activates_at') IS NOT NULL
         AND (v_effect->>'activates_at')::timestamptz > now() THEN
        CONTINUE;
      END IF;
      IF (v_effect->'ability_metadata'->>'suppression_resistance') IS NOT NULL THEN
        IF (v_effect->>'target_player')::int = 1 THEN
          v_supp_resistance_p1 := GREATEST(v_supp_resistance_p1,
            (v_effect->'ability_metadata'->>'suppression_resistance')::numeric);
        ELSE
          v_supp_resistance_p2 := GREATEST(v_supp_resistance_p2,
            (v_effect->'ability_metadata'->>'suppression_resistance')::numeric);
        END IF;
      END IF;
      IF COALESCE((v_effect->'ability_metadata'->>'suppression_immunity')::boolean, false) THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_supp_immune_p1 := true;
        ELSE v_supp_immune_p2 := true; END IF;
      END IF;
      IF v_effect->>'modifier' = 'flow_rate_ceiling' THEN
        IF (v_effect->>'target_player')::int = 1 THEN
          v_ceil_p1 := (v_effect->'ability_metadata'->>'ceiling_value')::numeric;
        ELSE
          v_ceil_p2 := (v_effect->'ability_metadata'->>'ceiling_value')::numeric;
        END IF;
      END IF;
      IF v_effect->>'modifier' = 'momentum_window'
         AND (v_effect->>'value')::numeric = 0.0
         AND COALESCE((v_effect->'ability_metadata'->>'suppresses_momentum')::boolean, false) THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_suppress_p1 := true;
        ELSE v_momentum_suppress_p2 := true; END IF;
      END IF;
    END LOOP;

    -- flow_rate_multiplier P1 — triggers (log stacking)
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001))) / COUNT(*)) END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false)
      AND (e->>'source') IS DISTINCT FROM 'subcategory'
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_trg_flow_p1 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt)) END;

    SELECT COALESCE(EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))), 1.0)
    INTO v_pas_flow_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND (COALESCE((e->>'is_passive')::boolean, false) OR (e->>'source') = 'subcategory')
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    -- flow_rate_multiplier P2 — triggers
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001))) / COUNT(*)) END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false)
      AND (e->>'source') IS DISTINCT FROM 'subcategory'
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_trg_flow_p2 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt)) END;

    SELECT COALESCE(EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))), 1.0)
    INTO v_pas_flow_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'flow_rate_multiplier'
      AND (COALESCE((e->>'is_passive')::boolean, false) OR (e->>'source') = 'subcategory')
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    -- heat_influence_multiplier P1
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001))) / COUNT(*)) END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false)
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_trg_heat_p1 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt)) END;
    SELECT COALESCE(EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))), 1.0)
    INTO v_pas_heat_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND (COALESCE((e->>'is_passive')::boolean, false) OR (e->>'source') = 'subcategory')
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    -- heat_influence_multiplier P2
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001))) / COUNT(*)) END
    INTO v_trg_cnt, v_trg_geomean
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND NOT COALESCE((e->>'is_passive')::boolean, false)
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_trg_heat_p2 := CASE WHEN v_trg_cnt = 0 THEN 1.0
                          ELSE v_trg_geomean * (1.0 + LN(1.0 + v_trg_cnt)) END;
    SELECT COALESCE(EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))), 1.0)
    INTO v_pas_heat_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'heat_influence_multiplier'
      AND (COALESCE((e->>'is_passive')::boolean, false) OR (e->>'source') = 'subcategory')
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    -- opponent_efficiency P1
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))) END
    INTO v_opp_cnt, v_opp_product
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'opponent_efficiency'
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_opp_eff_p1 := CASE WHEN v_opp_cnt = 0 THEN 1.0
                         ELSE GREATEST(c_opp_eff_floor, v_opp_product) END;

    -- opponent_efficiency P2
    SELECT COUNT(*)::int,
           CASE WHEN COUNT(*) = 0 THEN 1.0
                ELSE EXP(SUM(LN(GREATEST((e->>'value')::numeric, 0.001)))) END
    INTO v_opp_cnt, v_opp_product
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'opponent_efficiency'
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    v_opp_eff_p2 := CASE WHEN v_opp_cnt = 0 THEN 1.0
                         ELSE GREATEST(c_opp_eff_floor, v_opp_product) END;

    -- suppression_level
    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0) INTO v_supp_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1 AND e->>'modifier' = 'suppression_level'
      AND (e->>'value')::numeric > 0
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);
    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0) INTO v_supp_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2 AND e->>'modifier' = 'suppression_level'
      AND (e->>'value')::numeric > 0
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    IF v_supp_immune_p1 THEN v_supp_p1 := 0.0; END IF;
    IF v_supp_immune_p2 THEN v_supp_p2 := 0.0; END IF;
    IF v_supp_resistance_p1 > 0 THEN v_supp_p1 := GREATEST(0.0, v_supp_p1 * (1.0 - v_supp_resistance_p1)); END IF;
    IF v_supp_resistance_p2 > 0 THEN v_supp_p2 := GREATEST(0.0, v_supp_p2 * (1.0 - v_supp_resistance_p2)); END IF;

    v_momentum_p1 := v_state.momentum_window_p1;
    v_momentum_p2 := v_state.momentum_window_p2;
    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF v_effect->>'modifier' = 'momentum_window' AND (v_effect->>'value')::numeric > 0 THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
      IF v_effect->>'ability_id' = 'athlete:game_winner' THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
    END LOOP;
    IF v_momentum_suppress_p1 THEN v_momentum_p1 := false; END IF;
    IF v_momentum_suppress_p2 THEN v_momentum_p2 := false; END IF;

    -- ── Accumulate BaseFlow (Business:Leverage uses 0.95 decay) ──────────
    v_flow_factor_p1 := CASE WHEN v_match.player_1_archetype = 'business' THEN 0.95 ELSE c_flow_factor END;
    v_flow_factor_p2 := CASE WHEN v_match.player_2_archetype = 'business' THEN 0.95 ELSE c_flow_factor END;

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
        v_delta_flow_p1 := v_delta_flow_p1 + v_event.value * (v_flow_factor_p1 ^ v_idx_p1);
        v_idx_p1 := v_idx_p1 + 1;
      ELSIF v_event.target_id = v_match.player_2_id THEN
        v_delta_flow_p2 := v_delta_flow_p2 + v_event.value * (v_flow_factor_p2 ^ v_idx_p2);
        v_idx_p2 := v_idx_p2 + 1;
      END IF;
    END LOOP;

    v_new_flow_p1 := v_state.flow_rate_p1 + v_delta_flow_p1;
    v_new_flow_p2 := v_state.flow_rate_p2 + v_delta_flow_p2;

    IF v_ceil_p1 IS NOT NULL THEN v_new_flow_p1 := LEAST(v_new_flow_p1, v_ceil_p1); END IF;
    IF v_ceil_p2 IS NOT NULL THEN v_new_flow_p2 := LEAST(v_new_flow_p2, v_ceil_p2); END IF;

    -- ── Score per tick (Phase D: includes MomentumCarry) ─────────────────
    v_new_score_p1 := GREATEST(0,
      v_state.score_p1
      + (v_new_flow_p1 * v_trg_flow_p1 * v_pas_flow_p1 * v_opp_eff_p1)
      + (v_heat_inf_p1 * v_trg_heat_p1 * v_pas_heat_p1)
      + v_momentum_carry_p1
      - v_supp_p1
    );

    v_new_score_p2 := GREATEST(0,
      v_state.score_p2
      + (v_new_flow_p2 * v_trg_flow_p2 * v_pas_flow_p2 * v_opp_eff_p2)
      + (v_heat_inf_p2 * v_trg_heat_p2 * v_pas_heat_p2)
      + v_momentum_carry_p2
      - v_supp_p2
    );

    -- ── Upsert arena_state ────────────────────────────────────────────────
    UPDATE public.arena_state
    SET tick               = tick + 1,
        score_p1           = v_new_score_p1,
        score_p2           = v_new_score_p2,
        flow_rate_p1       = v_new_flow_p1,
        flow_rate_p2       = v_new_flow_p2,
        heat_influence_p1  = v_heat_inf_p1,
        heat_influence_p2  = v_heat_inf_p2,
        active_effects     = v_active_effects,
        expired_effects    = v_expired_effects,
        suppression_p1     = v_supp_p1,
        suppression_p2     = v_supp_p2,
        momentum_window_p1 = v_momentum_p1,
        momentum_window_p2 = v_momentum_p2,
        updated_at         = now()
    WHERE match_id = v_match.id;

    UPDATE public.arena_events
    SET processed = true
    WHERE match_id = v_match.id AND processed = false;

    -- ── c. Resolve if time is up ──────────────────────────────────────────
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

    -- ── Write telemetry (unchanged from v3) ───────────────────────────────
    SELECT COALESCE(SUM(CASE WHEN target_id = v_match.player_1_id AND type = 'back' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_2_id AND type = 'back' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_1_id AND type = 'trigger' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_2_id AND type = 'trigger' THEN value ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN target_id = v_match.player_1_id AND type = 'back' THEN user_id END)::int,
           COUNT(DISTINCT CASE WHEN target_id = v_match.player_2_id AND type = 'back' THEN user_id END)::int
    INTO v_tel_back_p1, v_tel_back_p2,
         v_tel_trigger_p1, v_tel_trigger_p2,
         v_tel_backers_p1, v_tel_backers_p2
    FROM public.arena_events WHERE match_id = v_match.id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('ability_id', ability_id, 'count', cnt, 'total_cost', total_cost)), '[]'::jsonb)
    INTO v_tel_abilities_p1
    FROM (
      SELECT au.ability_id, COUNT(*)::int AS cnt, SUM(COALESCE(ae.value, 0)) AS total_cost
      FROM public.arena_ability_uses au
      LEFT JOIN public.arena_events ae ON ae.match_id = au.match_id AND ae.user_id = au.user_id
        AND ae.type = 'trigger' AND (ae.metadata->>'ability_id') = au.ability_id
      WHERE au.match_id = v_match.id AND au.target_id = v_match.player_1_id
      GROUP BY au.ability_id
    ) sub;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('ability_id', ability_id, 'count', cnt, 'total_cost', total_cost)), '[]'::jsonb)
    INTO v_tel_abilities_p2
    FROM (
      SELECT au.ability_id, COUNT(*)::int AS cnt, SUM(COALESCE(ae.value, 0)) AS total_cost
      FROM public.arena_ability_uses au
      LEFT JOIN public.arena_events ae ON ae.match_id = au.match_id AND ae.user_id = au.user_id
        AND ae.type = 'trigger' AND (ae.metadata->>'ability_id') = au.ability_id
      WHERE au.match_id = v_match.id AND au.target_id = v_match.player_2_id
      GROUP BY au.ability_id
    ) sub;

    INSERT INTO public.arena_match_telemetry (
      match_id, archetype_p1, archetype_p2, subcategory_p1, subcategory_p2,
      total_back_p1, total_back_p2, total_trigger_p1, total_trigger_p2,
      unique_backers_p1, unique_backers_p2,
      abilities_used_p1, abilities_used_p2,
      final_score_p1, final_score_p2, winner_archetype
    ) VALUES (
      v_match.id,
      v_match.player_1_archetype, v_match.player_2_archetype,
      v_match.subcategory_p1, v_match.subcategory_p2,
      v_tel_back_p1, v_tel_back_p2, v_tel_trigger_p1, v_tel_trigger_p2,
      v_tel_backers_p1, v_tel_backers_p2,
      v_tel_abilities_p1, v_tel_abilities_p2,
      v_new_score_p1, v_new_score_p2,
      CASE WHEN v_winner_id = v_match.player_1_id THEN v_match.player_1_archetype
           ELSE v_match.player_2_archetype END
    ) ON CONFLICT (match_id) DO NOTHING;

    -- ── Token payouts (unchanged from v3) ─────────────────────────────────
    v_total_pool := v_state.total_pool_p1 + v_state.total_pool_p2;

    IF v_total_pool > 0 THEN
      v_win_side_total := CASE
        WHEN v_winner_id = v_match.player_1_id THEN v_state.total_pool_p1
        ELSE v_state.total_pool_p2
      END;

      v_winner_pool    := FLOOR(v_total_pool * c_winner_share);
      v_creator_tokens := FLOOR(v_total_pool * c_creator_share);

      IF v_creator_tokens > 0 THEN
        PERFORM public.increment_token_balance(v_winner_id, v_creator_tokens);
        INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
        VALUES (v_winner_id, 'arena_win', v_creator_tokens, v_match.id, 'Arena match — creator reward');
      END IF;

      IF v_win_side_total > 0 THEN
        FOR v_backer IN
          SELECT ae.user_id, SUM(ae.value) AS backed_amount
          FROM public.arena_events ae
          WHERE ae.match_id = v_match.id AND ae.type = 'back' AND ae.target_id = v_winner_id
          GROUP BY ae.user_id
        LOOP
          v_payout := FLOOR(v_winner_pool * (v_backer.backed_amount / v_win_side_total));
          IF v_payout > 0 THEN
            PERFORM public.increment_token_balance(v_backer.user_id, v_payout);
            INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
            VALUES (v_backer.user_id, 'arena_win', v_payout, v_match.id, 'Arena match — backing reward');
          END IF;
        END LOOP;
      END IF;
    END IF;

    -- ── Phase D: momentum_score updates ───────────────────────────────────
    -- Winner gains round-based points; loser decays 5%.
    v_round_points := CASE v_match.round WHEN 1 THEN 5 WHEN 2 THEN 10 WHEN 3 THEN 25 ELSE 5 END;

    UPDATE public.platform_metrics
    SET momentum_score = momentum_score + v_round_points
    WHERE user_id = v_winner_id;

    UPDATE public.platform_metrics
    SET momentum_score = GREATEST(0, momentum_score * 0.95)
    WHERE user_id != v_winner_id
      AND user_id IN (v_match.player_1_id, v_match.player_2_id);

    -- ── Phase D: arena_weekly_points upsert ───────────────────────────────
    v_week_start := date_trunc('week', now() AT TIME ZONE 'UTC')::date;

    INSERT INTO public.arena_weekly_points (user_id, week_start, points)
    VALUES (
      v_winner_id,
      v_week_start,
      CASE v_match.round WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 3 THEN 5 ELSE 1 END
    )
    ON CONFLICT (user_id, week_start) DO UPDATE
    SET points       = arena_weekly_points.points + EXCLUDED.points,
        last_updated = now();

    -- ── Phase D: Elo rating update (Round 2 only) ─────────────────────────
    IF v_match.round = 2 THEN
      SELECT COALESCE(MAX(arena_rating), 1000) INTO v_p1_rating
      FROM public.platform_metrics WHERE user_id = v_match.player_1_id;

      SELECT COALESCE(MAX(arena_rating), 1000) INTO v_p2_rating
      FROM public.platform_metrics WHERE user_id = v_match.player_2_id;

      v_expected_p1 := 1.0 / (1.0 + POWER(10.0, (v_p2_rating::numeric - v_p1_rating::numeric) / 400.0));
      v_actual_p1   := CASE WHEN v_winner_id = v_match.player_1_id THEN 1.0 ELSE 0.0 END;
      v_elo_delta   := ROUND(c_elo_k * (v_actual_p1 - v_expected_p1))::int;

      UPDATE public.platform_metrics
      SET arena_rating = GREATEST(100, arena_rating + v_elo_delta)
      WHERE user_id = v_match.player_1_id;

      UPDATE public.platform_metrics
      SET arena_rating = GREATEST(100, arena_rating - v_elo_delta)
      WHERE user_id = v_match.player_2_id;
    END IF;

    -- ── Phase D: Round 3 bracket completion check ─────────────────────────
    IF v_match.round = 3 THEN
      SELECT r.bracket_id, r.round_in_bracket
      INTO v_bracket_id, v_round_in_bracket
      FROM public.arena_round3_results r
      WHERE r.match_id = v_match.id
      LIMIT 1;

      IF v_bracket_id IS NOT NULL THEN
        -- Highest round_in_bracket for this bracket
        SELECT COALESCE(MAX(round_in_bracket), 0)
        INTO v_max_round
        FROM public.arena_round3_results
        WHERE bracket_id = v_bracket_id;

        -- Is this the highest round AND do all matches in it resolve?
        IF v_round_in_bracket = v_max_round THEN
          SELECT COUNT(*) INTO v_unresolved_count
          FROM public.arena_round3_results r2
          JOIN public.arena_matches am ON am.id = r2.match_id
          WHERE r2.bracket_id = v_bracket_id
            AND r2.round_in_bracket = v_max_round
            AND am.state != 'resolved';

          -- If exactly 1 match in this round and now it's resolved: that was the final
          SELECT COUNT(*) INTO v_match_count
          FROM public.arena_round3_results
          WHERE bracket_id = v_bracket_id
            AND round_in_bracket = v_max_round;

          IF v_unresolved_count = 0 AND v_match_count = 1 THEN
            UPDATE public.arena_round3_brackets
            SET state = 'completed', completed_at = now()
            WHERE id = v_bracket_id;
          END IF;
        END IF;
      END IF;
    END IF;

  END LOOP;
END;
$$;
