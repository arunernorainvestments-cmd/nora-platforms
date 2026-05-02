-- Migration 047: process_arena_tick() v3 — Phase C full archetype support
--
-- Changes from v2:
--   1. Generic passive injection framework for all 10 archetypes
--   2. Subcategory modifier injection (from arena_subcategory_modifiers)
--   3. Special modifier handling:
--        flow_rate_ceiling      — Business:Monopoly (clamps opponent delta_flow)
--        suppression_resistance — Healthcare:Stability (reduces v_supp post-sum)
--        suppression_immunity   — Healthcare:Stabilize (zeroes v_supp entirely)
--        ramping effects        — Religion:Prayer, Performer:Standing Ovation
--        activates_at           — Business:Invest (skip if not yet active)
--        momentum suppression   — Healthcare:Critical Intervention (value=0 disables)
--   4. expired_effects tracking (prepend decayed trigger effects for Religion:Revival)
--   5. Business:Leverage decay constant override (0.95 vs default 0.9)
--   6. Educator:Framework jitter dampening on Performer crowd_reaction
--   7. Dynamic passives: Gamer:APM Scaling, Influencer:Network Effect
--   8. Match telemetry write at resolution
--
-- Stacking rules (unchanged):
--   Trigger effects:    Base × (1 + ln(1 + N)) where Base = geometric mean
--   Passive effects:    Product of all passive modifier values
--   opponent_efficiency: Product with 0.4 floor (60% suppression cap)
--   suppression_level:   Sum, then adjusted for resistance/immunity passives

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
  c_opp_eff_floor   CONSTANT numeric  := 0.40;

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
  v_effect_age_secs   numeric;
  v_apm_count         int;
  v_network_count     int;
  v_jitter_dampen     boolean;
  v_jitter_amplitude  numeric;
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
  v_ceil_p1         numeric;  -- flow_rate_ceiling on P1 (cap on P1's accumulated flow)
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

    -- ── Decay expired trigger effects ─────────────────────────────────────
    -- Passives (is_passive=true OR no expires_at) are kept.
    -- Subcategory passives (source='subcategory') are kept.
    -- Trigger effects that have expired are moved to expired_effects for Revival.
    -- Scheduled effects (activates_at in future) are kept but not applied yet.
    v_active_effects  := v_state.active_effects;
    v_expired_effects := v_state.expired_effects;
    v_clean_effects   := '[]'::jsonb;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      -- Always keep passives and subcategory modifiers
      IF COALESCE((v_effect->>'is_passive')::boolean, false)
         OR (v_effect->>'source') = 'subcategory'
      THEN
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
        CONTINUE;
      END IF;

      -- Keep if not expired
      IF (v_effect->>'expires_at') IS NULL
         OR (v_effect->>'expires_at')::timestamptz > now()
      THEN
        v_clean_effects := v_clean_effects || jsonb_build_array(v_effect);
      ELSE
        -- Moved to expired_effects (cap at 10 entries, most recent first)
        IF jsonb_array_length(v_expired_effects) >= 10 THEN
          -- Trim last entry
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

    -- ── Inject / update archetype passives ───────────────────────────────
    -- Each archetype's passive is removed and re-injected every tick with the
    -- current computed value (some are static, some dynamic).
    -- Effect_id uses a deterministic string so the UI can track without flicker.

    -- Helper: removes existing passive entries for a given ability_id + target_player
    -- then injects the new value.

    -- ── ATHLETE: Conditioning (ramp +0.5%/10s, cap 15%) ─────────────────
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

    -- ── MUSICIAN: Replay Value (+25% ability effectiveness, static) ───────
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

    -- ── HEALTHCARE: Stability (suppression_resistance, static) ───────────
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

    -- ── PERFORMER: Crowd Reaction (deterministic jitter each tick) ────────
    -- Check if Educator:Framework is active on this side (dampens jitter by 50%)
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
        v_jitter_amplitude := 0.10;
        IF (v_idx_p1 = 1 AND v_framework_active_p1)
           OR (v_idx_p1 = 2 AND v_framework_active_p2) THEN
          v_jitter_amplitude := v_jitter_amplitude * 0.5;  -- Framework dampens jitter
        END IF;
        -- Deterministic jitter: sin(tick * 0.7) in [-1, 1]
        v_ramp_value := 1.0 + SIN(v_state.tick::numeric * 0.7) * v_jitter_amplitude;

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
      END IF;
    END LOOP;

    -- ── GAMER: APM Scaling (dynamic — reads recent event count) ──────────
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'gamer' THEN
        DECLARE
          v_gamer_target_id uuid := CASE WHEN v_idx_p1 = 1
                                         THEN v_match.player_1_id
                                         ELSE v_match.player_2_id END;
        BEGIN
          SELECT COUNT(*)::int INTO v_apm_count
          FROM public.arena_events
          WHERE match_id  = v_match.id
            AND target_id = v_gamer_target_id
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

    -- ── INFLUENCER: Network Effect (dynamic — distinct backer count) ──────
    FOR v_idx_p1 IN 1..2 LOOP
      IF (CASE WHEN v_idx_p1 = 1 THEN v_match.player_1_archetype ELSE v_match.player_2_archetype END) = 'influencer' THEN
        DECLARE
          v_inf_target_id uuid := CASE WHEN v_idx_p1 = 1
                                       THEN v_match.player_1_id
                                       ELSE v_match.player_2_id END;
        BEGIN
          SELECT COUNT(DISTINCT user_id)::int INTO v_network_count
          FROM public.arena_events
          WHERE match_id  = v_match.id
            AND target_id = v_inf_target_id
            AND type      = 'back';

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

    -- ── EDUCATOR: Efficiency (+15% flow, static) ─────────────────────────
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

    -- ── POLITICIAN: Influence (+10% ability effectiveness, static) ────────
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

    -- ── RELIGION: Faith (time-ramp, up to +10% at 5 min) ─────────────────
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

    -- ── BUSINESS: Leverage (decay override, passive flag only) ────────────
    -- The actual mechanic is in the back-event accumulation loop below.
    -- We inject a passive marker so the UI can show it's active.
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

    -- ── Inject subcategory modifiers ─────────────────────────────────────
    -- Injected once at match start and re-injected each tick (idempotent by effect_id).
    -- source='subcategory' prevents decay removal.

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

    -- ── Handle ramping effects (interpolate value based on effect age) ────
    -- Effects with metadata.ramp = {start, end} get their value updated each tick.
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

    -- ── Compute effective modifiers ────────────────────────────────────────
    -- Collect special modifier flags before the stacking computations.
    v_supp_resistance_p1    := 0.0;
    v_supp_resistance_p2    := 0.0;
    v_supp_immune_p1        := false;
    v_supp_immune_p2        := false;
    v_ceil_p1               := NULL;
    v_ceil_p2               := NULL;
    v_momentum_suppress_p1  := false;
    v_momentum_suppress_p2  := false;

    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      -- Skip scheduled effects not yet active
      IF (v_effect->>'activates_at') IS NOT NULL
         AND (v_effect->>'activates_at')::timestamptz > now() THEN
        CONTINUE;
      END IF;

      -- Suppression resistance (Healthcare:Stability passive)
      IF (v_effect->'ability_metadata'->>'suppression_resistance') IS NOT NULL THEN
        IF (v_effect->>'target_player')::int = 1 THEN
          v_supp_resistance_p1 := GREATEST(v_supp_resistance_p1,
            (v_effect->'ability_metadata'->>'suppression_resistance')::numeric);
        ELSE
          v_supp_resistance_p2 := GREATEST(v_supp_resistance_p2,
            (v_effect->'ability_metadata'->>'suppression_resistance')::numeric);
        END IF;
      END IF;

      -- Suppression immunity (Healthcare:Stabilize)
      IF COALESCE((v_effect->'ability_metadata'->>'suppression_immunity')::boolean, false) THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_supp_immune_p1 := true;
        ELSE v_supp_immune_p2 := true; END IF;
      END IF;

      -- Flow rate ceiling (Business:Monopoly)
      IF v_effect->>'modifier' = 'flow_rate_ceiling' THEN
        IF (v_effect->>'target_player')::int = 1 THEN
          v_ceil_p1 := (v_effect->'ability_metadata'->>'ceiling_value')::numeric;
        ELSE
          v_ceil_p2 := (v_effect->'ability_metadata'->>'ceiling_value')::numeric;
        END IF;
      END IF;

      -- Momentum suppression (Healthcare:Critical Intervention, value=0 on opponent)
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

    -- heat_influence_multiplier P1 — triggers
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

    -- heat_influence_multiplier P2 — triggers
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

    -- opponent_efficiency P1 (debuffs on P1, multiplicative product, 0.4 floor)
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

    -- suppression_level — sum, then apply resistance/immunity
    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0)
    INTO v_supp_p1
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 1
      AND e->>'modifier' = 'suppression_level'
      AND (e->>'value')::numeric > 0
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    SELECT COALESCE(SUM((e->>'value')::numeric), 0.0)
    INTO v_supp_p2
    FROM jsonb_array_elements(v_active_effects) e
    WHERE (e->>'target_player')::int = 2
      AND e->>'modifier' = 'suppression_level'
      AND (e->>'value')::numeric > 0
      AND COALESCE((e->>'activates_at') IS NULL OR (e->>'activates_at')::timestamptz <= now(), true);

    -- Apply suppression immunity (zeroes it entirely)
    IF v_supp_immune_p1 THEN v_supp_p1 := 0.0; END IF;
    IF v_supp_immune_p2 THEN v_supp_p2 := 0.0; END IF;
    -- Apply suppression resistance (reduces by percentage)
    IF v_supp_resistance_p1 > 0 THEN
      v_supp_p1 := GREATEST(0.0, v_supp_p1 * (1.0 - v_supp_resistance_p1));
    END IF;
    IF v_supp_resistance_p2 > 0 THEN
      v_supp_p2 := GREATEST(0.0, v_supp_p2 * (1.0 - v_supp_resistance_p2));
    END IF;

    -- momentum_window
    v_momentum_p1 := v_state.momentum_window_p1;
    v_momentum_p2 := v_state.momentum_window_p2;
    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_active_effects) LOOP
      IF v_effect->>'modifier' = 'momentum_window' AND (v_effect->>'value')::numeric > 0 THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
      -- also_sets from Game Winner metadata
      IF v_effect->>'ability_id' = 'athlete:game_winner' THEN
        IF (v_effect->>'target_player')::int = 1 THEN v_momentum_p1 := true; END IF;
        IF (v_effect->>'target_player')::int = 2 THEN v_momentum_p2 := true; END IF;
      END IF;
    END LOOP;
    -- Apply momentum suppression (Healthcare:Critical Intervention)
    IF v_momentum_suppress_p1 THEN v_momentum_p1 := false; END IF;
    IF v_momentum_suppress_p2 THEN v_momentum_p2 := false; END IF;

    -- ── Accumulate BaseFlow from unprocessed back events ──────────────────
    -- Business:Leverage uses a gentler decay constant (0.95 vs 0.9).
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

    -- Apply flow_rate_ceiling (Business:Monopoly — cap opponent's accumulated flow)
    IF v_ceil_p1 IS NOT NULL THEN
      v_new_flow_p1 := LEAST(v_new_flow_p1, v_ceil_p1);
    END IF;
    IF v_ceil_p2 IS NOT NULL THEN
      v_new_flow_p2 := LEAST(v_new_flow_p2, v_ceil_p2);
    END IF;

    -- ── Score per tick ────────────────────────────────────────────────────
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

    -- Mark back events processed
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

    -- ── Write match telemetry ─────────────────────────────────────────────
    SELECT COALESCE(SUM(CASE WHEN target_id = v_match.player_1_id AND type = 'back' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_2_id AND type = 'back' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_1_id AND type = 'trigger' THEN value ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN target_id = v_match.player_2_id AND type = 'trigger' THEN value ELSE 0 END), 0),
           COUNT(DISTINCT CASE WHEN target_id = v_match.player_1_id AND type = 'back' THEN user_id END)::int,
           COUNT(DISTINCT CASE WHEN target_id = v_match.player_2_id AND type = 'back' THEN user_id END)::int
    INTO v_tel_back_p1, v_tel_back_p2,
         v_tel_trigger_p1, v_tel_trigger_p2,
         v_tel_backers_p1, v_tel_backers_p2
    FROM public.arena_events
    WHERE match_id = v_match.id;

    -- Build abilities_used JSON for each side
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('ability_id', ability_id, 'count', cnt, 'total_cost', total_cost)
    ), '[]'::jsonb)
    INTO v_tel_abilities_p1
    FROM (
      SELECT au.ability_id,
             COUNT(*)::int AS cnt,
             SUM(COALESCE(ae.value, 0)) AS total_cost
      FROM public.arena_ability_uses au
      LEFT JOIN public.arena_events ae
        ON ae.match_id = au.match_id
        AND ae.user_id = au.user_id
        AND ae.type = 'trigger'
        AND (ae.metadata->>'ability_id') = au.ability_id
      WHERE au.match_id = v_match.id
        AND au.target_id = v_match.player_1_id
      GROUP BY au.ability_id
    ) sub;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('ability_id', ability_id, 'count', cnt, 'total_cost', total_cost)
    ), '[]'::jsonb)
    INTO v_tel_abilities_p2
    FROM (
      SELECT au.ability_id,
             COUNT(*)::int AS cnt,
             SUM(COALESCE(ae.value, 0)) AS total_cost
      FROM public.arena_ability_uses au
      LEFT JOIN public.arena_events ae
        ON ae.match_id = au.match_id
        AND ae.user_id = au.user_id
        AND ae.type = 'trigger'
        AND (ae.metadata->>'ability_id') = au.ability_id
      WHERE au.match_id = v_match.id
        AND au.target_id = v_match.player_2_id
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
      CASE WHEN v_winner_id = v_match.player_1_id
           THEN v_match.player_1_archetype
           ELSE v_match.player_2_archetype END
    ) ON CONFLICT (match_id) DO NOTHING;

    -- ── Token payouts ──────────────────────────────────────────────────────
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
