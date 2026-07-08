-- Migration 156: marketplace M2 — the USD-ready seam (BUILT LIKE-LIVE, SIM BEHIND SWITCHES).
--
-- Two independent switches, both OFF-by-default / founder-gated:
--   1. `platform_integrity_settings.marketplace_usd_lane` (NEW, default FALSE) — whether
--      the marketplace accepts USD listings/purchases AT ALL. Flipping it is the spec §2
--      "USD lane flip" founder decision. While FALSE the lane RAISEs exactly as in M1.
--   2. `battle_payments_mode()` (mig 132) — sim vs live money rail. With the lane ON and
--      mode 'sim', USD sales settle against `sim_usd_balances` (integer cents) via
--      ccg_usd_debit/ccg_usd_credit; in 'live' those fns RAISE until Stripe Treasury
--      lands (the P5 stub) — so the live flip is config + the mig-132 Treasury work,
--      not a marketplace rewrite.
--
-- What M2 adds on the M1 surface:
--   • `currency` branch on list/buy — USD prices come from the SAME pricing row
--     (`usd_cents_snapshot`, frozen at list time), fee in INTEGER CENTS, floor division
--     (Hard Rule 33: integer cents, no floats; token and USD flows NEVER cross —
--     a USD sale writes sim_usd_transactions, never token_transactions);
--   • PROVENANCE LOCK ACTIVATED: a copy acquired with tokens can never be listed for
--     USD (`acquired_currency='token'` on any of the seller's acquisition rows for the
--     chit locks the pair token-resale-only). This is what makes free token emission
--     (signup grants, challenges) structurally unable to reach USD. One-directional:
--     USD-bought copies MAY be relisted for tokens (money → tokens is a sink, safe).
--   • KYC-on-USD gates: seller must be KYC-verified to list USD; buyer must pass
--     `is_eligible_for_real_money` (KYC now; +18/jurisdiction checks activate with
--     live mode — mig 132) to buy USD. Token lane stays KYC-free.
--   • USD fee: recorded as fee_burned and credited to NO ONE in sim. Its live
--     disposition (destroy vs platform retention) is a founder decision at the live
--     flip — tokens burn (deflationary sink); USD "burn" has no economic meaning yet.
--
-- Spec: NORA_PLATFORMS_MARKETPLACE_SPEC.md PHASE M2. Delist needs no change (no money
-- moves; returns escrow regardless of lane state).

-- ── the lane switch ───────────────────────────────────────────────────────────────
ALTER TABLE public.platform_integrity_settings
  ADD COLUMN IF NOT EXISTS marketplace_usd_lane BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.marketplace_usd_enabled()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT marketplace_usd_lane FROM public.platform_integrity_settings WHERE id = TRUE;
$$;

