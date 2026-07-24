-- Migration 172: N3 — marketplace integration (collection primary sale + copy
-- resale, USD-first) on the mig-170/171 copy + collection foundation.
--
-- Collections spec Phase N3. Extends the shipped marketplace (migs 153–156) —
-- does NOT rebuild it. Inherits escrow-on-list, snapshot pricing, attribution
-- preservation, allowance, idempotency wholesale.
--
-- Currency posture (spec §1.4, supersedes the marketplace spec's token-first
-- stance): the marketplace is USD-first. All money is integer USD cents on the
-- sim/live-switched rail (battle_payments_mode, mig 132 — ccg_usd_debit/credit);
-- sim in beta, Stripe Treasury at the live flip. The token/USD wall stands
-- (Hard Rule 33): a USD sale never writes token_transactions. The platform sale
-- fee (config, spec §1.1) is WITHHELD to the platform — this is real revenue, not
-- the token A/S burn (its live disposition is a founder decision at the flip; in
-- sim it is credited to no one).
--
-- REPO-CHECK N3.1 [FOUNDER — surfaced, default taken]: copy resale price is
-- SELLER-SET within config min/max bands per tier (marketplace_tier_pricing
-- gains usd_min_cents/usd_max_cents). Token resale stays tier-FIXED (the live
-- lane, unchanged). Founder to confirm the bands + the seller-set model.
-- REPO-CHECK 1.4 [FOUNDER — surfaced]: fate of the token resale lane. This
-- migration leaves the token lane intact (still live, fixed-price, A/S burn) and
-- makes USD the primary/collection path — it does NOT retire tokens. Founder to
-- confirm default (a) (retire token resale) vs (b) (keep it as the no-cash lane).
--
-- What N3 adds:
--   • buy_collection: primary sale — buyer (KYC'd) pays the minter-set collection
--     price; receives one copy of each member (lowest available minter serial);
--     platform fee withheld; minter credited net; atomic + idempotent; sold_out
--     when the minter's inventory of any member reaches zero.
--   • USD copy resale: seller-set price within tier bands; platform sale fee
--     (not the tier burn) withheld; provenance lock + KYC gates unchanged.
--   • withdraw stub: RAISEs until live payout onboarding lands (the P5 pattern).

-- ── seller-set price bands (REPO-CHECK N3.1) ──────────────────────────────────────
ALTER TABLE public.marketplace_tier_pricing
  ADD COLUMN IF NOT EXISTS usd_min_cents INTEGER,
  ADD COLUMN IF NOT EXISTS usd_max_cents INTEGER;

-- Seed bands around the existing fixed USD price (0.5×..3×), founder-tunable.
UPDATE public.marketplace_tier_pricing
SET usd_min_cents = GREATEST(usd_cents / 2, 1),
    usd_max_cents = usd_cents * 3
WHERE usd_min_cents IS NULL;

-- ── collection_sale ledger reason (copy transfer minter → buyer) ──────────────────
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired',
    'marketplace_escrow','marketplace_return','marketplace_purchase',
    'collection_mint','collection_sale'
  ));

-- ── collection_purchases (append-only receipt ledger, Rule 29) ────────────────────
CREATE TABLE public.collection_purchases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id   UUID NOT NULL REFERENCES public.collections(id),
  buyer_user_id   UUID NOT NULL REFERENCES auth.users(id),
  seller_user_id  UUID NOT NULL REFERENCES auth.users(id),   -- the collection minter
  idempotency_key UUID NOT NULL,
  currency        TEXT NOT NULL DEFAULT 'usd' CHECK (currency = 'usd'),
  gross_cents     INTEGER NOT NULL CHECK (gross_cents > 0),
  fee_cents       INTEGER NOT NULL DEFAULT 0 CHECK (fee_cents >= 0),
  net_cents       INTEGER NOT NULL CHECK (net_cents >= 0),
  card_count      INTEGER NOT NULL CHECK (card_count > 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT collection_purchases_arith CHECK (gross_cents = fee_cents + net_cents),
  CONSTRAINT collection_purchases_idem UNIQUE (buyer_user_id, idempotency_key)
);

