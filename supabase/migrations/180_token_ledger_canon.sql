-- Migration 180: canonical token-ledger signs + atomic token debits.
--
-- Money-path audit 2026-07-25, bugs #4 and #5.
--
-- ═══ #4 — the ledger could not reconcile against balances ═══
-- Hard Rule 5 says every token movement is logged. It is — but not consistently:
--   * `chit_purchase` (mig 155, the CURRENT marketplace) writes -price  → signed
--   * `admin_adjustment` (mig 168) writes either sign                   → signed
--   * `arena_back` (mig 030) writes +amount for a DEBIT                 → magnitude
--   * `bet_placed` (hot-topic-place-bet) writes +amount for a DEBIT     → magnitude
-- So SUM(amount) over-counts every arena Back and every Hot Topic bet by 2x their
-- value, and no audit can reconcile `token_balances` from the ledger. ~341k
-- arena_back rows are already stored the magnitude way.
--
-- Fixed in two parts, because the ledger is append-only and history must NOT be
-- rewritten:
--   1. `token_ledger_signed` — a view exposing `signed_amount`, normalising by
--      TYPE rather than by stored sign. It is deliberately sign-agnostic
--      (-ABS() for debit types), so it returns the right number for both the
--      historical magnitude rows AND the corrected rows written from now on.
--      Every reconciliation/reporting query should read this view, never
--      token_transactions.amount directly.
--   2. The writers are corrected to the canonical signed convention going
--      forward (arena_back here; bet_placed in the RPC below).
--
-- ═══ #5 — lost-update races on token_balances ═══
-- hot-topic-place-bet and chit-marketplace-buy both did:
--     SELECT available_tokens  →  UPDATE available_tokens = <read value> - cost
-- Two concurrent calls read the same balance and each writes its own result, so
-- one debit is LOST — the user spends twice and is charged once. Neither was
-- atomic with the row it was paying for either, so a mid-flight failure could
-- take tokens with no bet/no goods.
--
-- Both are replaced by SECURITY DEFINER RPCs that do the whole thing in ONE
-- transaction, with the debit as a single conditional UPDATE
-- (`WHERE available_tokens >= cost`) — the pattern arena_back already used
-- correctly. This is the "money math belongs in an RPC, not an edge function"
-- rule the audit landed on.

-- ═══════════════════════════════════════════════════════════════════════════════
-- #4.1 — the canonical signed view
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW public.token_ledger_signed AS
SELECT
  t.id,
  t.user_id,
  t.type,
  t.amount AS raw_amount,
  CASE
    -- Debits. -ABS() so historical magnitude rows and corrected signed rows both
    -- normalise to the same (negative) number.
    WHEN t.type IN ('arena_back', 'bet_placed', 'chit_purchase')
      THEN -ABS(t.amount)
    -- Genuinely bidirectional: the stored sign IS the meaning.
    WHEN t.type IN ('admin_adjustment')
      THEN t.amount
    -- Everything else is a credit.
    ELSE ABS(t.amount)
  END AS signed_amount,
  t.reference_id,
  t.description,
  t.created_at
FROM public.token_transactions t;

COMMENT ON VIEW public.token_ledger_signed IS
  'Canonical token ledger (mig 180). Use signed_amount — never '
  'token_transactions.amount — for any reconciliation or reporting. Normalises by '
  'TYPE, so it is correct across the 2026-07-25 sign-convention cutover: rows '
  'written before it stored debits as magnitudes, rows after store them negative.';

