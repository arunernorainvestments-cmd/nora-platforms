-- Migration 034: arena_trigger() RPC + extend token type constraint
--
-- Design choice: the Trigger RPC writes the new effect directly to
-- arena_state.active_effects (immediate Realtime push, no tick delay).
-- The arena_events row is inserted with processed=true and serves as the
-- event ticker feed + audit log. The tick loop reads active_effects for
-- stacking math — it does not re-process trigger events.
--
-- This solves the 1-minute tick / short-duration ability timing problem:
-- Sprint (8 s) would expire before the tick fires it if it waited for the loop.

-- ── 1. Extend token_transactions type constraint ───────────────────────────────
ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (
    type IN (
      'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
      'refund', 'promoted', 'referral_bonus', 'purchase', 'purchased',
      'challenge_reward', 'passive_bonus',
      'arena_back', 'arena_win', 'arena_trigger'
    )
  );

-- ── 2. arena_trigger(p_match_id, p_ability_id, p_target_id) → jsonb ───────────
-- p_target_id: the player who RECEIVES the effect.
--   ability.target='self'     → p_target_id = the player the user is supporting
--   ability.target='opponent' → p_target_id = the opposing player
-- The caller (Flutter) resolves which UUID to send based on selected side.
--
-- Returns: { new_balance, effect_expires_at, effect_id }

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
  v_user_id        uuid;
  v_match          record;
  v_state          record;
  v_ability        record;
  v_last_use_at    timestamptz;
  v_new_bal        integer;
  v_effect_id      uuid;
  v_expires_at     timestamptz;
  v_target_player  int;
  v_elapsed_secs   numeric;
  v_new_effect     jsonb;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Lock arena_matches first (consistent lock order with tick loop)
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
  IF v_ability.token_cost <= 0 THEN
    RAISE EXCEPTION 'Ability % has no token cost (passive?)', p_ability_id;
  END IF;

  -- Cooldown check (skip for ultimates — handled separately below)
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
    -- 5-minute match = 300 s; last 20 s window starts at 280 s
    IF v_elapsed_secs < 280 THEN
      RAISE EXCEPTION '% can only be triggered in the final 20 seconds (%.0f s elapsed)',
        v_ability.display_name, v_elapsed_secs;
    END IF;
  END IF;

  -- Debit tokens (atomic: fails if balance insufficient)
  UPDATE public.token_balances
  SET available_tokens = available_tokens - v_ability.token_cost,
      lifetime_spent   = lifetime_spent   + v_ability.token_cost,
      updated_at       = now()
  WHERE user_id           = v_user_id
    AND available_tokens >= v_ability.token_cost
  RETURNING available_tokens INTO v_new_bal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient tokens (need %)', v_ability.token_cost;
  END IF;

  -- Log the spend
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (
    v_user_id, 'arena_trigger', v_ability.token_cost, p_match_id,
    'Triggered ability: ' || v_ability.display_name || ' in match ' || p_match_id
  );

  -- Record ability use (cooldown + audit log)
  INSERT INTO public.arena_ability_uses (match_id, user_id, ability_id, target_id)
  VALUES (p_match_id, v_user_id, p_ability_id, p_target_id);

  -- Determine target player number (1 or 2) for active_effects
  v_target_player := CASE WHEN p_target_id = v_match.player_1_id THEN 1 ELSE 2 END;

  -- Compute effect expiry
  v_effect_id  := gen_random_uuid();
  v_expires_at := now() + (v_ability.duration_seconds || ' seconds')::interval;

  -- Build the effect object for active_effects
  v_new_effect := jsonb_build_object(
    'effect_id',       v_effect_id,
    'ability_id',      p_ability_id,
    'source_user_id',  v_user_id,
    'target_player',   v_target_player,
    'modifier',        v_ability.modifier,
    'value',           v_ability.modifier_value,
    'expires_at',      v_expires_at,
    'is_passive',      false,
    'ability_metadata', v_ability.metadata
  );

  -- Push effect directly to arena_state.active_effects (immediate Realtime push)
  -- Tick loop reads this array for stacking math each tick.
  UPDATE public.arena_state
  SET active_effects = active_effects || jsonb_build_array(v_new_effect),
      updated_at     = now()
  WHERE match_id = p_match_id;

  -- Insert arena_events with processed=true (audit log + event ticker)
  -- processed=true tells the tick loop this event was already applied.
  INSERT INTO public.arena_events
    (match_id, user_id, target_id, type, value, processed, metadata)
  VALUES (
    p_match_id, v_user_id, p_target_id, 'trigger', v_ability.token_cost,
    true,
    jsonb_build_object(
      'ability_id',    p_ability_id,
      'display_name',  v_ability.display_name,
      'effect_id',     v_effect_id,
      'target_player', v_target_player
    )
  );

  RETURN jsonb_build_object(
    'new_balance',       v_new_bal,
    'effect_expires_at', v_expires_at,
    'effect_id',         v_effect_id
  );
END;
$$;