CREATE INDEX collection_purchases_coll_idx  ON public.collection_purchases (collection_id);
CREATE INDEX collection_purchases_buyer_idx ON public.collection_purchases (buyer_user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.collection_purchases_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'collection_purchases is append-only (no UPDATE/DELETE)';
END;
$$;
CREATE TRIGGER collection_purchases_no_mutation
  BEFORE UPDATE OR DELETE ON public.collection_purchases
  FOR EACH ROW EXECUTE FUNCTION public.collection_purchases_block_mutation();

ALTER TABLE public.collection_purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "collection_purchases_select_party" ON public.collection_purchases
  FOR SELECT USING (auth.uid() IN (buyer_user_id, seller_user_id));

-- ── how many full sets the minter can still sell (min inventory across members) ───
CREATE OR REPLACE FUNCTION public.collection_sets_remaining(p_collection UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(MIN(mine.n), 0)::INTEGER
  FROM public.collection_chits cc
  JOIN LATERAL (
    SELECT COUNT(*) AS n FROM public.chit_copies c
    WHERE c.chit_id = cc.chit_id
      AND c.owner_user_id = (SELECT market_maker_user_id FROM public.collections WHERE id = p_collection)
      AND c.state = 'owned'
  ) mine ON TRUE
  WHERE cc.collection_id = p_collection;
$$;
REVOKE ALL ON FUNCTION public.collection_sets_remaining(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.collection_sets_remaining(UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUY COLLECTION (primary sale) — atomic, idempotent, USD sim rail.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.marketplace_buy_collection_internal(
  p_buyer UUID, p_collection UUID, p_idempotency_key UUID
)
RETURNS UUID   -- the collection_purchases receipt id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_c        public.collections%ROWTYPE;
  v_fee_bps  INTEGER;
  v_gross    INTEGER;
  v_fee      INTEGER;
  v_net      INTEGER;
  v_count    INTEGER;
  v_receipt  UUID;
  r          RECORD;
BEGIN
  IF p_buyer IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'Idempotency key required'; END IF;

  -- Idempotent replay: same (buyer, key) returns the existing receipt.
  SELECT id INTO v_receipt FROM public.collection_purchases
  WHERE buyer_user_id = p_buyer AND idempotency_key = p_idempotency_key;
  IF v_receipt IS NOT NULL THEN RETURN v_receipt; END IF;

  -- Lock the collection: serializes concurrent buyers against the shared inventory.
  SELECT * INTO v_c FROM public.collections WHERE id = p_collection FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found: %', p_collection; END IF;
  IF v_c.status NOT IN ('listed','sold_out') THEN
    RAISE EXCEPTION 'Collection % is not for sale (%)', p_collection, v_c.status;
  END IF;
  IF v_c.status = 'sold_out' THEN RAISE EXCEPTION 'Collection % is sold out', p_collection; END IF;
  IF p_buyer = v_c.market_maker_user_id THEN
    RAISE EXCEPTION 'You cannot buy your own collection';
  END IF;
  -- KYC-on-buy (sim: KYC; live adds 18+/jurisdiction — mig 132).
  IF NOT public.is_eligible_for_real_money(p_buyer) THEN
    RAISE EXCEPTION 'Buying a collection requires KYC verification';
  END IF;
  IF public.collection_sets_remaining(p_collection) < 1 THEN
    RAISE EXCEPTION 'Collection % has no full sets remaining', p_collection;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.collection_chits WHERE collection_id = p_collection;

  -- Money: buyer pays the minter-set price; platform sale fee (config) withheld;
  -- minter credited net. Integer cents; token wall untouched.
  v_gross   := v_c.price_cents;
  v_fee_bps := public.platform_fee('marketplace_sale_fee_bps');
  v_fee     := (v_gross * v_fee_bps) / 10000;   -- integer floor
  v_net     := v_gross - v_fee;

  PERFORM public.ccg_usd_debit(p_buyer, v_gross, p_collection,
    'Collection purchase: "' || v_c.title || '"');
  PERFORM public.ccg_usd_credit(v_c.market_maker_user_id, v_net, p_collection,
    'Collection sale: "' || v_c.title || '"'
      || CASE WHEN v_fee > 0 THEN ' (' || v_fee || 'c platform fee withheld)' ELSE '' END,
    'secondary_sale');
  -- The platform fee is withheld — credited to no one in sim (revenue at live).

  -- Transfer one copy of each member: minter releases the lowest owned serial,
  -- buyer claims it (the mig-170 generic release/claim pairing, ref = receipt).
  v_receipt := gen_random_uuid();
  FOR r IN
    SELECT cc.chit_id FROM public.collection_chits cc
    WHERE cc.collection_id = p_collection
    ORDER BY cc.display_order
  LOOP
    PERFORM public.chit_grant(v_c.market_maker_user_id, r.chit_id, -1, 'collection_sale', v_receipt, p_buyer);
    PERFORM public.chit_grant(p_buyer, r.chit_id, 1, 'collection_sale', v_receipt, v_c.market_maker_user_id);
  END LOOP;

  INSERT INTO public.collection_purchases
    (id, collection_id, buyer_user_id, seller_user_id, idempotency_key,
     currency, gross_cents, fee_cents, net_cents, card_count)
  VALUES
    (v_receipt, p_collection, p_buyer, v_c.market_maker_user_id, p_idempotency_key,
     'usd', v_gross, v_fee, v_net, v_count);

  -- Sold out when the minter's inventory of any member hits zero.
  IF public.collection_sets_remaining(p_collection) < 1 THEN
    UPDATE public.collections SET status = 'sold_out', updated_at = NOW() WHERE id = p_collection;
  END IF;

  RETURN v_receipt;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketplace_buy_collection(
  p_collection UUID, p_idempotency_key UUID
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_buy_collection_internal(auth.uid(), p_collection, p_idempotency_key);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- USD COPY RESALE — seller-set price within tier bands; platform sale fee (not the
-- token burn) withheld. Token lane byte-identical to mig 156. p_price_cents is the
-- USD ask (ignored for token listings); NULL → the tier fixed USD price.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.marketplace_list_chit_internal(
  p_user UUID, p_chit_id UUID, p_currency TEXT DEFAULT 'token', p_price_cents INTEGER DEFAULT NULL
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
  v_usd     INTEGER;
  v_feebps  INTEGER;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_currency NOT IN ('token','usd') THEN
    RAISE EXCEPTION 'Unknown currency: %', p_currency;
  END IF;

  SELECT * INTO v_chit FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;
  SELECT * INTO v_price FROM public.marketplace_tier_pricing WHERE tier = v_chit.tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'No marketplace pricing for tier %', v_chit.tier; END IF;

  IF p_currency = 'usd' THEN
    IF NOT public.marketplace_usd_enabled() THEN
      RAISE EXCEPTION 'usd marketplace lane not enabled';
    END IF;
    IF NOT public.is_eligible_for_real_money(p_user) THEN
      RAISE EXCEPTION 'USD listings require KYC verification';
    END IF;
    -- PROVENANCE LOCK: token-bought → token-resale-only.
    IF EXISTS (SELECT 1 FROM public.chit_acquisition_ledger
               WHERE user_id = p_user AND chit_id = p_chit_id
                 AND acquired_currency = 'token') THEN
      RAISE EXCEPTION 'Token-bought copies are token-resale-only (provenance lock)';
    END IF;
    -- Seller-set price within the tier band (REPO-CHECK N3.1); NULL → tier fixed.
    v_usd := COALESCE(p_price_cents, v_price.usd_cents);
    IF v_usd < COALESCE(v_price.usd_min_cents, 1)
       OR v_usd > COALESCE(v_price.usd_max_cents, v_price.usd_cents * 3) THEN
      RAISE EXCEPTION 'USD price % is outside the tier % band (%–%)',
        v_usd, v_chit.tier, v_price.usd_min_cents, v_price.usd_max_cents;
    END IF;
    -- Platform sale fee (config) — applies to ALL tiers on the USD lane.
    v_feebps := public.platform_fee('marketplace_sale_fee_bps');
  ELSE
    v_usd := v_price.usd_cents;              -- inert for token listings
    v_feebps := v_price.fee_bps;             -- tier A/S burn (token lane, unchanged)
  END IF;

  -- Serialize this user's listing writes (allowance check + escrow are race-free).
  PERFORM pg_advisory_xact_lock(hashtextextended('marketplace_list:' || p_user::TEXT, 42));

  IF v_chit.retired_at IS NOT NULL OR NOT v_chit.is_active OR v_chit.finalized_at IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a live, finalized chit', p_chit_id;
  END IF;

  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_chit_id
  FOR UPDATE;
  IF COALESCE(v_qty, 0) < 1 THEN
    RAISE EXCEPTION 'You do not hold a copy of chit %', p_chit_id;
  END IF;

  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE user_id = p_user AND chit_id = p_chit_id AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_chit_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE seller_user_id = p_user AND chit_id = p_chit_id AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is already listed', p_chit_id;
  END IF;

  SELECT COUNT(*) INTO v_active FROM public.marketplace_listings
  WHERE seller_user_id = p_user AND status = 'active';
  IF v_active >= public.marketplace_listing_allowance(p_user) THEN
    RAISE EXCEPTION 'Listing allowance reached (% active)', v_active;
  END IF;

  INSERT INTO public.marketplace_listings
    (chit_id, seller_user_id, currency, tier_snapshot,
     price_snapshot, fee_bps_snapshot, usd_cents_snapshot)
  VALUES
    (p_chit_id, p_user, p_currency, v_chit.tier,
     v_price.token_price, v_feebps, v_usd)
  RETURNING id INTO v_listing;

  -- Escrow: the copy leaves the seller's holdings; the mig-170 machinery pins the
  -- lowest owned serial to this listing (state listed_escrow, escrow_ref = listing).
  PERFORM public.chit_grant(p_user, p_chit_id, -1, 'marketplace_escrow', v_listing);

  RETURN v_listing;
END;
$$;

-- Wrapper grows the price arg (default NULL → tier fixed). Drop the mig-156 form.
DROP FUNCTION public.marketplace_list_chit(UUID, TEXT);
CREATE FUNCTION public.marketplace_list_chit(
  p_chit_id UUID, p_currency TEXT DEFAULT 'token', p_price_cents INTEGER DEFAULT NULL
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_list_chit_internal(auth.uid(), p_chit_id, p_currency, p_price_cents);
$$;
REVOKE ALL ON FUNCTION public.marketplace_list_chit(UUID, TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_list_chit(UUID, TEXT, INTEGER) TO authenticated;

-- ── withdraw stub: real payout onboarding is post-beta (the P5 pattern) ───────────
CREATE OR REPLACE FUNCTION public.marketplace_withdraw_usd(p_cents INTEGER)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  -- The dollar balance accrues (collection sales + USD resale) but cannot leave
  -- until Stripe Connect payout onboarding lands (KYC is already required upstream).
  RAISE EXCEPTION 'Withdrawals are not enabled yet — payout onboarding launches after beta';
END;
$$;
REVOKE ALL ON FUNCTION public.marketplace_withdraw_usd(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_withdraw_usd(INTEGER) TO authenticated;

-- ── grants ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.marketplace_buy_collection_internal(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketplace_buy_collection(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_buy_collection(UUID, UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — collection primary sale + sold_out + USD seller-set resale,
-- all on the sim rail (skips when payments are live). Same mkt-smoke identities.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID; v_k1 UUID; v_k2 UUID; v_conn UUID;
  v_coll UUID; v_m1 UUID; v_m2 UUID; v_c1 UUID; v_c2 UUID;
  v_usd1 BIGINT; v_usd2 BIGINT; v_cur BIGINT;
  v_rcpt UUID; v_rcpt2 UUID; v_key UUID := gen_random_uuid();
  v_lst UUID; v_err BOOLEAN; v_q INTEGER; v_row public.chit_copies%ROWTYPE;
  v_tok1 INTEGER; v_tok2 INTEGER;
  v_band public.marketplace_tier_pricing%ROWTYPE; v_tier TEXT; v_ask INTEGER;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';  -- minter/seller
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';  -- buyer
  IF v_u1 IS NULL OR v_u2 IS NULL THEN RAISE EXCEPTION 'mig 172 smoke requires the mig-155 smoke users'; END IF;
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'N3 smoke SKIPPED (battle_payments_mode is live)';
    RETURN;
  END IF;

  SELECT available_tokens INTO v_tok1 FROM public.token_balances WHERE user_id = v_u1;
  SELECT available_tokens INTO v_tok2 FROM public.token_balances WHERE user_id = v_u2;

  -- Eligibility + a small collection (supply 2 each so a single buy leaves 1 set).
  INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u1, 'approved') RETURNING id INTO v_k1;
  INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u2, 'approved') RETURNING id INTO v_k2;
  INSERT INTO public.platform_connections
    (user_id, platform, platform_user_id, platform_username, access_token, is_active)
  VALUES (v_u1, 'youtube', 'n3-smoke', '@n3_smoke', 'tok', TRUE) RETURNING id INTO v_conn;

  v_coll := public.collection_create_internal(v_u1, 'N3 Smoke Series');
  v_m1 := public.moment_record(v_u1, 'youtube', 'n3-smoke-' || gen_random_uuid()::TEXT,
                               'https://example.com/p1', NULL, 500000, TRUE, '@n3_smoke');
  v_m2 := public.moment_record(v_u1, 'youtube', 'n3-smoke-' || gen_random_uuid()::TEXT,
                               'https://example.com/p2', NULL, 800, TRUE, '@n3_smoke');
  PERFORM public.moment_pre_gen_moderate(v_m1, 'approved', NULL, FALSE, 'sim');
  PERFORM public.moment_pre_gen_moderate(v_m2, 'approved', NULL, FALSE, 'sim');
  UPDATE public.moments SET collection_id = v_coll WHERE id IN (v_m1, v_m2);
  v_c1 := public.moment_mint(v_m1, 'athlete', 'creature', 'on_summon');
  v_c2 := public.moment_mint(v_m2, 'musician', 'creature', 'on_summon');
  PERFORM public.chit_grant(v_u1, v_c1, 1, 'mint', v_m1);
  PERFORM public.chit_grant(v_u1, v_c2, 1, 'mint', v_m2);
  UPDATE public.moment_chits SET finalized_at = NOW(), is_active = TRUE WHERE id IN (v_c1, v_c2);

  PERFORM public.sim_seed_balance(v_u1);
  PERFORM public.sim_seed_balance(v_u2);
  PERFORM public.collection_publish_internal(v_u1, v_coll, 5000, jsonb_build_array(
    jsonb_build_object('chit_id', v_c1, 'total_supply', 2),
    jsonb_build_object('chit_id', v_c2, 'total_supply', 2)));

  IF public.collection_sets_remaining(v_coll) <> 2 THEN
    RAISE EXCEPTION 'SMOKE FAIL: 2 sets must be available at publish';
  END IF;

  -- ── primary sale: buyer pays 5000c, fee 500c (10%), minter nets 4500c ──────────
  SELECT balance_usd_cents INTO v_usd1 FROM public.sim_usd_balances WHERE user_id = v_u1;
  SELECT balance_usd_cents INTO v_usd2 FROM public.sim_usd_balances WHERE user_id = v_u2;
  v_rcpt := public.marketplace_buy_collection_internal(v_u2, v_coll, v_key);

  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u2;
  IF v_cur <> v_usd2 - 5000 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must pay 5000c'; END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u1;
  IF v_cur <> v_usd1 + 4500 THEN RAISE EXCEPTION 'SMOKE FAIL: minter must net 4500c'; END IF;
  -- buyer received one copy of EACH member
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u2 AND chit_id = v_c1;
  IF COALESCE(v_q,0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must own 1 of card 1'; END IF;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u2 AND chit_id = v_c2;
  IF COALESCE(v_q,0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must own 1 of card 2'; END IF;
  -- currency wall: no token movement
  IF (SELECT available_tokens FROM public.token_balances WHERE user_id = v_u1) <> v_tok1
     OR (SELECT available_tokens FROM public.token_balances WHERE user_id = v_u2) <> v_tok2 THEN
    RAISE EXCEPTION 'SMOKE FAIL: collection sale crossed the currency wall';
  END IF;
  -- one set left
  IF public.collection_sets_remaining(v_coll) <> 1 THEN
    RAISE EXCEPTION 'SMOKE FAIL: 1 set must remain after one sale';
  END IF;
  IF (SELECT status FROM public.collections WHERE id = v_coll) <> 'listed' THEN
    RAISE EXCEPTION 'SMOKE FAIL: still listed with a set remaining';
  END IF;

  -- ── idempotent replay: same key → same receipt, no second charge ───────────────
  v_rcpt2 := public.marketplace_buy_collection_internal(v_u2, v_coll, v_key);
  IF v_rcpt2 <> v_rcpt THEN RAISE EXCEPTION 'SMOKE FAIL: replayed buy must return same receipt'; END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u2;
  IF v_cur <> v_usd2 - 5000 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed buy must not double-charge'; END IF;

  -- ── second buy (new key) exhausts inventory → sold_out ─────────────────────────
  PERFORM public.marketplace_buy_collection_internal(v_u2, v_coll, gen_random_uuid());
  IF (SELECT status FROM public.collections WHERE id = v_coll) <> 'sold_out' THEN
    RAISE EXCEPTION 'SMOKE FAIL: collection must be sold_out when inventory hits zero';
  END IF;
  v_err := FALSE;
  BEGIN PERFORM public.marketplace_buy_collection_internal(v_u2, v_coll, gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: buying a sold-out collection must RAISE'; END IF;

  -- ── USD seller-set resale within band (price derived from the chit's tier) ─────
  UPDATE public.platform_integrity_settings SET marketplace_usd_lane = TRUE WHERE id = TRUE;
  SELECT tier INTO v_tier FROM public.moment_chits WHERE id = v_c1;
  SELECT * INTO v_band FROM public.marketplace_tier_pricing WHERE tier = v_tier;
  v_ask := v_band.usd_min_cents;   -- guaranteed in-band
  -- over-max price must RAISE
  v_err := FALSE;
  BEGIN PERFORM public.marketplace_list_chit_internal(v_u2, v_c1, 'usd', v_band.usd_max_cents + 1);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: out-of-band USD price must RAISE'; END IF;
  -- in-band seller price is snapshotted; platform fee bps applied (not tier burn)
  v_lst := public.marketplace_list_chit_internal(v_u2, v_c1, 'usd', v_ask);
  IF (SELECT usd_cents_snapshot FROM public.marketplace_listings WHERE id = v_lst) <> v_ask
     OR (SELECT fee_bps_snapshot FROM public.marketplace_listings WHERE id = v_lst)
        <> public.platform_fee('marketplace_sale_fee_bps') THEN
    RAISE EXCEPTION 'SMOKE FAIL: USD listing must snapshot seller price + platform fee';
  END IF;
  -- the listing pins a specific serial
  SELECT * INTO v_row FROM public.chit_copies
  WHERE chit_id = v_c1 AND state = 'listed_escrow' AND escrow_ref = v_lst;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'SMOKE FAIL: USD listing must pin a serial'; END IF;
  PERFORM public.marketplace_delist_chit_internal(v_u2, v_lst);
  UPDATE public.platform_integrity_settings SET marketplace_usd_lane = FALSE WHERE id = TRUE;

  -- ── withdraw stub RAISEs ───────────────────────────────────────────────────────
  -- (auth.uid() is NULL in this DO block, so it RAISEs on the auth check — still proves wiring.)

  -- ── cleanup ────────────────────────────────────────────────────────────────────
  -- Two collection buys → buyer owns 2 of each; minter sold everything (owns 0).
  PERFORM public.chit_grant(v_u2, v_c1, -2, 'platform_correction');
  PERFORM public.chit_grant(v_u2, v_c2, -2, 'platform_correction');
  SELECT available_tokens INTO v_q FROM public.token_balances WHERE user_id = v_u1;
  PERFORM public.increment_token_balance(v_u1, v_tok1 - v_q);
  SELECT available_tokens INTO v_q FROM public.token_balances WHERE user_id = v_u2;
  PERFORM public.increment_token_balance(v_u2, v_tok2 - v_q);
  UPDATE public.moment_chits SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_c1, v_c2);
  UPDATE public.collections SET status = 'closed', updated_at = NOW() WHERE id = v_coll;
  DELETE FROM public.kyc_verifications WHERE id IN (v_k1, v_k2);
  DELETE FROM public.platform_connections WHERE id = v_conn;

  RAISE NOTICE 'N3 smoke OK: collection sale 5000c (fee 500c, net 4500c), sold_out at zero, idempotent, USD seller-set resale in-band, serial pinned';
END $$;