-- ── LIST: currency branch + KYC gate + provenance lock ─────────────────────────────
CREATE OR REPLACE FUNCTION public.marketplace_list_chit_internal(
  p_user UUID, p_chit_id UUID, p_currency TEXT DEFAULT 'token'
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_chit    public.moment_chits%ROWTYPE;
  v_price   public.marketplace_tier_pricing%ROWTYPE;
  v_qty     INTEGER;
  v_active  INTEGER;
  v_listing UUID;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_currency NOT IN ('token','usd') THEN
    RAISE EXCEPTION 'Unknown currency: %', p_currency;
  END IF;

  IF p_currency = 'usd' THEN
    -- Founder gate (spec §2): the lane exists but is OFF until signed off.
    IF NOT public.marketplace_usd_enabled() THEN
      RAISE EXCEPTION 'usd marketplace lane not enabled';
    END IF;
    -- KYC-on-USD-seller (sim: KYC approval; live adds 18+/jurisdiction via mig 132).
    IF NOT public.is_eligible_for_real_money(p_user) THEN
      RAISE EXCEPTION 'USD listings require KYC verification';
    END IF;
    -- PROVENANCE LOCK: token-bought → token-resale-only. Conservative at the
    -- (seller, chit) grain: any token-stamped acquisition locks the pair.
    IF EXISTS (SELECT 1 FROM public.chit_acquisition_ledger
               WHERE user_id = p_user AND chit_id = p_chit_id
                 AND acquired_currency = 'token') THEN
      RAISE EXCEPTION 'Token-bought copies are token-resale-only (provenance lock)';
    END IF;
  END IF;

  -- Serialize this user's listing writes (allowance check + escrow are race-free).
  PERFORM pg_advisory_xact_lock(hashtextextended('marketplace_list:' || p_user::TEXT, 42));

  SELECT * INTO v_chit FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;

  -- Only a live, FINALIZED collectible can be sold: never a retired chit, never a
  -- pending-preview / swap-pending chit (finalized_at gate, migs 140/150).
  IF v_chit.retired_at IS NOT NULL OR NOT v_chit.is_active OR v_chit.finalized_at IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a live, finalized chit', p_chit_id;
  END IF;

  -- Caller must hold a free copy (row-locked: serializes against concurrent spends).
  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_chit_id
  FOR UPDATE;
  IF COALESCE(v_qty, 0) < 1 THEN
    RAISE EXCEPTION 'You do not hold a copy of chit %', p_chit_id;
  END IF;

  -- Never list a wager-staked chit (its copy is spoken for until the match resolves).
  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE user_id = p_user AND chit_id = p_chit_id AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_chit_id;
  END IF;

  -- One open listing per (seller, chit) — friendly error ahead of the unique index.
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE seller_user_id = p_user AND chit_id = p_chit_id AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is already listed', p_chit_id;
  END IF;

  -- Concurrent-listing allowance (default 1 — the "one active listing" rule).
  SELECT COUNT(*) INTO v_active FROM public.marketplace_listings
  WHERE seller_user_id = p_user AND status = 'active';
  IF v_active >= public.marketplace_listing_allowance(p_user) THEN
    RAISE EXCEPTION 'Listing allowance reached (% active)', v_active;
  END IF;

  -- Snapshot BOTH fixed prices for the chit's CURRENT tier (config, mig 153); the
  -- listing's currency decides which one the buy settles in.
  SELECT * INTO v_price FROM public.marketplace_tier_pricing WHERE tier = v_chit.tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'No marketplace pricing for tier %', v_chit.tier; END IF;

  INSERT INTO public.marketplace_listings
    (chit_id, seller_user_id, currency, tier_snapshot,
     price_snapshot, fee_bps_snapshot, usd_cents_snapshot)
  VALUES
    (p_chit_id, p_user, p_currency, v_chit.tier,
     v_price.token_price, v_price.fee_bps, v_price.usd_cents)
  RETURNING id INTO v_listing;

  -- Escrow: the copy leaves the seller's holdings (append-only ledger, mig 142 pattern).
  PERFORM public.chit_grant(p_user, p_chit_id, -1, 'marketplace_escrow', v_listing);

  RETURN v_listing;
END;
$$;

-- Wrapper grows the currency arg (default token). Drop the M1 1-arg form so PostgREST
-- never sees an ambiguous overload.
DROP FUNCTION public.marketplace_list_chit(UUID);
CREATE FUNCTION public.marketplace_list_chit(p_chit_id UUID, p_currency TEXT DEFAULT 'token')
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_list_chit_internal(auth.uid(), p_chit_id, p_currency);
$$;

-- ── BUY: currency branch — USD settles on the mig-132 rail, tokens as in M1 ────────
CREATE OR REPLACE FUNCTION public.marketplace_buy_chit_internal(p_buyer UUID, p_listing_id UUID)
RETURNS UUID   -- the marketplace_sales receipt id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_l     public.marketplace_listings%ROWTYPE;
  v_gross INTEGER;
  v_fee   INTEGER;
  v_net   INTEGER;
  v_sale  UUID;
BEGIN
  IF p_buyer IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  -- Row lock: one buyer wins; everyone else sees 'sold' below.
  SELECT * INTO v_l FROM public.marketplace_listings WHERE id = p_listing_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Listing not found: %', p_listing_id; END IF;

  -- Idempotent replay: if THIS buyer already bought this listing, return the existing
  -- receipt — a retried request is a no-op, never a double-spend.
  IF v_l.status = 'sold' THEN
    SELECT id INTO v_sale FROM public.marketplace_sales
    WHERE listing_id = p_listing_id AND buyer_user_id = p_buyer;
    IF v_sale IS NOT NULL THEN RETURN v_sale; END IF;
    RAISE EXCEPTION 'Listing % is already sold', p_listing_id;
  END IF;
  IF v_l.status <> 'active' THEN
    RAISE EXCEPTION 'Listing % is not active (%)', p_listing_id, v_l.status;
  END IF;
  IF p_buyer = v_l.seller_user_id THEN
    RAISE EXCEPTION 'Cannot buy your own listing';
  END IF;

  IF v_l.currency = 'usd' THEN
    -- Lane may have been switched off between list and buy: block NEW settlements
    -- (the seller can still delist — no money moves there).
    IF NOT public.marketplace_usd_enabled() THEN
      RAISE EXCEPTION 'usd marketplace lane not enabled';
    END IF;
    -- KYC-on-USD-buyer (sim: KYC; live adds 18+/jurisdiction — mig 132).
    IF NOT public.is_eligible_for_real_money(p_buyer) THEN
      RAISE EXCEPTION 'USD purchases require KYC verification';
    END IF;

    v_gross := v_l.usd_cents_snapshot;                     -- INTEGER CENTS (HR33)
    v_fee   := (v_gross * v_l.fee_bps_snapshot) / 10000;   -- integer floor
    v_net   := v_gross - v_fee;

    -- The mig-132 rail: sim debits/credits sim_usd_balances; live RAISEs until
    -- Stripe Treasury/Connect lands. The fee is debited but credited to NO ONE
    -- (recorded as fee_burned; live disposition is a founder decision at the flip).
    PERFORM public.ccg_usd_debit(p_buyer, v_gross, v_l.id,
      'Marketplace: bought ' || v_l.tier_snapshot || '-tier chit');
    PERFORM public.ccg_usd_credit(v_l.seller_user_id, v_net, v_l.id,
      'Marketplace: sold ' || v_l.tier_snapshot || '-tier chit'
        || CASE WHEN v_fee > 0 THEN ' (' || v_fee || 'c fee withheld)' ELSE '' END);
    -- NO token_transactions here — token and USD economies never cross (HR33).
  ELSE
    v_gross := v_l.price_snapshot;                          -- tokens
    v_fee   := (v_gross * v_l.fee_bps_snapshot) / 10000;    -- integer floor
    v_net   := v_gross - v_fee;

    -- Debit buyer the gross price (guarded — mirrors _barter_move_tokens, mig 119).
    UPDATE public.token_balances
    SET available_tokens = available_tokens - v_gross,
        lifetime_spent   = lifetime_spent + v_gross,
        updated_at       = NOW()
    WHERE user_id = p_buyer AND available_tokens >= v_gross;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;

    -- Credit seller the NET (single sanctioned write path — Hard Rule 5 + governance).
    PERFORM public.increment_token_balance(v_l.seller_user_id, v_net);

    INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
    VALUES
      (p_buyer, 'chit_purchase', -v_gross, v_l.id,
       'Marketplace: bought ' || v_l.tier_snapshot || '-tier chit'),
      (v_l.seller_user_id, 'chit_sale', v_net, v_l.id,
       'Marketplace: sold ' || v_l.tier_snapshot || '-tier chit'
         || CASE WHEN v_fee > 0 THEN ' (' || v_fee || ' fee burned)' ELSE '' END);
  END IF;

  -- Ownership transfer: the escrowed copy lands with the buyer via a NEW acquisition-
  -- ledger row (append-only, Hard Rule 29), stamped with the settlement currency —
  -- the provenance the LIST-side lock reads. Attribution (original_minter_handle /
  -- card_serial) lives on the chit definition — untouched by transfer.
  INSERT INTO public.chit_acquisition_ledger
    (user_id, chit_id, quantity_delta, reason, reference_id,
     counterparty_user_id, acquired_currency)
  VALUES
    (p_buyer, v_l.chit_id, 1, 'marketplace_purchase', v_l.id,
     v_l.seller_user_id, v_l.currency);

  UPDATE public.marketplace_listings
  SET status = 'sold', closed_at = NOW()
  WHERE id = p_listing_id;

  INSERT INTO public.marketplace_sales
    (listing_id, chit_id, buyer_user_id, seller_user_id,
     currency, gross_price, fee_burned, net_to_seller)
  VALUES
    (v_l.id, v_l.chit_id, p_buyer, v_l.seller_user_id,
     v_l.currency, v_gross, v_fee, v_net)
  RETURNING id INTO v_sale;

  RETURN v_sale;
END;
$$;

COMMENT ON COLUMN public.marketplace_sales.gross_price IS
  'In the sale currency''s integer minor unit: tokens for token sales, CENTS for usd sales (HR33).';

-- ── grants (list wrapper was dropped/recreated; internals stay service-only) ───────
REVOKE ALL ON FUNCTION public.marketplace_list_chit(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_list_chit(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.marketplace_usd_enabled() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_usd_enabled() TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE: gates OFF→ON→OFF inside this transaction (end state: lane OFF).
-- Proves: lane gate · KYC gates · provenance lock · sim-USD settlement in integer
-- cents with fee withheld · currency wall (token_balances untouched by a USD sale) ·
-- idempotent replay · token lane unaffected by the lane switch.
-- Same smoke identities as mig 155 (residue discipline per mig 142; P7 sweeps).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;                  -- seller, buyer
  v_cS UUID; v_cT UUID;                  -- S-tier (USD sale) + C-tier (token-provenance)
  v_k1 UUID; v_k2 UUID;                  -- smoke KYC rows (deleted at cleanup)
  v_lT UUID; v_lS UUID; v_lC UUID;
  v_sale UUID; v_sale2 UUID;
  v_tok1 INTEGER; v_tok2 INTEGER;        -- token balances at smoke start (restored at cleanup)
  v_wall1 INTEGER; v_wall2 INTEGER;      -- token balances just before the USD sale (wall assert)
  v_usd1 BIGINT; v_usd2 BIGINT;          -- sim USD balances
  v_cur BIGINT; v_q INTEGER;
  v_err BOOLEAN; v_txt TEXT;
  v_row RECORD;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN
    RAISE EXCEPTION 'M2 smoke requires the mig-155 smoke users';
  END IF;
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'MKT M2 smoke SKIPPED (battle_payments_mode is live — sim rail unavailable)';
    RETURN;
  END IF;

  -- Smoke chits: S for the USD sale, C for the token-provenance setup.
  v_cS := public.create_moment_chit('MKT M2 smoke S', 'athlete', 'creature', 'S');
  v_cT := public.create_moment_chit('MKT M2 smoke C', 'musician', 'creature', 'C');
  UPDATE public.moment_chits
  SET finalized_at = NOW(), original_minter_handle = '@mkt_smoke_minter'
  WHERE id IN (v_cS, v_cT);
  PERFORM public.chit_grant(v_u1, v_cS, 1, 'event');
  PERFORM public.chit_grant(v_u2, v_cT, 1, 'event');

  SELECT available_tokens INTO v_tok1 FROM public.token_balances WHERE user_id = v_u1;
  SELECT available_tokens INTO v_tok2 FROM public.token_balances WHERE user_id = v_u2;

  -- ── 1. lane OFF (default): USD listing must RAISE ────────────────────────────
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cS, 'usd');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: usd lane must be OFF by default'; END IF;

  -- ── 2. lane ON, no KYC: seller gate must RAISE ───────────────────────────────
  UPDATE public.platform_integrity_settings SET marketplace_usd_lane = TRUE WHERE id = TRUE;
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cS, 'usd');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: USD listing must require seller KYC'; END IF;

  -- KYC-approve both smoke users (rows deleted at cleanup).
  INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u1, 'approved')
  RETURNING id INTO v_k1;
  INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u2, 'approved')
  RETURNING id INTO v_k2;

  -- ── 3. provenance lock: u1 token-buys cT, then may NOT USD-list it ───────────
  v_lT := public.marketplace_list_chit_internal(v_u2, v_cT, 'token');
  PERFORM public.increment_token_balance(v_u1, 1000);
  PERFORM public.marketplace_buy_chit_internal(v_u1, v_lT);   -- u1 now token-bought cT
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cT, 'usd');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: token-bought copy must be token-resale-only'; END IF;

  -- ── 4. USD sale on the sim rail: integer cents, fee withheld, wall intact ────
  PERFORM public.sim_seed_balance(v_u1);
  PERFORM public.sim_seed_balance(v_u2);
  SELECT balance_usd_cents INTO v_usd1 FROM public.sim_usd_balances WHERE user_id = v_u1;
  SELECT balance_usd_cents INTO v_usd2 FROM public.sim_usd_balances WHERE user_id = v_u2;
  SELECT available_tokens INTO v_wall1 FROM public.token_balances WHERE user_id = v_u1;
  SELECT available_tokens INTO v_wall2 FROM public.token_balances WHERE user_id = v_u2;

  v_lS := public.marketplace_list_chit_internal(v_u1, v_cS, 'usd');
  SELECT * INTO v_row FROM public.marketplace_listings WHERE id = v_lS;
  IF v_row.currency <> 'usd' OR v_row.usd_cents_snapshot <> 10000 OR v_row.fee_bps_snapshot <> 1500 THEN
    RAISE EXCEPTION 'SMOKE FAIL: usd listing snapshots wrong';
  END IF;

  v_sale := public.marketplace_buy_chit_internal(v_u2, v_lS);
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u2;
  IF v_cur <> v_usd2 - 10000 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must be debited 10000c'; END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u1;
  IF v_cur <> v_usd1 + 8500 THEN RAISE EXCEPTION 'SMOKE FAIL: seller must net 8500c'; END IF;
  SELECT * INTO v_row FROM public.marketplace_sales WHERE id = v_sale;
  IF v_row.currency <> 'usd' OR v_row.gross_price <> 10000
     OR v_row.fee_burned <> 1500 OR v_row.net_to_seller <> 8500 THEN
    RAISE EXCEPTION 'SMOKE FAIL: usd sale receipt wrong';
  END IF;
  -- currency wall: the USD sale must not have touched token balances (HR33)
  IF (SELECT available_tokens FROM public.token_balances WHERE user_id = v_u1) <> v_wall1
     OR (SELECT available_tokens FROM public.token_balances WHERE user_id = v_u2) <> v_wall2 THEN
    RAISE EXCEPTION 'SMOKE FAIL: USD sale crossed the currency wall';
  END IF;
  -- provenance stamp
  IF NOT EXISTS (SELECT 1 FROM public.chit_acquisition_ledger
                 WHERE user_id = v_u2 AND chit_id = v_cS
                   AND reason = 'marketplace_purchase' AND acquired_currency = 'usd') THEN
    RAISE EXCEPTION 'SMOKE FAIL: usd buy must stamp acquired_currency=usd';
  END IF;

  -- ── 5. replay is a no-op ──────────────────────────────────────────────────────
  v_sale2 := public.marketplace_buy_chit_internal(v_u2, v_lS);
  IF v_sale2 IS DISTINCT FROM v_sale THEN RAISE EXCEPTION 'SMOKE FAIL: replayed usd buy must return same receipt'; END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u2;
  IF v_cur <> v_usd2 - 10000 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed usd buy must not double-debit'; END IF;

  -- ── 6. lane back OFF: USD blocked again; token lane unaffected ────────────────
  UPDATE public.platform_integrity_settings SET marketplace_usd_lane = FALSE WHERE id = TRUE;
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cT, 'usd');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: usd lane must re-gate when switched off'; END IF;
  v_lC := public.marketplace_list_chit_internal(v_u1, v_cT, 'token');
  PERFORM public.marketplace_delist_chit_internal(v_u1, v_lC);
  SELECT status INTO v_txt FROM public.marketplace_listings WHERE id = v_lC;
  IF v_txt <> 'delisted' THEN RAISE EXCEPTION 'SMOKE FAIL: token lane must work with usd lane off'; END IF;

  -- ── cleanup: KYC rows out, holdings compensated, balances restored, chits retired.
  --    sim_usd_balances residue stays on the smoke identities (sim-only fake money,
  --    P7 sweeps them with the users). ─────────────────────────────────────────────
  DELETE FROM public.kyc_verifications WHERE id IN (v_k1, v_k2);
  PERFORM public.chit_grant(v_u2, v_cS, -1, 'platform_correction');
  PERFORM public.chit_grant(v_u1, v_cT, -1, 'platform_correction');
  SELECT available_tokens INTO v_q FROM public.token_balances WHERE user_id = v_u1;
  PERFORM public.increment_token_balance(v_u1, v_tok1 - v_q);
  SELECT available_tokens INTO v_q FROM public.token_balances WHERE user_id = v_u2;
  PERFORM public.increment_token_balance(v_u2, v_tok2 - v_q);
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_cS, v_cT);

  RAISE NOTICE 'MKT M2 smoke OK: lane gated, KYC gated, provenance locked, sim USD sale 10000c (fee 1500c withheld), currency wall intact';
END $$;
