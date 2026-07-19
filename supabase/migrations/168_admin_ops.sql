-- Migration 168: admin operations console, iteration 2 (PLAN 2026-07-15 callout,
-- "NOT yet in the MVP" list): audited token adjustments + admin marketplace delist.
--
-- Both are service-only `_internal` fns (mig 101/155 pattern) called from the
-- admin-review edge function AFTER its own profiles.is_admin gate; each re-checks
-- the acting admin server-side anyway (belt and suspenders). No client grants.
--
-- Rules in force:
--   • Hard Rule 5 — every token movement lands in token_transactions with a type
--     and reference_id (here: type 'admin_adjustment', reference_id = acting admin).
--   • Hard Rule 40 — marketplace writes only via marketplace_* RPCs; the admin
--     delist reuses the exact seller-delist semantics (escrow returns to the
--     SELLER on the append-only acquisition ledger; listing → 'delisted').

-- ── 1. token_transactions gains the 'admin_adjustment' type ─────────────────────
ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (type IN (
    -- Existing (must not remove any — mig 088 list):
    'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
    'refund', 'promoted', 'referral_bonus', 'purchase', 'purchased',
    'challenge_reward', 'passive_bonus',
    'arena_back', 'arena_win', 'arena_trigger',
    'verification_bonus',
    'card_purchase', 'card_sale',
    'match_active_reward', 'match_creator_reward', 'match_passive_reward',
    'chit_earn', 'chit_purchase', 'chit_sale',
    'poll_boost_applied', 'platform_fee',
    -- New:
    'admin_adjustment'
  ));

-- ── 2. admin_adjust_tokens_internal ─────────────────────────────────────────────
-- A manual, audited balance correction (support refunds, goodwill grants,
-- clawbacks). Negative deltas are balance-guarded — an adjustment can never
-- drive available_tokens below zero.
CREATE OR REPLACE FUNCTION public.admin_adjust_tokens_internal(
  p_admin UUID, p_user_id UUID, p_delta INTEGER, p_note TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Not an admin';
  END IF;
  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'Delta must be non-zero';
  END IF;
  IF ABS(p_delta) > 100000 THEN
    RAISE EXCEPTION 'Adjustment too large (max 100000 per action)';
  END IF;
  IF COALESCE(TRIM(p_note), '') = '' THEN
    RAISE EXCEPTION 'A note explaining the adjustment is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'User not found: %', p_user_id;
  END IF;

  IF p_delta > 0 THEN
    UPDATE public.token_balances
    SET available_tokens = available_tokens + p_delta,
        lifetime_earned  = lifetime_earned + p_delta,
        updated_at       = NOW()
    WHERE user_id = p_user_id;
  ELSE
    UPDATE public.token_balances
    SET available_tokens = available_tokens + p_delta,   -- p_delta < 0
        lifetime_spent   = lifetime_spent - p_delta,
        updated_at       = NOW()
    WHERE user_id = p_user_id AND available_tokens >= -p_delta;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Insufficient balance for a % clawback', -p_delta;
    END IF;
  END IF;

  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (p_user_id, 'admin_adjustment', p_delta, p_admin,
          'Admin adjustment: ' || TRIM(p_note));

  SELECT available_tokens INTO v_balance
  FROM public.token_balances WHERE user_id = p_user_id;
  RETURN jsonb_build_object('ok', TRUE, 'new_balance', v_balance);
END;
$$;

-- ── 3. marketplace_admin_delist_internal ────────────────────────────────────────
-- Dispute/moderation takedown of an active listing. Identical money semantics to
-- the seller's own delist (mig 155): the escrowed copy returns to the SELLER via
-- chit_grant on the append-only ledger; nothing is confiscated by delisting.
CREATE OR REPLACE FUNCTION public.marketplace_admin_delist_internal(
  p_admin UUID, p_listing_id UUID
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_l public.marketplace_listings%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Not an admin';
  END IF;

  SELECT * INTO v_l FROM public.marketplace_listings WHERE id = p_listing_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Listing not found: %', p_listing_id; END IF;
  IF v_l.status <> 'active' THEN
    RAISE EXCEPTION 'Listing % is not active (%)', p_listing_id, v_l.status;
  END IF;

  PERFORM public.chit_grant(v_l.seller_user_id, v_l.chit_id, 1,
                            'marketplace_return', v_l.id);

  UPDATE public.marketplace_listings
  SET status = 'delisted', closed_at = NOW()
  WHERE id = p_listing_id;
END;
$$;

-- ── 4. Grants: service-only, never client-callable ──────────────────────────────
REVOKE ALL ON FUNCTION public.admin_adjust_tokens_internal(UUID, UUID, INTEGER, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketplace_admin_delist_internal(UUID, UUID)
  FROM PUBLIC, anon, authenticated;

-- ── 5. Apply-time smoke: adjustment credits/debits + audit row + guards ─────────
DO $$
DECLARE
  v_u UUID; v_bal INTEGER; v_cur INTEGER; v_err BOOLEAN;
  v_was_admin BOOLEAN;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  IF v_u IS NULL THEN
    RAISE NOTICE 'admin-ops smoke SKIPPED (no smoke user on this database)';
    RETURN;
  END IF;

  SELECT is_admin INTO v_was_admin FROM public.profiles WHERE id = v_u;
  UPDATE public.profiles SET is_admin = TRUE WHERE id = v_u;
  SELECT available_tokens INTO v_bal FROM public.token_balances WHERE user_id = v_u;

  -- credit 100 → balance +100, ledger row present
  PERFORM public.admin_adjust_tokens_internal(v_u, v_u, 100, 'mig-168 smoke credit');
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u;
  IF v_cur <> v_bal + 100 THEN RAISE EXCEPTION 'SMOKE FAIL: credit must add 100'; END IF;
  -- reference_id is TEXT on prod (drift from mig 002's uuid) — compare as text.
  IF NOT EXISTS (SELECT 1 FROM public.token_transactions
                 WHERE user_id = v_u AND type = 'admin_adjustment'
                   AND amount = 100 AND reference_id::TEXT = v_u::TEXT) THEN
    RAISE EXCEPTION 'SMOKE FAIL: adjustment must land in token_transactions';
  END IF;

  -- clawback back to start
  PERFORM public.admin_adjust_tokens_internal(v_u, v_u, -100, 'mig-168 smoke clawback');
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u;
  IF v_cur <> v_bal THEN RAISE EXCEPTION 'SMOKE FAIL: clawback must restore balance'; END IF;

  -- over-clawback must be blocked by the balance guard
  v_err := FALSE;
  BEGIN
    PERFORM public.admin_adjust_tokens_internal(v_u, v_u, -(v_cur + 1000000), 'overdraw');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: overdraw clawback must RAISE'; END IF;

  -- non-admin caller must be rejected
  UPDATE public.profiles SET is_admin = COALESCE(v_was_admin, FALSE) WHERE id = v_u;
  IF NOT COALESCE(v_was_admin, FALSE) THEN
    v_err := FALSE;
    BEGIN
      PERFORM public.admin_adjust_tokens_internal(v_u, v_u, 10, 'not admin');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE;
    END;
    IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: non-admin must be rejected'; END IF;
  END IF;

  RAISE NOTICE 'admin-ops smoke OK: audited adjust + guards hold';
END $$;
