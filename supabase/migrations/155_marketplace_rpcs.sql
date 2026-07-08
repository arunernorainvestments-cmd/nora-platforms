-- Migration 155: marketplace RPCs — list / buy / delist (M1 — spec §3.3) + escrow
-- integration patches + apply-time smoke (§3.4).
--
-- Server-authoritative, atomic, idempotent. Pattern: service-only `_internal` fns take
-- an explicit user (callable from apply-time smoke + future server paths — mirrors
-- battle_start_match wrapper/_internal, mig 101); thin auth.uid() wrappers are what
-- clients call. No client ever writes a marketplace table directly (RLS, mig 154).
--
-- Money rules in force (Hard Rules 5/29/33/34/36 + spec DO NOTs):
--   • tokens only in M1 — any USD entry RAISEs ('usd marketplace lane not enabled until M2');
--   • integer math only; fee = gross * fee_bps / 10000, integer floor;
--   • the A/S fee is a BURN: debit gross from buyer, credit ONLY net to seller — the
--     difference is credited to no one and recorded as fee_burned;
--   • both user token movements logged in token_transactions (chit_purchase/chit_sale,
--     reference_id = listing id — Hard Rule 5), seller credit via increment_token_balance;
--   • ownership transfer = new acquisition-ledger rows (append-only, Hard Rule 29);
--     attribution (original_minter_handle/card_serial) lives on the chit definition and
--     survives untouched; the buyer's row carries acquired_currency='token' (M2 seam);
--   • a bought chit never consumes the buyer's self-mint slot (slot derives from
--     moments.owner_user_id — attribution ≠ authorship, same as wager-won cards);
--   • ascension freezes while a chit is escrowed in a listing (patches below), so a
--     listing's tier/price snapshot can never drift under a live buyer (Hard Rule 36).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. LIST
-- ═══════════════════════════════════════════════════════════════════════════════
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
  -- USD lane is inert in M1 (columns exist so M2 is a branch, not a data migration).
  IF p_currency IS DISTINCT FROM 'token' THEN
    RAISE EXCEPTION 'usd marketplace lane not enabled until M2';
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

  -- Concurrent-listing allowance (default 1 — the "one active listing" rule; a future
  -- subscription tier raises marketplace_listing_allowance via config, mig 154).
  SELECT COUNT(*) INTO v_active FROM public.marketplace_listings
  WHERE seller_user_id = p_user AND status = 'active';
  IF v_active >= public.marketplace_listing_allowance(p_user) THEN
    RAISE EXCEPTION 'Listing allowance reached (% active)', v_active;
  END IF;

  -- Snapshot the fixed price/fee for the chit's CURRENT tier (config, mig 153).
  SELECT * INTO v_price FROM public.marketplace_tier_pricing WHERE tier = v_chit.tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'No marketplace pricing for tier %', v_chit.tier; END IF;

  INSERT INTO public.marketplace_listings
    (chit_id, seller_user_id, currency, tier_snapshot,
     price_snapshot, fee_bps_snapshot, usd_cents_snapshot)
  VALUES
    (p_chit_id, p_user, 'token', v_chit.tier,
     v_price.token_price, v_price.fee_bps, v_price.usd_cents)
  RETURNING id INTO v_listing;

  -- Escrow: the copy leaves the seller's holdings (append-only ledger, mig 142 pattern).
  PERFORM public.chit_grant(p_user, p_chit_id, -1, 'marketplace_escrow', v_listing);

  RETURN v_listing;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketplace_list_chit(p_chit_id UUID)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_list_chit_internal(auth.uid(), p_chit_id, 'token');
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. BUY
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.marketplace_buy_chit_internal(p_buyer UUID, p_listing_id UUID)
RETURNS UUID   -- the marketplace_sales receipt id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_l    public.marketplace_listings%ROWTYPE;
  v_fee  INTEGER;
  v_net  INTEGER;
  v_sale UUID;
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
  IF v_l.currency IS DISTINCT FROM 'token' THEN
    RAISE EXCEPTION 'usd marketplace lane not enabled until M2';
  END IF;
  IF p_buyer = v_l.seller_user_id THEN
    RAISE EXCEPTION 'Cannot buy your own listing';
  END IF;

  -- Fee (A/S only via fee_bps_snapshot; F–B snapshot 0): integer floor. The fee is
  -- BURNED — debited from the buyer, credited to no one.
  v_fee := (v_l.price_snapshot * v_l.fee_bps_snapshot) / 10000;
  v_net := v_l.price_snapshot - v_fee;

  -- Debit buyer the gross price (guarded — mirrors _barter_move_tokens, mig 119).
  UPDATE public.token_balances
  SET available_tokens = available_tokens - v_l.price_snapshot,
      lifetime_spent   = lifetime_spent + v_l.price_snapshot,
      updated_at       = NOW()
  WHERE user_id = p_buyer AND available_tokens >= v_l.price_snapshot;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;

  -- Credit seller the NET (single sanctioned write path — Hard Rule 5 + governance).
  PERFORM public.increment_token_balance(v_l.seller_user_id, v_net);

  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES
    (p_buyer, 'chit_purchase', -v_l.price_snapshot, v_l.id,
     'Marketplace: bought ' || v_l.tier_snapshot || '-tier chit'),
    (v_l.seller_user_id, 'chit_sale', v_net, v_l.id,
     'Marketplace: sold ' || v_l.tier_snapshot || '-tier chit'
       || CASE WHEN v_fee > 0 THEN ' (' || v_fee || ' fee burned)' ELSE '' END);

  -- Ownership transfer: the escrowed copy lands with the buyer via a NEW acquisition-
  -- ledger row (append-only, Hard Rule 29). Attribution (original_minter_handle /
  -- card_serial) lives on the chit definition — untouched by transfer. The direct
  -- INSERT (vs chit_grant) carries the acquired_currency provenance stamp for M2.
  INSERT INTO public.chit_acquisition_ledger
    (user_id, chit_id, quantity_delta, reason, reference_id,
     counterparty_user_id, acquired_currency)
  VALUES
    (p_buyer, v_l.chit_id, 1, 'marketplace_purchase', v_l.id,
     v_l.seller_user_id, 'token');

  UPDATE public.marketplace_listings
  SET status = 'sold', closed_at = NOW()
  WHERE id = p_listing_id;

  INSERT INTO public.marketplace_sales
    (listing_id, chit_id, buyer_user_id, seller_user_id,
     currency, gross_price, fee_burned, net_to_seller)
  VALUES
    (v_l.id, v_l.chit_id, p_buyer, v_l.seller_user_id,
     'token', v_l.price_snapshot, v_fee, v_net)
  RETURNING id INTO v_sale;

  RETURN v_sale;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketplace_buy_chit(p_listing_id UUID)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_buy_chit_internal(auth.uid(), p_listing_id);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. DELIST
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.marketplace_delist_chit_internal(p_user UUID, p_listing_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_l public.marketplace_listings%ROWTYPE;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_l FROM public.marketplace_listings WHERE id = p_listing_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Listing not found: %', p_listing_id; END IF;
  IF v_l.seller_user_id <> p_user THEN RAISE EXCEPTION 'Only the seller can delist'; END IF;
  IF v_l.status <> 'active' THEN
    RAISE EXCEPTION 'Listing % is not active (%)', p_listing_id, v_l.status;
  END IF;

  -- Escrow returns to the seller; ascension unfreezes (no active listing remains).
  PERFORM public.chit_grant(p_user, v_l.chit_id, 1, 'marketplace_return', v_l.id);

  UPDATE public.marketplace_listings
  SET status = 'delisted', closed_at = NOW()
  WHERE id = p_listing_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketplace_delist_chit(p_listing_id UUID)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.marketplace_delist_chit_internal(auth.uid(), p_listing_id);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. ESCROW INTEGRATION PATCHES — a listed chit is HELD, not free
-- ═══════════════════════════════════════════════════════════════════════════════

-- 4a. self_mint_slot (mig 142): a listed self-minted chit still occupies the slot —
--     it is still "their" card until sold (delist returns it). A SOLD chit frees the
--     slot (the card lives on with the buyer, attribution intact — same as wager loss).
--     Without this, listing would free the slot and allow a second self-mint.
CREATE OR REPLACE FUNCTION public.self_mint_slot(p_user UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT mc.id
  FROM public.moment_chits mc
  JOIN public.moments m ON m.id = mc.moment_id
  WHERE m.owner_user_id = p_user
    AND mc.character_class = 'consent_minted'
    AND mc.retired_at IS NULL
    AND (
      EXISTS (SELECT 1 FROM public.chit_ownership co
              WHERE co.user_id = p_user AND co.chit_id = mc.id AND co.quantity > 0)
      OR EXISTS (SELECT 1 FROM public.ccg_wager_escrow we
                 WHERE we.user_id = p_user AND we.chit_id = mc.id AND we.status = 'escrowed')
      OR EXISTS (SELECT 1 FROM public.marketplace_listings ml
                 WHERE ml.seller_user_id = p_user AND ml.chit_id = mc.id AND ml.status = 'active')
    )
  ORDER BY mc.created_at DESC
  LIMIT 1;
$$;

-- 4b. chit_swap_retire (mig 142): never retire a chit that is escrowed in an active
--     listing (mirror of its wager guard) — the buyer's offer must stay honest.
CREATE OR REPLACE FUNCTION public.chit_swap_retire(p_user UUID, p_old_chit UUID, p_new_chit UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_deck RECORD;
BEGIN
  -- The old chit must be THIS user's live self-minted chit.
  IF NOT EXISTS (
    SELECT 1 FROM public.moment_chits mc
    JOIN public.moments m ON m.id = mc.moment_id
    WHERE mc.id = p_old_chit AND m.owner_user_id = p_user
      AND mc.character_class = 'consent_minted' AND mc.retired_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Chit % is not a live self-minted chit of user %', p_old_chit, p_user;
  END IF;
  -- Never retire a chit that is mid-wager.
  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE chit_id = p_old_chit AND user_id = p_user AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_old_chit;
  END IF;
  -- Never retire a chit that is listed for sale (marketplace escrow, mig 154/155).
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE chit_id = p_old_chit AND seller_user_id = p_user AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active marketplace listing', p_old_chit;
  END IF;

  -- Dispose remaining holdings (append-only ledger, negative delta).
  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_old_chit;
  IF COALESCE(v_qty, 0) > 0 THEN
    PERFORM public.chit_grant(p_user, p_old_chit, -v_qty, 'swap_retired', p_new_chit);
  END IF;

  -- Retire the definition (soft: ledger/match-history FKs stay valid).
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'swap'
  WHERE id = p_old_chit;

  -- Pull it from every deck that contains it; those decks are no longer legal.
  FOR v_deck IN
    DELETE FROM public.deck_chits WHERE chit_id = p_old_chit RETURNING deck_id
  LOOP
    UPDATE public.decks SET is_legal = FALSE, validated_at = NOW(), updated_at = NOW()
    WHERE id = v_deck.deck_id;
  END LOOP;
END;
$$;

-- 4c. moment_chit_rederive (mig 136): ascension FREEZES while ANY copy of the chit is
--     escrowed in an active listing — ascension is definition-level, so a re-derive
--     would move the listed card's tier/stats (and its fixed price band) under a live
--     buyer, violating the snapshot promise (Hard Rule 36 spirit). Guard first.
CREATE OR REPLACE FUNCTION public.moment_chit_rederive(p_chit_id UUID, p_new_tier TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_c public.moment_chits%ROWTYPE; v_stats JSONB;
BEGIN
  -- Ascension is frozen while escrowed in a marketplace listing (M1, mig 155).
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE chit_id = p_chit_id AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active marketplace listing (ascension frozen)', p_chit_id;
  END IF;

  SELECT * INTO v_c FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;

  v_stats := public.derive_chit_stats(p_new_tier, v_c.chit_type, v_c.effect_ref);

  UPDATE public.moment_chits SET
    tier             = p_new_tier,
    aura_cost        = (v_stats->>'aura_cost')::INTEGER,
    atk              = (v_stats->>'atk')::INTEGER,
    hp               = (v_stats->>'hp')::INTEGER,
    effect_magnitude = (v_stats->>'effect_magnitude')::INTEGER,
    updated_at       = NOW()
  WHERE id = p_chit_id;
  -- archetype_family, effect_ref, timing_type, keywords intentionally unchanged.
END;
$$;

-- 4d. chit_ascension_refresh (mig 136): skip listed chits so one frozen card never
--     aborts the whole weekly refresh (the rederive guard above stays as the backstop
--     for admin/review-queue paths).
CREATE OR REPLACE FUNCTION public.chit_ascension_refresh(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
  r RECORD;
  v_new_tier TEXT; v_new_rank INTEGER; v_cur_rank INTEGER; v_jump INTEGER;
  v_ascended INTEGER := 0; v_queued INTEGER := 0;
BEGIN
  SELECT MAX(refreshed_at) INTO v_last FROM public.chit_ascension_log WHERE user_id = p_user_id;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '7 days' THEN
    RAISE EXCEPTION 'Ascension refresh is available once per 7 days';
  END IF;

  FOR r IN
    SELECT m.engagement_count AS eng, mc.id AS chit_id, mc.tier AS cur_tier
    FROM public.moments m
    JOIN public.moment_chits mc ON mc.id = m.minted_chit_id
    WHERE m.owner_user_id = p_user_id
      AND m.source_status = 'active'        -- deleted/expired keep last-verified tier
      AND m.minted_chit_id IS NOT NULL
      -- ascension frozen while escrowed in a marketplace listing (M1, mig 155)
      AND NOT EXISTS (SELECT 1 FROM public.marketplace_listings ml
                      WHERE ml.chit_id = mc.id AND ml.status = 'active')
  LOOP
    v_new_tier := public.tier_for_engagement(r.eng);
    SELECT tier_rank INTO v_new_rank FROM public.tier_ladder WHERE tier = v_new_tier;
    SELECT tier_rank INTO v_cur_rank FROM public.tier_ladder WHERE tier = r.cur_tier;

    IF v_new_rank > v_cur_rank THEN            -- one-directional: only ascend
      v_jump := v_new_rank - v_cur_rank;
      IF v_jump >= 3 THEN
        INSERT INTO public.ascension_review_queue (chit_id, user_id, from_tier, to_tier, engagement)
        VALUES (r.chit_id, p_user_id, r.cur_tier, v_new_tier, r.eng);
        v_queued := v_queued + 1;
      ELSE
        PERFORM public.moment_chit_rederive(r.chit_id, v_new_tier);
        v_ascended := v_ascended + 1;
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.chit_ascension_log (user_id) VALUES (p_user_id);
  RETURN jsonb_build_object('ascended', v_ascended, 'queued_for_review', v_queued);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. GRANTS — internals are service-only; wrappers are for signed-in clients
-- ═══════════════════════════════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION public.marketplace_list_chit_internal(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketplace_buy_chit_internal(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketplace_delist_chit_internal(UUID, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.marketplace_list_chit(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marketplace_buy_chit(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.marketplace_delist_chit(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_list_chit(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_buy_chit(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketplace_delist_chit(UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. APPLY-TIME SMOKE (spec §3.4): list → buy → assertions; list → delist → assertions.
--    Runs on dedicated smoke identities (mig 142 discipline: the acquisition ledger is
--    append-only, so residue must live on smoke users — created here if absent, 026
--    pattern, flagged is_test_account so Hard Rule 15 filters apply). Balances and
--    holdings are compensated back to start; sold/delisted listings + the sale receipt
--    remain on smoke identities and are swept by the P7 pre-launch reset (ARCHIVE §A8).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;                 -- seller, buyer
  v_cS UUID; v_cC UUID;                 -- S-tier + C-tier smoke chits
  v_bal1 INTEGER; v_bal2 INTEGER;       -- starting balances
  v_cur  INTEGER;
  v_lS UUID; v_lC UUID;
  v_sale UUID; v_sale2 UUID;
  v_q INTEGER; v_err BOOLEAN;
  v_serial TEXT; v_txt TEXT;
  v_row RECORD;
BEGIN
  -- ── smoke users (create if absent; trigger creates profiles + token_balances) ──
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  IF v_u1 IS NULL THEN
    v_u1 := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'mkt-smoke-1@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"MKT Smoke Seller"}');
  END IF;
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_u2 IS NULL THEN
    v_u2 := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_u2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'mkt-smoke-2@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"MKT Smoke Buyer"}');
  END IF;
  UPDATE public.profiles SET is_test_account = TRUE WHERE id IN (v_u1, v_u2);

  SELECT available_tokens INTO v_bal1 FROM public.token_balances WHERE user_id = v_u1;
  SELECT available_tokens INTO v_bal2 FROM public.token_balances WHERE user_id = v_u2;

  -- ── smoke chits: S (fee tier) + C (no-fee tier), finalized, attributed ─────────
  v_cS := public.create_moment_chit('MKT M1 smoke S', 'athlete', 'creature', 'S');
  v_cC := public.create_moment_chit('MKT M1 smoke C', 'musician', 'creature', 'C');
  UPDATE public.moment_chits
  SET finalized_at = NOW(), original_minter_handle = '@mkt_smoke_minter'
  WHERE id IN (v_cS, v_cC);
  SELECT card_serial INTO v_serial FROM public.moment_chits WHERE id = v_cS;
  PERFORM public.chit_grant(v_u1, v_cS, 1, 'event');
  PERFORM public.chit_grant(v_u1, v_cC, 1, 'event');

  -- ── LIST the S chit: escrow drains, snapshots frozen ───────────────────────────
  v_lS := public.marketplace_list_chit_internal(v_u1, v_cS, 'token');
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_cS;
  IF COALESCE(v_q, -1) <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: list must escrow the copy out of holdings'; END IF;
  SELECT * INTO v_row FROM public.marketplace_listings WHERE id = v_lS;
  IF v_row.status <> 'active' OR v_row.price_snapshot <> 10000
     OR v_row.fee_bps_snapshot <> 1500 OR v_row.usd_cents_snapshot <> 10000 THEN
    RAISE EXCEPTION 'SMOKE FAIL: S listing snapshots wrong (price %, fee_bps %)', v_row.price_snapshot, v_row.fee_bps_snapshot;
  END IF;

  -- ── allowance: a second concurrent listing must be blocked (default 1) ─────────
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cC, 'token');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: listing allowance must block a second active listing'; END IF;

  -- ── ascension freeze: re-derive of a LISTED chit must be blocked ───────────────
  v_err := FALSE;
  BEGIN
    PERFORM public.moment_chit_rederive(v_cS, 'A');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: ascension must be frozen while escrowed'; END IF;

  -- ── BUY: ownership moves, seller nets price − fee, fee burns, receipts append ──
  PERFORM public.increment_token_balance(v_u2, 20000);
  v_sale := public.marketplace_buy_chit_internal(v_u2, v_lS);

  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u2 AND chit_id = v_cS;
  IF COALESCE(v_q, 0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must receive the copy'; END IF;
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u1;
  IF v_cur <> v_bal1 + 8500 THEN RAISE EXCEPTION 'SMOKE FAIL: seller must net 8500 (got delta %)', v_cur - v_bal1; END IF;
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u2;
  IF v_cur <> v_bal2 + 20000 - 10000 THEN RAISE EXCEPTION 'SMOKE FAIL: buyer must pay gross 10000'; END IF;
  SELECT * INTO v_row FROM public.marketplace_sales WHERE id = v_sale;
  IF v_row.gross_price <> 10000 OR v_row.fee_burned <> 1500 OR v_row.net_to_seller <> 8500
     OR v_row.currency <> 'token' THEN
    RAISE EXCEPTION 'SMOKE FAIL: sale receipt wrong (gross % fee % net %)', v_row.gross_price, v_row.fee_burned, v_row.net_to_seller;
  END IF;
  SELECT status INTO v_txt FROM public.marketplace_listings WHERE id = v_lS;
  IF v_txt <> 'sold' THEN RAISE EXCEPTION 'SMOKE FAIL: listing must be sold'; END IF;
  -- attribution + serial survive transfer (they live on the definition)
  SELECT original_minter_handle INTO v_txt FROM public.moment_chits WHERE id = v_cS;
  IF v_txt <> '@mkt_smoke_minter' THEN RAISE EXCEPTION 'SMOKE FAIL: attribution must survive transfer'; END IF;
  IF (SELECT card_serial FROM public.moment_chits WHERE id = v_cS) IS DISTINCT FROM v_serial THEN
    RAISE EXCEPTION 'SMOKE FAIL: card_serial must survive transfer';
  END IF;
  -- provenance stamp for M2
  IF NOT EXISTS (SELECT 1 FROM public.chit_acquisition_ledger
                 WHERE user_id = v_u2 AND chit_id = v_cS
                   AND reason = 'marketplace_purchase' AND acquired_currency = 'token') THEN
    RAISE EXCEPTION 'SMOKE FAIL: buy must stamp acquired_currency=token';
  END IF;
  -- a bought card never eats the buyer's self-mint slot
  IF public.self_mint_slot(v_u2) IS NOT NULL THEN
    RAISE EXCEPTION 'SMOKE FAIL: bought chit must not occupy the buyer self-mint slot';
  END IF;

  -- ── replayed buy is a NO-OP (same receipt back, no second debit) ───────────────
  v_sale2 := public.marketplace_buy_chit_internal(v_u2, v_lS);
  IF v_sale2 IS DISTINCT FROM v_sale THEN RAISE EXCEPTION 'SMOKE FAIL: replayed buy must return the same receipt'; END IF;
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u2;
  IF v_cur <> v_bal2 + 10000 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed buy must not double-spend'; END IF;

  -- ── USD lane is inert in M1 ────────────────────────────────────────────────────
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_list_chit_internal(v_u1, v_cC, 'usd');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: usd lane must RAISE until M2'; END IF;

  -- ── LIST → DELIST: escrow returns, listing closes ──────────────────────────────
  v_lC := public.marketplace_list_chit_internal(v_u1, v_cC, 'token');
  -- a non-seller cannot delist
  v_err := FALSE;
  BEGIN
    PERFORM public.marketplace_delist_chit_internal(v_u2, v_lC);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: only the seller may delist'; END IF;
  PERFORM public.marketplace_delist_chit_internal(v_u1, v_lC);
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_cC;
  IF COALESCE(v_q, 0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: delist must return the escrowed copy'; END IF;
  SELECT status INTO v_txt FROM public.marketplace_listings WHERE id = v_lC;
  IF v_txt <> 'delisted' THEN RAISE EXCEPTION 'SMOKE FAIL: listing must be delisted'; END IF;

  -- ── cleanup: compensate holdings + balances back to start; retire smoke chits ──
  PERFORM public.chit_grant(v_u2, v_cS, -1, 'platform_correction');
  PERFORM public.chit_grant(v_u1, v_cC, -1, 'platform_correction');
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u1;
  PERFORM public.increment_token_balance(v_u1, v_bal1 - v_cur);
  SELECT available_tokens INTO v_cur FROM public.token_balances WHERE user_id = v_u2;
  PERFORM public.increment_token_balance(v_u2, v_bal2 - v_cur);
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_cS, v_cC);

  RAISE NOTICE 'MKT M1 smoke OK: sold S fee_burned=1500, delist returned escrow';
END $$;