-- Ops helper: who has drifted from their ledger? (Test accounts excluded — dev
-- tooling like arena-dev-reset hard-sets balances with no ledger rows at all.)
CREATE OR REPLACE FUNCTION public.token_balance_drift()
RETURNS TABLE (user_id UUID, balance INTEGER, ledger BIGINT, drift BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH led AS (
    SELECT l.user_id, SUM(l.signed_amount)::BIGINT AS ledger
    FROM public.token_ledger_signed l GROUP BY l.user_id
  )
  SELECT b.user_id, b.available_tokens, COALESCE(led.ledger, 0),
         b.available_tokens - COALESCE(led.ledger, 0)
  FROM public.token_balances b
  LEFT JOIN led ON led.user_id = b.user_id
  JOIN public.profiles p ON p.id = b.user_id
  WHERE COALESCE(p.is_test_account, FALSE) = FALSE
    AND b.available_tokens <> COALESCE(led.ledger, 0);
$$;

REVOKE ALL ON FUNCTION public.token_balance_drift() FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- #4.2 — arena_back writes the canonical sign from now on
-- Body is mig 030's verbatim except the ledger amount (marked).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.arena_back(
  p_match_id  uuid,
  p_target_id uuid,
  p_amount    numeric
)
RETURNS integer          -- unchanged from mig 030: clients read the new balance
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_match      record;
  v_new_bal    integer;
  v_int_amount integer;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_int_amount := CEIL(p_amount)::integer;
  IF v_int_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT * INTO v_match FROM public.arena_matches WHERE id = p_match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Match not found';
  END IF;
  IF v_match.state <> 'live' THEN
    RAISE EXCEPTION 'Match is not live (state: %)', v_match.state;
  END IF;
  IF p_target_id NOT IN (v_match.player_1_id, v_match.player_2_id) THEN
    RAISE EXCEPTION 'Target % is not a player in match %', p_target_id, p_match_id;
  END IF;

  -- Atomic guarded debit (this part was always correct).
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

  -- Record the spend. NEGATIVE: a Back is a debit (audit #4). Historical rows are
  -- positive magnitudes; token_ledger_signed normalises both.
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (
    v_user_id, 'arena_back', -v_int_amount, p_match_id,
    'Backed creator in arena match'
  );

  INSERT INTO public.arena_events (match_id, user_id, target_id, type, value)
  VALUES (p_match_id, v_user_id, p_target_id, 'back', v_int_amount);

  IF p_target_id = v_match.player_1_id THEN
    UPDATE public.arena_state
    SET total_pool_p1 = total_pool_p1 + v_int_amount, updated_at = now()
    WHERE match_id = p_match_id;
  ELSE
    UPDATE public.arena_state
    SET total_pool_p2 = total_pool_p2 + v_int_amount, updated_at = now()
    WHERE match_id = p_match_id;
  END IF;

  RETURN v_new_bal;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- #4.3 — increment_token_balance: lifetime accounting was wrong for debits
-- It added p_amount to lifetime_earned unconditionally, so a negative amount
-- DECREMENTED lifetime_earned instead of incrementing lifetime_spent.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.increment_token_balance(p_user_id UUID, p_amount INTEGER)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE public.token_balances
  SET available_tokens = available_tokens + p_amount,
      lifetime_earned  = lifetime_earned + GREATEST(p_amount, 0),
      lifetime_spent   = lifetime_spent  + GREATEST(-p_amount, 0),
      updated_at       = now()
  WHERE user_id = p_user_id;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- #5.1 — Hot Topic bet placement, atomic
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.hot_topic_place_bet_atomic(
  p_user            UUID,
  p_week_id         TEXT,
  p_bet_category    TEXT,
  p_tokens          INTEGER,
  p_simple_direction TEXT DEFAULT NULL,
  p_celeb_id        UUID DEFAULT NULL,
  p_scoring_window  TEXT DEFAULT NULL,
  p_weekly_bet_type TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_bet UUID;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_tokens IS NULL OR p_tokens <= 0 THEN RAISE EXCEPTION 'Wager must be positive'; END IF;

  -- Single conditional UPDATE: no read-then-write, so concurrent bets cannot
  -- lose a debit (audit #5).
  UPDATE public.token_balances
  SET available_tokens = available_tokens - p_tokens,
      lifetime_spent   = lifetime_spent + p_tokens,
      updated_at       = now()
  WHERE user_id = p_user
    AND available_tokens >= p_tokens;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient tokens';
  END IF;

  -- Same transaction: if this violates the one-bet-per-window UNIQUE, the debit
  -- above rolls back with it. No compensating "restore the balance" write, and
  -- therefore no stale absolute value to clobber a concurrent change.
  INSERT INTO public.weekly_bets
    (user_id, week_id, bet_category, tokens_wagered, status,
     simple_direction, celeb_id, scoring_window, weekly_bet_type)
  VALUES
    (p_user, p_week_id, p_bet_category, p_tokens, 'pending',
     p_simple_direction, p_celeb_id, p_scoring_window, p_weekly_bet_type)
  RETURNING id INTO v_bet;

  -- NEGATIVE: a placed bet is a debit (audit #4).
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (p_user, 'bet_placed', -p_tokens, v_bet,
          CASE WHEN p_bet_category = 'simple'
               THEN 'Hot Topic simple bet (' || COALESCE(p_simple_direction,'') || ')'
               ELSE 'Hot Topic weekly bet (' || COALESCE(p_weekly_bet_type,'') || ')' END);

  RETURN v_bet;
END;
$$;

REVOKE ALL ON FUNCTION public.hot_topic_place_bet_atomic(UUID, TEXT, TEXT, INTEGER, TEXT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- #5.2 — legacy chit marketplace purchase, atomic
-- Dormant under v3 (Hard Rule 27) but still deployed and still spending tokens.
-- It had THREE read-then-write races: the buyer's balance, the listing quantity
-- (oversell), and the buyer's inventory row.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.chit_marketplace_buy_atomic(
  p_buyer UUID, p_listing UUID, p_quantity INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_l    public.chit_marketplace_listings%ROWTYPE;
  v_cost INTEGER;
  v_new  INTEGER;
BEGIN
  IF p_buyer IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;

  -- Lock the listing: serialises concurrent buyers, so quantity cannot oversell.
  SELECT * INTO v_l FROM public.chit_marketplace_listings
  WHERE id = p_listing FOR UPDATE;
  IF NOT FOUND OR v_l.status <> 'active' THEN
    RAISE EXCEPTION 'Listing not found or not active';
  END IF;
  IF v_l.seller_user_id = p_buyer THEN
    RAISE EXCEPTION 'Cannot buy your own listing';
  END IF;
  IF v_l.quantity_listed < p_quantity THEN
    RAISE EXCEPTION 'Insufficient quantity in listing';
  END IF;

  v_cost := v_l.price_per_unit_tokens * p_quantity;

  UPDATE public.token_balances
  SET available_tokens = available_tokens - v_cost,
      lifetime_spent   = lifetime_spent + v_cost,
      updated_at       = now()
  WHERE user_id = p_buyer AND available_tokens >= v_cost;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient token balance';
  END IF;

  PERFORM public.increment_token_balance(v_l.seller_user_id, v_cost);

  -- Buyer inventory: UPSERT rather than read-then-write.
  UPDATE public.user_battle_chits
  SET quantity = quantity + p_quantity
  WHERE user_id = p_buyer AND chit_definition_id = v_l.chit_definition_id;
  IF NOT FOUND THEN
    INSERT INTO public.user_battle_chits
      (user_id, chit_definition_id, quantity, acquired_via)
    VALUES (p_buyer, v_l.chit_definition_id, p_quantity, 'marketplace_purchase');
  END IF;

  v_new := v_l.quantity_listed - p_quantity;
  UPDATE public.chit_marketplace_listings
  SET quantity_listed = v_new,
      status = CASE WHEN v_new = 0 THEN 'sold' ELSE 'active' END
  WHERE id = p_listing;

  -- Hard Rule 5, canonical signs (audit #4).
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES
    (p_buyer, 'chit_purchase', -v_cost, p_listing,
     'Bought ' || p_quantity || ' chit(s) from marketplace'),
    (v_l.seller_user_id, 'chit_sale', v_cost, p_listing,
     'Sold ' || p_quantity || ' chit(s) on marketplace');

  RETURN jsonb_build_object('success', TRUE, 'quantity_purchased', p_quantity);
END;
$$;

REVOKE ALL ON FUNCTION public.chit_marketplace_buy_atomic(UUID, UUID, INTEGER)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_bal0 INTEGER; v_bal INTEGER; v_le0 INTEGER; v_ls0 INTEGER; v_le INTEGER; v_ls INTEGER;
  v_bet UUID; v_err BOOLEAN; v_msg TEXT;
  v_signed BIGINT; v_week TEXT := 'mig180-' || substr(gen_random_uuid()::TEXT, 1, 8);
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email='mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email='mkt-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN
    RAISE EXCEPTION 'mig 180 smoke needs the mig-155 smoke users';
  END IF;

  SELECT available_tokens, lifetime_earned, lifetime_spent
    INTO v_bal0, v_le0, v_ls0 FROM public.token_balances WHERE user_id = v_u1;

  -- ── #4.3: a negative increment must hit lifetime_spent, not lifetime_earned ──
  PERFORM public.increment_token_balance(v_u1, -10);
  SELECT lifetime_earned, lifetime_spent INTO v_le, v_ls
  FROM public.token_balances WHERE user_id = v_u1;
  IF v_le <> v_le0 OR v_ls <> v_ls0 + 10 THEN
    RAISE EXCEPTION 'SMOKE FAIL: a debit must move lifetime_spent (earned % -> %, spent % -> %)',
      v_le0, v_le, v_ls0, v_ls;
  END IF;
  PERFORM public.increment_token_balance(v_u1, 10);
  SELECT lifetime_earned, lifetime_spent INTO v_le, v_ls
  FROM public.token_balances WHERE user_id = v_u1;
  IF v_le <> v_le0 + 10 OR v_ls <> v_ls0 + 10 THEN
    RAISE EXCEPTION 'SMOKE FAIL: a credit must move lifetime_earned';
  END IF;

  -- ── #5.1: the atomic bet debits exactly once and logs a NEGATIVE amount ─────
  PERFORM public.increment_token_balance(v_u1, 500);
  SELECT available_tokens INTO v_bal0 FROM public.token_balances WHERE user_id = v_u1;

  v_bet := public.hot_topic_place_bet_atomic(
    v_u1, v_week, 'simple', 25, 'up',
    (SELECT id FROM public.celebs LIMIT 1), 'daily', NULL);

  SELECT available_tokens INTO v_bal FROM public.token_balances WHERE user_id = v_u1;
  IF v_bal <> v_bal0 - 25 THEN
    RAISE EXCEPTION 'SMOKE FAIL: the bet must debit exactly 25 (was %, now %)', v_bal0, v_bal;
  END IF;
  IF (SELECT amount FROM public.token_transactions WHERE reference_id::TEXT = v_bet::TEXT
      AND type='bet_placed') <> -25 THEN
    RAISE EXCEPTION 'SMOKE FAIL: bet_placed must be logged NEGATIVE (audit #4)';
  END IF;

  -- ── #4.1: the view normalises both conventions to the same signed number ────
  SELECT signed_amount INTO v_signed FROM public.token_ledger_signed
  WHERE reference_id::TEXT = v_bet::TEXT AND type='bet_placed';
  IF v_signed <> -25 THEN
    RAISE EXCEPTION 'SMOKE FAIL: the view must sign a new bet_placed row as -25 (got %)', v_signed;
  END IF;
  -- a legacy-shaped (positive magnitude) debit row must normalise the same way
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (v_u1, 'arena_back', 40, v_bet, 'mig180 legacy-shape probe');
  SELECT signed_amount INTO v_signed FROM public.token_ledger_signed
  WHERE reference_id::TEXT = v_bet::TEXT AND type='arena_back';
  IF v_signed <> -40 THEN
    RAISE EXCEPTION 'SMOKE FAIL: the view must normalise a legacy positive debit to -40 (got %)', v_signed;
  END IF;
  -- and a credit stays positive
  IF (SELECT signed_amount FROM public.token_ledger_signed
      WHERE type='signup_bonus' LIMIT 1) < 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: credits must stay positive in the view';
  END IF;

  -- ── #5.1: insufficient funds must RAISE, and must not debit ────────────────
  SELECT available_tokens INTO v_bal0 FROM public.token_balances WHERE user_id = v_u1;
  v_err := FALSE;
  BEGIN
    PERFORM public.hot_topic_place_bet_atomic(
      v_u1, v_week || 'x', 'simple', v_bal0 + 1000, 'up',
      (SELECT id FROM public.celebs LIMIT 1), 'daily', NULL);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%Insufficient tokens%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: an unaffordable bet must RAISE (got %)', v_msg;
  END IF;
  SELECT available_tokens INTO v_bal FROM public.token_balances WHERE user_id = v_u1;
  IF v_bal <> v_bal0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: a failed bet must not move the balance (% -> %)', v_bal0, v_bal;
  END IF;

  -- ── cleanup: remove the smoke bet + probe rows, restore the balance ────────
  DELETE FROM public.token_transactions WHERE reference_id::TEXT = v_bet::TEXT;
  DELETE FROM public.weekly_bets WHERE id = v_bet;
  PERFORM public.increment_token_balance(v_u1, 25 - 500);

  RAISE NOTICE 'mig 180 smoke OK: lifetime accounting fixed, atomic bet debits once, debits logged negative, view normalises both conventions, insufficient funds cannot debit';
END $$;
