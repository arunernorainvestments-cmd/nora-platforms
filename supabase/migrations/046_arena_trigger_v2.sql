-- Migration 046: arena_trigger() v2
-- Extends Phase B arena_trigger() to handle all Phase C special cases:
--   1. Debate ability lockout (metadata.locks_abilities)
--   2. Secondary effects (metadata.secondary_effect) — Performer:Spotlight Steal
--   3. Token cost discounts (metadata.ability_cost_discount) — Educator:Optimize, Business:Cut Costs
--   4. Musician duration extension (metadata.duration_multiplier) — Replay Value passive
--   5. Special actions computed and applied at trigger time:
--        reset_baseline       — Healthcare:Resuscitate (snap flow rates to average)
--        subtract_opponent_flow — Politician:Power Move (deduct 50% of opponent flow)
--        convert_flow         — Religion:Convert (transfer 5% of opponent flow to self)
--        revival              — Religion:Revival (re-push most recent expired effect)
--        miracle              — Religion:Miracle (deterministic swing, value from tick counter)
--        monopoly_ceiling     — Business:Monopoly (compute ceiling from current opponent flow)
--   6. Business:Invest scheduled activation (metadata.scheduled_delay_secs → activates_at)

CREATE OR REPLACE FUNCTION public.arena_trigger(
  p_match_id   uuid,
  p_ability_id text,
  p_target_id  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id          uuid;
  v_match            record;
  v_state            record;
  v_ability          record;
  v_last_use_at      timestamptz;
  v_new_bal          integer;
  v_effect_id        uuid;
  v_expires_at       timestamptz;
  v_activates_at     timestamptz;
  v_target_player    int;
  v_other_player     int;
  v_elapsed_secs     numeric;
  v_new_effect       jsonb;
  v_effect           jsonb;
  v_effects_out      jsonb;
  v_target_archetype text;
  v_duration_secs    int;
  v_actual_cost      int;
  v_discount         numeric;

  -- Special action helpers
  v_miracle_value    numeric;
  v_ceiling_value    numeric;
  v_opponent_flow    numeric;
  v_transfer_amt     numeric;
  v_expired_list     jsonb;
  v_revived_effect   jsonb;
  v_secondary        jsonb;
  v_sec_player       int;

BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Lock arena_matches (consistent lock order with tick loop)
  SELECT * INTO v_match
  FROM public.arena_matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Match not found';
  END IF;
  IF v_match.state != 'live' THEN
    RAISE EXCEPTION 'Match is not live (state: %)', v_match.state;
  END IF;
  IF p_target_id != v_match.player_1_id AND p_target_id != v_match.player_2_id THEN
    RAISE EXCEPTION 'Target % is not a player in match %', p_target_id, p_match_id;
  END IF;

  -- Lock arena_state (second in lock order)
  SELECT * INTO v_state
  FROM public.arena_state
  WHERE match_id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Arena state not found for match %', p_match_id;
  END IF;

  -- Load ability config
  SELECT * INTO v_ability
  FROM public.arena_abilities
  WHERE id = p_ability_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ability % not found', p_ability_id;
  END IF;
  IF v_ability.ability_type = 'passive' THEN
    RAISE EXCEPTION 'Passive abilities cannot be manually triggered';
  END IF;

  -- ── Check Politician:Debate ability lockout ───────────────────────────────
  -- Any active effect with locks_abilities = true blocks all triggers.
  FOR v_effect IN SELECT * FROM jsonb_array_elements(v_state.active_effects) LOOP
    IF COALESCE((v_effect->'ability_metadata'->>'locks_abilities')::boolean, false) THEN
      RAISE EXCEPTION 'Abilities are locked — Debate is active (%.0f s remaining)',
        EXTRACT(EPOCH FROM ((v_effect->>'expires_at')::timestamptz - now()));
    END IF;
  END LOOP;

  -- ── Cooldown check ────────────────────────────────────────────────────────
  IF v_ability.cooldown_seconds > 0 AND v_ability.cooldown_seconds < 999999 THEN
    SELECT triggered_at INTO v_last_use_at
    FROM public.arena_ability_uses
    WHERE match_id   = p_match_id
      AND user_id    = v_user_id
      AND ability_id = p_ability_id
    ORDER BY triggered_at DESC
    LIMIT 1;

    IF FOUND AND
       EXTRACT(EPOCH FROM (now() - v_last_use_at)) < v_ability.cooldown_seconds
    THEN
      RAISE EXCEPTION 'Ability % is on cooldown (%.0f s remaining)',
        v_ability.display_name,
        v_ability.cooldown_seconds - EXTRACT(EPOCH FROM (now() - v_last_use_at));
    END IF;
  END IF;

  -- Ultimate: one use per user per match
  IF v_ability.cooldown_seconds = 999999 THEN
    IF EXISTS (
      SELECT 1 FROM public.arena_ability_uses
      WHERE match_id   = p_match_id
        AND user_id    = v_user_id
        AND ability_id = p_ability_id
    ) THEN
      RAISE EXCEPTION '% can only be used once per match', v_ability.display_name;
    END IF;
  END IF;

  -- Trigger window validation
  IF v_ability.trigger_window = 'last_20_seconds' THEN
    IF v_match.actual_start IS NULL THEN
      RAISE EXCEPTION 'Match has not started yet';
    END IF;
    v_elapsed_secs := EXTRACT(EPOCH FROM (now() - v_match.actual_start));
    IF v_elapsed_secs < 280 THEN
      RAISE EXCEPTION '% can only be triggered in the final 20 seconds (%.0f s elapsed)',
        v_ability.display_name, v_elapsed_secs;
    END IF;
  END IF;

  -- ── Check for token cost discount (Educator:Optimize, Business:Cut Costs) ─
  -- Scan active effects on this user's supported side for ability_cost_discount metadata.
  -- The user's supported side is the side whose abilities they're targeting (p_target_id player).
  v_target_player := CASE WHEN p_target_id = v_match.player_1_id THEN 1 ELSE 2 END;
  v_actual_cost   := v_ability.token_cost;
  v_discount      := 0.0;

  FOR v_effect IN SELECT * FROM jsonb_array_elements(v_state.active_effects) LOOP
    IF (v_effect->>'target_player')::int = v_target_player THEN
      IF (v_effect->'ability_metadata'->>'ability_cost_discount') IS NOT NULL THEN
        v_discount := GREATEST(v_discount,
          (v_effect->'ability_metadata'->>'ability_cost_discount')::numeric);
      END IF;
    END IF;
  END LOOP;

  IF v_discount > 0 THEN
    v_actual_cost := GREATEST(1, FLOOR(v_actual_cost * (1 - v_discount))::int);
  END IF;

  -- ── Debit tokens ──────────────────────────────────────────────────────────
  UPDATE public.token_balances
  SET available_tokens = available_tokens - v_actual_cost,
      lifetime_spent   = lifetime_spent   + v_actual_cost,
      updated_at       = now()
  WHERE user_id           = v_user_id
    AND available_tokens >= v_actual_cost
  RETURNING available_tokens INTO v_new_bal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient tokens (need %)', v_actual_cost;
  END IF;

  -- Log spend
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (
    v_user_id, 'arena_trigger', v_actual_cost, p_match_id,
    'Triggered ability: ' || v_ability.display_name
  );

  -- Record ability use (cooldown + audit log)
  INSERT INTO public.arena_ability_uses (match_id, user_id, ability_id, target_id)
  VALUES (p_match_id, v_user_id, p_ability_id, p_target_id);

  -- ── Compute effect parameters ──────────────────────────────────────────────
  v_other_player     := CASE WHEN v_target_player = 1 THEN 2 ELSE 1 END;
  v_target_archetype := CASE WHEN p_target_id = v_match.player_1_id
                             THEN v_match.player_1_archetype
                             ELSE v_match.player_2_archetype END;
  v_effect_id        := gen_random_uuid();

  -- Base duration — extended by Musician:Replay Value if target side is Musician
  v_duration_secs := v_ability.duration_seconds;
  IF v_target_archetype = 'musician' AND v_ability.ability_type != 'passive' THEN
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_state.active_effects) e
      WHERE e->>'ability_id' = 'musician:replay_value'
        AND (e->>'target_player')::int = v_target_player
    ) THEN
      v_duration_secs := CEIL(v_duration_secs * 1.25)::int;
    END IF;
  END IF;

  v_expires_at := now() + (v_duration_secs || ' seconds')::interval;

  -- Scheduled delay (Business:Invest)
  v_activates_at := NULL;
  IF (v_ability.metadata->>'scheduled_delay_secs') IS NOT NULL THEN
    v_activates_at := now() + ((v_ability.metadata->>'scheduled_delay_secs')::int || ' seconds')::interval;
  END IF;

  -- ── Handle special_action abilities ───────────────────────────────────────
  -- These take effect immediately and may short-circuit the standard effect push.

  -- Healthcare:Resuscitate — snap both flow rates to average
  IF v_ability.metadata->>'special_action' = 'reset_baseline' THEN
    DECLARE v_avg numeric;
    BEGIN
      v_avg := (v_state.flow_rate_p1 + v_state.flow_rate_p2) / 2.0;
      UPDATE public.arena_state
      SET flow_rate_p1 = v_avg,
          flow_rate_p2 = v_avg,
          updated_at   = now()
      WHERE match_id = p_match_id;
    END;
    -- Still push a 1s display effect so the UI shows the ability fired
  END IF;

  -- Politician:Power Move — subtract 50% of opponent's flow rate
  IF v_ability.metadata->>'special_action' = 'subtract_opponent_flow' THEN
    DECLARE
      v_sub_pct numeric := COALESCE((v_ability.metadata->>'subtract_pct')::numeric, 0.5);
    BEGIN
      IF v_target_player = 1 THEN
        -- Targeting P1 (opponent of user's supported side) = reducing P1's flow
        -- target_player = 1 means opponent is P1, so p_target_id = player_1_id
        -- The ability targets the OPPONENT player, so we reduce p_target_id's flow
        UPDATE public.arena_state
        SET flow_rate_p1 = GREATEST(0, flow_rate_p1 * (1 - v_sub_pct)),
            updated_at   = now()
        WHERE match_id = p_match_id;
      ELSE
        UPDATE public.arena_state
        SET flow_rate_p2 = GREATEST(0, flow_rate_p2 * (1 - v_sub_pct)),
            updated_at   = now()
        WHERE match_id = p_match_id;
      END IF;
    END;
  END IF;

  -- Religion:Convert — transfer 5% of opponent's flow to self
  IF v_ability.metadata->>'special_action' = 'convert_flow' THEN
    DECLARE
      v_xfer_pct numeric := COALESCE((v_ability.metadata->>'transfer_pct')::numeric, 0.05);
    BEGIN
      -- p_target_id is the OPPONENT (ability target='opponent')
      IF v_target_player = 1 THEN
        -- Opponent is P1; self is P2
        v_transfer_amt := v_state.flow_rate_p1 * v_xfer_pct;
        UPDATE public.arena_state
        SET flow_rate_p1 = GREATEST(0, flow_rate_p1 - v_transfer_amt),
            flow_rate_p2 = flow_rate_p2 + v_transfer_amt,
            updated_at   = now()
        WHERE match_id = p_match_id;
      ELSE
        v_transfer_amt := v_state.flow_rate_p2 * v_xfer_pct;
        UPDATE public.arena_state
        SET flow_rate_p2 = GREATEST(0, flow_rate_p2 - v_transfer_amt),
            flow_rate_p1 = flow_rate_p1 + v_transfer_amt,
            updated_at   = now()
        WHERE match_id = p_match_id;
      END IF;
    END;
  END IF;

  -- Religion:Revival — re-push most recent expired effect for this target's side
  IF v_ability.metadata->>'special_action' = 'revival' THEN
    v_expired_list := v_state.expired_effects;
    v_revived_effect := NULL;

    -- Find most recent expired effect targeting v_target_player (revival is 'self')
    FOR v_effect IN SELECT * FROM jsonb_array_elements(v_expired_list) LOOP
      IF (v_effect->>'target_player')::int = v_target_player THEN
        v_revived_effect := v_effect;
        EXIT; -- expired_effects is ordered most-recent-first
      END IF;
    END LOOP;

    IF v_revived_effect IS NOT NULL THEN
      DECLARE
        v_orig_duration_secs int;
        v_revived_id         uuid;
      BEGIN
        -- Compute 50% of the original duration from the effect's stored duration
        -- We re-derive it from (original expires_at - when it expired)
        -- Since we don't store original duration, use ability duration as fallback
        v_revived_id := gen_random_uuid();
        v_orig_duration_secs := COALESCE(
          (v_revived_effect->>'original_duration_secs')::int,
          30  -- fallback: 30s if not stored
        );

        v_revived_effect := v_revived_effect
          || jsonb_build_object(
               'effect_id',  v_revived_id,
               'expires_at', now() + ((v_orig_duration_secs / 2) || ' seconds')::interval,
               'revived',    true
             );

        UPDATE public.arena_state
        SET active_effects = active_effects || jsonb_build_array(v_revived_effect),
            updated_at     = now()
        WHERE match_id = p_match_id;
      END;
    END IF;
    -- Still push the 1s display effect for revival
  END IF;

  -- Religion:Miracle — deterministic swing value from match tick counter
  IF v_ability.metadata->>'special_action' = 'miracle' THEN
    DECLARE
      v_range_min numeric := COALESCE((v_ability.metadata->>'range_min')::numeric, 0.5);
      v_range_max numeric := COALESCE((v_ability.metadata->>'range_max')::numeric, 3.0);
    BEGIN
      -- sin(tick * 2.7) maps to [-1, 1]; normalize to [range_min, range_max]
      v_miracle_value := v_range_min
        + (SIN(v_state.tick::numeric * 2.7) + 1.0) / 2.0 * (v_range_max - v_range_min);
    END;
  END IF;

  -- Business:Monopoly — compute ceiling from opponent's current flow rate
  IF v_ability.metadata->>'special_action' = 'monopoly_ceiling' THEN
    -- p_target_id is the opponent
    IF v_target_player = 1 THEN
      v_ceiling_value := GREATEST(v_state.flow_rate_p1, 1.0);
    ELSE
      v_ceiling_value := GREATEST(v_state.flow_rate_p2, 1.0);
    END IF;
  END IF;

  -- ── Build primary effect object ───────────────────────────────────────────
  v_new_effect := jsonb_build_object(
    'effect_id',              v_effect_id,
    'ability_id',             p_ability_id,
    'source_user_id',         v_user_id,
    'target_player',          v_target_player,
    'modifier',               v_ability.modifier,
    'value',                  CASE
                                WHEN v_ability.metadata->>'special_action' = 'miracle'
                                  THEN v_miracle_value
                                ELSE v_ability.modifier_value
                              END,
    'expires_at',             v_expires_at,
    'is_passive',             false,
    'ability_metadata',       v_ability.metadata
      || CASE WHEN v_ceiling_value IS NOT NULL
              THEN jsonb_build_object('ceiling_value', v_ceiling_value)
              ELSE '{}'::jsonb END,
    'original_duration_secs', v_duration_secs
  );

  -- Add activates_at for scheduled effects
  IF v_activates_at IS NOT NULL THEN
    v_new_effect := v_new_effect || jsonb_build_object('activates_at', v_activates_at);
  END IF;

  -- Push primary effect to active_effects
  UPDATE public.arena_state
  SET active_effects = active_effects || jsonb_build_array(v_new_effect),
      updated_at     = now()
  WHERE match_id = p_match_id;

  -- ── Secondary effect (Performer:Spotlight Steal) ─────────────────────────
  IF (v_ability.metadata->>'secondary_effect') IS NOT NULL THEN
    v_secondary := (v_ability.metadata->'secondary_effect');

    -- Resolve target for secondary effect
    v_sec_player := CASE
      WHEN v_secondary->>'target' = 'self' THEN v_other_player  -- 'self' = the user's supported side
      WHEN v_secondary->>'target' = 'opponent' THEN v_target_player
      ELSE v_other_player
    END;

    v_new_effect := jsonb_build_object(
      'effect_id',              gen_random_uuid(),
      'ability_id',             p_ability_id || '_secondary',
      'source_user_id',         v_user_id,
      'target_player',          v_sec_player,
      'modifier',               v_secondary->>'modifier',
      'value',                  (v_secondary->>'value')::numeric,
      'expires_at',             v_expires_at,
      'is_passive',             false,
      'ability_metadata',       '{"secondary": true}'::jsonb,
      'original_duration_secs', v_duration_secs
    );

    UPDATE public.arena_state
    SET active_effects = active_effects || jsonb_build_array(v_new_effect),
        updated_at     = now()
    WHERE match_id = p_match_id;
  END IF;

  -- ── Event ticker entry ────────────────────────────────────────────────────
  INSERT INTO public.arena_events
    (match_id, user_id, target_id, type, value, processed, metadata)
  VALUES (
    p_match_id, v_user_id, p_target_id, 'trigger', v_actual_cost,
    true,
    jsonb_build_object(
      'ability_id',    p_ability_id,
      'display_name',  v_ability.display_name,
      'effect_id',     v_effect_id,
      'target_player', v_target_player,
      'discounted',    v_discount > 0
    )
  );

  RETURN jsonb_build_object(
    'new_balance',       v_new_bal,
    'effect_expires_at', v_expires_at,
    'effect_id',         v_effect_id,
    'actual_cost',       v_actual_cost
  );
END;
$$;
