-- Migration 030: Arena token types + arena_back() RPC
-- Adds 'arena_back' and 'arena_win' to the token_transactions type constraint.
-- arena_back: charged when a user backs a creator (tokens debited at action time).
-- arena_win:  credited to winning backers and winning creator at match resolution.

-- ── 1. Extend token_transactions type constraint ───────────────────────────────
ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (
    type IN (
      'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
      'refund', 'promoted', 'referral_bonus', 'purchase', 'purchased',
      'challenge_reward', 'passive_bonus',
      'arena_back', 'arena_win'
    )
  );

-- ── 2. arena_back(p_match_id, p_target_id, p_amount) → new_balance ────────────
-- Atomically:
--   1. Validates match is live and target is a player.
--   2. Debits user's token_balances (available_tokens + lifetime_spent).
--   3. Inserts token_transactions row (type='arena_back').
--   4. Inserts arena_events row (type='back').
--   5. Increments total_pool_p1 or total_pool_p2 in arena_state.
--
-- SECURITY DEFINER: runs as postgres, bypasses RLS on all target tables.
-- The function validates auth.uid() so only the calling authenticated user
-- can debit their own balance.

CREATE OR REPLACE FUNCTION public.arena_back(
  p_match_id  uuid,
  p_target_id uuid,
  p_amount    numeric
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id    uuid;
  v_match      record;
  v_balance    integer;
  v_int_amount integer;
  v_new_bal    integer;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_int_amount := CEIL(p_amount)::integer;
  IF v_int_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  -- Lock and validate the match
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

  -- Debit token balance (mirrors handle_bet_token_deduction pattern from migration 004)
  UPDATE public.token_balances
  SET available_tokens = available_tokens - v_int_amount,
      lifetime_spent   = lifetime_spent   + v_int_amount,
      updated_at       = now()
  WHERE user_id            = v_user_id
    AND available_tokens  >= v_int_amount
  RETURNING available_tokens INTO v_new_bal;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient tokens';
  END IF;

  -- Record the spend
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (
    v_user_id, 'arena_back', v_int_amount, p_match_id,
    'Backed creator in arena match'
  );

  -- Append arena event (processed=false, tick loop picks it up)
  INSERT INTO public.arena_events (match_id, user_id, target_id, type, value)
  VALUES (p_match_id, v_user_id, p_target_id, 'back', v_int_amount);

  -- Increment the appropriate side pool in arena_state.
  -- pool columns are updated here immediately so the UI reflects the pool
  -- size before the next tick fires.
  IF p_target_id = v_match.player_1_id THEN
    UPDATE public.arena_state
    SET total_pool_p1 = total_pool_p1 + v_int_amount,
        updated_at    = now()
    WHERE match_id = p_match_id;
  ELSE
    UPDATE public.arena_state
    SET total_pool_p2 = total_pool_p2 + v_int_amount,
        updated_at    = now()
    WHERE match_id = p_match_id;
  END IF;

  RETURN v_new_bal;
END;
$$;
