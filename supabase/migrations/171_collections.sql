-- Migration 171: Collections — multi-copy themed series minted by collection
-- minters (Collections spec Phase N2.2), on the mig-170 copy foundation.
--
-- Model (spec §1.2, decisions LOCKED):
--   • a Collection = 1–N distinct member cards, each minted through the FULL
--     existing pipeline (OAuth-owned post, moderation, ladder-derived stats —
--     HR37–39 per card, zero shortcuts). The pipeline learns ONE new thing:
--     a moment may carry collection_id, which exempts the mint from the personal
--     self-mint slot (the collection + mint fee is its own lane) — nothing else.
--   • per-card supply 1–1000, FIXED at publish (mig-170 immutability backstop);
--     copies are serialized "#k of N"; attribution is definition-level and
--     already survives every transfer (migs 142/155).
--   • minter sets the collection PRICE (integer cents) — never stats/tier
--     (Hard Rule 34: price is not a stat).
--   • no minter royalty on resale (LOCKED; P5 match royalty is separate).
--   • G-COLL (counsel-gated): all of this runs in SIM. The language ban is
--     absolute — nothing here or in any surface may frame cards as investments.
--
-- REPO-CHECK resolutions:
--   1.1 [FOUNDER]: fee numbers are CONFIG (platform_fee_config), seeded with the
--       spec's suggested placeholders (10% sale fee; collection mint fee $5 base
--       + $0.50/copy). Surfaced for founder sign-off before any live flip.
--   1.3: is_kyc_verified (kyc_verifications.status='approved') is marketplace-
--       entry KYC; payout onboarding does NOT exist yet and stays a distinct
--       future flag — withdrawal is stubbed behind the live flip (N3).
--   N2.3: profiles.is_market_maker is load-bearing for ranking/discovery filters
--       (Hard Rules 13/15) — NOT overloaded. Collection-minter eligibility is the
--       DERIVED predicate is_collection_minter(user): KYC-approved + ≥1 active
--       linked social (platform_connections). No stale flag to maintain.

-- ── platform_fee_config (REPO-CHECK 1.1 — placeholder values, founder-gated) ─────
CREATE TABLE public.platform_fee_config (
  config_key  TEXT PRIMARY KEY,
  value_int   INTEGER NOT NULL CHECK (value_int >= 0),
  description TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.platform_fee_config IS
  'The two platform revenue streams (Collections spec §1.1): sale fee + collection '
  'mint fee. PLACEHOLDER values pending founder sign-off (REPO-CHECK 1.1) — tune '
  'via UPDATE, never rebuild.';

INSERT INTO public.platform_fee_config (config_key, value_int, description) VALUES
  ('marketplace_sale_fee_bps',          1000, 'Platform fee on card sales, basis points (10%). Founder to confirm.'),
  ('collection_mint_fee_base_cents',     500, 'Collection mint fee: flat base, integer cents ($5). Founder to confirm.'),
  ('collection_mint_fee_per_copy_cents',  50, 'Collection mint fee: per authorized copy, integer cents ($0.50). Founder to confirm.');

ALTER TABLE public.platform_fee_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "platform_fee_config_select_all" ON public.platform_fee_config
  FOR SELECT USING (TRUE);
-- No client write policies: config changes are migrations / service role.

CREATE OR REPLACE FUNCTION public.platform_fee(p_key TEXT)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT value_int FROM public.platform_fee_config WHERE config_key = p_key;
$$;

-- ── collection-minter eligibility (REPO-CHECK N2.3: derived, not a flag) ─────────
CREATE OR REPLACE FUNCTION public.is_collection_minter(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.is_kyc_verified(p_user_id)
     AND EXISTS (SELECT 1 FROM public.platform_connections
                 WHERE user_id = p_user_id AND is_active);
$$;

-- Client peek for the UI gate (own status only).
CREATE OR REPLACE FUNCTION public.my_collection_minter_status()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'kyc_verified',  public.is_kyc_verified(auth.uid()),
    'linked_social', EXISTS (SELECT 1 FROM public.platform_connections
                             WHERE user_id = auth.uid() AND is_active),
    'eligible',      public.is_collection_minter(auth.uid()));
$$;

-- ── collections + membership ──────────────────────────────────────────────────────
CREATE TABLE public.collections (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  market_maker_user_id UUID NOT NULL REFERENCES auth.users(id),
  title                TEXT NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 80),
  description          TEXT,
  cover_art_url        TEXT,
  status               TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','minting','listed','sold_out','closed')),
  price_cents          INTEGER CHECK (price_cents > 0),   -- minter-set; integer cents (HR33)
  mint_fee_paid_cents  INTEGER,                           -- stamped once at publish (idempotency)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX collections_minter_idx ON public.collections (market_maker_user_id, status);
CREATE INDEX collections_browse_idx ON public.collections (created_at DESC) WHERE status IN ('listed','sold_out');

CREATE TABLE public.collection_chits (
  collection_id UUID NOT NULL REFERENCES public.collections(id),
  chit_id       UUID NOT NULL REFERENCES public.moment_chits(id) UNIQUE,
  display_order INTEGER NOT NULL DEFAULT 1,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (collection_id, chit_id)
);

ALTER TABLE public.collections     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collection_chits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collections_select_public_or_own" ON public.collections
  FOR SELECT USING (status IN ('listed','sold_out') OR auth.uid() = market_maker_user_id);

CREATE POLICY "collection_chits_select_visible" ON public.collection_chits
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.collections c
    WHERE c.id = collection_id
      AND (c.status IN ('listed','sold_out') OR c.market_maker_user_id = auth.uid())));
-- All writes via SECURITY DEFINER RPCs below.

-- ── the pipeline seam: a moment may target a collection ──────────────────────────
-- Stamped by cinematic-mint at the first accepted call (validated there + re-
-- validated in moment_mint below); resume-safe because it lives on the moment.
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS collection_id UUID REFERENCES public.collections(id);

-- ── ledger vocabulary: collection copy generation ─────────────────────────────────
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired',
    'marketplace_escrow','marketplace_return','marketplace_purchase',
    'collection_mint'
  ));

-- ── moment_mint: the collection branch (slot exemption + membership) ──────────────
-- Same signature as mig 142 — the collection rides on moments.collection_id.
CREATE OR REPLACE FUNCTION public.moment_mint(
  p_moment_id         UUID,
  p_family            TEXT,
  p_chit_type         TEXT,
  p_timing            TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_name              TEXT DEFAULT NULL,
  p_keywords          TEXT[] DEFAULT '{}',
  p_vibe_gate         INTEGER DEFAULT NULL,
  p_moment_video_ref  TEXT DEFAULT NULL,
  p_swap_of           UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_m public.moments%ROWTYPE; v_tier TEXT; v_chit UUID; v_slot UUID;
  v_coll public.collections%ROWTYPE;
BEGIN
  SELECT * INTO v_m FROM public.moments WHERE id = p_moment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Moment not found: %', p_moment_id; END IF;
  IF v_m.consent_granted_at IS NULL THEN RAISE EXCEPTION 'No consent on moment'; END IF;
  IF v_m.moderation_status <> 'approved' THEN RAISE EXCEPTION 'Moment not moderation-approved'; END IF;
  IF v_m.minted_chit_id IS NOT NULL THEN RAISE EXCEPTION 'Moment already minted'; END IF;
  IF v_m.source_status <> 'active' THEN RAISE EXCEPTION 'Moment source is not active'; END IF;

  IF v_m.collection_id IS NOT NULL THEN
    -- Collection lane: KYC'd + social-linked minter, their own open collection.
    -- The personal self-mint slot is NOT consumed and swap never mixes in.
    IF p_swap_of IS NOT NULL THEN
      RAISE EXCEPTION 'A collection mint never swap-retires the personal card';
    END IF;
    SELECT * INTO v_coll FROM public.collections WHERE id = v_m.collection_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found: %', v_m.collection_id; END IF;
    IF v_coll.market_maker_user_id <> v_m.owner_user_id THEN
      RAISE EXCEPTION 'Collection % does not belong to the moment owner', v_m.collection_id;
    END IF;
    IF v_coll.status NOT IN ('draft','minting') THEN
      RAISE EXCEPTION 'Collection % is % — cards can only be added before publish',
        v_m.collection_id, v_coll.status;
    END IF;
    IF NOT public.is_collection_minter(v_m.owner_user_id) THEN
      RAISE EXCEPTION 'Collection minting requires KYC verification and a linked social profile';
    END IF;
  ELSE
    -- Personal lane: one active self-minted chit per user (minting spec P4).
    v_slot := public.self_mint_slot(v_m.owner_user_id);
    IF p_swap_of IS NULL THEN
      IF v_slot IS NOT NULL THEN
        RAISE EXCEPTION 'self_mint_slot_occupied: user already holds self-minted chit % (swap required)', v_slot;
      END IF;
    ELSIF v_slot IS NULL OR v_slot <> p_swap_of THEN
      RAISE EXCEPTION 'swap_mismatch: % is not the occupying self-minted chit (%)', p_swap_of, v_slot;
    END IF;
  END IF;

  -- Tier assigned from CURRENT engagement (not user-set — Hard Rule 34).
  v_tier := public.tier_for_engagement(v_m.engagement_count);

  v_chit := public.create_moment_chit(
    COALESCE(p_name, 'Moment ' || LEFT(p_moment_id::TEXT, 8)),
    p_family, p_chit_type, v_tier, p_timing, p_effect_template_id,
    'consent_minted', p_moment_id, COALESCE(p_keywords,'{}'), p_vibe_gate,
    v_m.thumbnail_url, p_moment_video_ref, NULL);

  IF v_m.collection_id IS NOT NULL THEN
    INSERT INTO public.collection_chits (collection_id, chit_id, display_order)
    VALUES (v_m.collection_id, v_chit,
            COALESCE((SELECT MAX(display_order) FROM public.collection_chits
                      WHERE collection_id = v_m.collection_id), 0) + 1);
    UPDATE public.collections
    SET status = 'minting', updated_at = NOW()
    WHERE id = v_m.collection_id AND status = 'draft';
  END IF;

  UPDATE public.moments
  SET archetype_family = p_family, minted_chit_id = v_chit, mint_status = 'minted'
  WHERE id = p_moment_id;

  RETURN v_chit;
END;
$$;

-- ── self_mint_slot: collection cards never occupy the personal slot ───────────────
-- (Body otherwise identical to mig 155's version.)
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
    AND NOT EXISTS (SELECT 1 FROM public.collection_chits cc WHERE cc.chit_id = mc.id)
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

-- ── swap/delete walls: the personal-card flows never touch collection cards ───────
CREATE OR REPLACE FUNCTION public.chit_swap_retire(p_user UUID, p_old_chit UUID, p_new_chit UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_deck RECORD;
BEGIN
  -- Collection cards live under the collection, never under the personal slot.
  IF EXISTS (SELECT 1 FROM public.collection_chits WHERE chit_id = p_old_chit) THEN
    RAISE EXCEPTION 'Chit % is a collection card — the personal swap flow never touches it', p_old_chit;
  END IF;
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

-- chit_delete_owned (mig 162): same wall, prepended guard; body otherwise unchanged.
CREATE OR REPLACE FUNCTION public.chit_delete_owned(p_user UUID, p_chit UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_moment UUID; v_deck RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM public.collection_chits WHERE chit_id = p_chit) THEN
    RAISE EXCEPTION 'Chit % is a collection card — the personal delete flow never touches it', p_chit;
  END IF;

  SELECT mc.moment_id INTO v_moment
  FROM public.moment_chits mc
  JOIN public.moments m ON m.id = mc.moment_id
  JOIN public.chit_ownership co ON co.chit_id = mc.id
  WHERE mc.id = p_chit
    AND m.owner_user_id = p_user
    AND co.user_id = p_user AND co.quantity > 0
    AND mc.character_class = 'consent_minted'
    AND mc.retired_at IS NULL
  LIMIT 1;
  IF v_moment IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a deletable self-minted chit for this user', p_chit;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.chit_ownership
    WHERE chit_id = p_chit AND user_id <> p_user AND quantity > 0
  ) THEN
    RAISE EXCEPTION 'Chit % has copies held by other users and cannot be deleted', p_chit;
  END IF;

  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE chit_id = p_chit AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_chit;
  END IF;

  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE chit_id = p_chit AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active marketplace listing', p_chit;
  END IF;

  SELECT quantity INTO v_qty FROM public.chit_ownership WHERE user_id = p_user AND chit_id = p_chit;
  IF COALESCE(v_qty, 0) > 0 THEN
    PERFORM public.chit_grant(p_user, p_chit, -v_qty, 'swap_retired', v_moment);
  END IF;

  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'discarded'
  WHERE id = p_chit;

  FOR v_deck IN
    DELETE FROM public.deck_chits WHERE chit_id = p_chit RETURNING deck_id
  LOOP
    UPDATE public.decks SET is_legal = FALSE, validated_at = NOW(), updated_at = NOW()
    WHERE id = v_deck.deck_id;
  END LOOP;

  PERFORM public.moment_release_on_retire(p_chit);

  RETURN v_moment;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- COLLECTION RPCs — create / update / publish. Internals take an explicit user
-- (service + smoke callable); thin auth.uid() wrappers for clients (mig 155
-- pattern). All money integer cents on the sim USD rail (mig 132).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.collection_create_internal(
  p_user UUID, p_title TEXT, p_description TEXT DEFAULT NULL, p_cover_art_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_collection_minter(p_user) THEN
    RAISE EXCEPTION 'Collections require KYC verification and a linked social profile';
  END IF;
  INSERT INTO public.collections (market_maker_user_id, title, description, cover_art_url)
  VALUES (p_user, btrim(p_title), p_description, p_cover_art_url)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.collection_update_internal(
  p_user UUID, p_collection UUID,
  p_title TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL, p_cover_art_url TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_c public.collections%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM public.collections WHERE id = p_collection FOR UPDATE;
  IF NOT FOUND OR v_c.market_maker_user_id <> p_user THEN
    RAISE EXCEPTION 'Collection not found or not yours';
  END IF;
  IF v_c.status NOT IN ('draft','minting') THEN
    RAISE EXCEPTION 'Collection % is % — details are frozen after publish', p_collection, v_c.status;
  END IF;
  UPDATE public.collections
  SET title         = COALESCE(btrim(p_title), title),
      description   = COALESCE(p_description, description),
      cover_art_url = COALESCE(p_cover_art_url, cover_art_url),
      updated_at    = NOW()
  WHERE id = p_collection;
END;
$$;

-- PUBLISH: fix supplies (the one sanctioned total_supply write), charge the mint
-- fee (config; sim USD rail; idempotent via the mint_fee_paid_cents stamp +
-- status transition), generate the serialized copies, list the collection.
CREATE OR REPLACE FUNCTION public.collection_publish_internal(
  p_user UUID, p_collection UUID, p_price_cents INTEGER, p_supplies JSONB
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_c        public.collections%ROWTYPE;
  v_members  INTEGER;
  v_total    INTEGER := 0;
  v_fee      INTEGER;
  r          RECORD;
  v_supply   INTEGER;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_c FROM public.collections WHERE id = p_collection FOR UPDATE;
  IF NOT FOUND OR v_c.market_maker_user_id <> p_user THEN
    RAISE EXCEPTION 'Collection not found or not yours';
  END IF;

  -- Idempotent replay: an already-listed collection returns its receipt untouched.
  IF v_c.status = 'listed' AND v_c.mint_fee_paid_cents IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'listed', 'fee_cents', v_c.mint_fee_paid_cents,
                              'already_published', TRUE);
  END IF;
  IF v_c.status NOT IN ('draft','minting') THEN
    RAISE EXCEPTION 'Collection % is % and cannot be published', p_collection, v_c.status;
  END IF;
  IF NOT public.is_collection_minter(p_user) THEN
    RAISE EXCEPTION 'Collections require KYC verification and a linked social profile';
  END IF;
  IF COALESCE(p_price_cents, 0) <= 0 THEN
    RAISE EXCEPTION 'Collection price must be a positive integer amount of cents';
  END IF;

  SELECT COUNT(*) INTO v_members FROM public.collection_chits WHERE collection_id = p_collection;
  IF v_members = 0 THEN RAISE EXCEPTION 'Collection has no member cards yet'; END IF;

  -- Every member must be a live, finalized card whose ONLY copy is the minter's
  -- serial 1 (nothing sold/escrowed pre-publish), and every member needs a supply.
  IF EXISTS (
    SELECT 1 FROM public.collection_chits cc
    JOIN public.moment_chits mc ON mc.id = cc.chit_id
    WHERE cc.collection_id = p_collection
      AND (mc.retired_at IS NOT NULL OR NOT mc.is_active OR mc.finalized_at IS NULL)
  ) THEN
    RAISE EXCEPTION 'Every member card must be finalized and active before publish';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.collection_chits cc
    JOIN public.chit_copies c ON c.chit_id = cc.chit_id
    WHERE cc.collection_id = p_collection
      AND (c.owner_user_id <> p_user OR c.state <> 'owned')
  ) THEN
    RAISE EXCEPTION 'Every member card''s copies must be held by the minter at publish';
  END IF;

  -- Supplies: one entry per member, 1..1000 (fixed forever after this).
  FOR r IN
    SELECT cc.chit_id,
           (SELECT (e->>'total_supply')::INTEGER
            FROM jsonb_array_elements(p_supplies) e
            WHERE (e->>'chit_id')::UUID = cc.chit_id) AS supply
    FROM public.collection_chits cc
    WHERE cc.collection_id = p_collection
  LOOP
    IF r.supply IS NULL OR r.supply < 1 OR r.supply > 1000 THEN
      RAISE EXCEPTION 'Chit % needs a total_supply between 1 and 1000', r.chit_id;
    END IF;
    v_total := v_total + r.supply;
  END LOOP;

  -- The collection mint fee (config, REPO-CHECK 1.1): base + per-copy, integer
  -- cents, charged on the sim/live-switched USD rail. Stamped once.
  v_fee := public.platform_fee('collection_mint_fee_base_cents')
         + public.platform_fee('collection_mint_fee_per_copy_cents') * v_total;
  IF v_c.mint_fee_paid_cents IS NULL THEN
    PERFORM public.ccg_usd_debit(p_user, v_fee, p_collection,
      'Collection mint fee: "' || v_c.title || '" (' || v_total || ' copies)');
  END IF;

  -- Fix supplies + generate the remaining serials. The mint completion granted
  -- serial 1 to the minter; count what is actually issued so the flow is robust
  -- either way, and never allow a supply below already-issued serials.
  FOR r IN
    SELECT cc.chit_id,
           (SELECT (e->>'total_supply')::INTEGER
            FROM jsonb_array_elements(p_supplies) e
            WHERE (e->>'chit_id')::UUID = cc.chit_id) AS supply,
           (SELECT COUNT(*)::INTEGER FROM public.chit_copies c
            WHERE c.chit_id = cc.chit_id) AS issued
    FROM public.collection_chits cc
    WHERE cc.collection_id = p_collection
  LOOP
    IF r.issued > r.supply THEN
      RAISE EXCEPTION 'Chit % already has % issued copies — supply % is too low',
        r.chit_id, r.issued, r.supply;
    END IF;
    PERFORM set_config('nora.allow_supply_set', 'on', TRUE);
    UPDATE public.moment_chits SET total_supply = r.supply WHERE id = r.chit_id;
    PERFORM set_config('nora.allow_supply_set', 'off', TRUE);
    UPDATE public.chit_copies SET total_supply = r.supply, updated_at = NOW()
    WHERE chit_id = r.chit_id;
    IF r.supply > r.issued THEN
      PERFORM public.chit_grant(p_user, r.chit_id, r.supply - r.issued, 'collection_mint', p_collection);
    END IF;
  END LOOP;

  UPDATE public.collections
  SET status = 'listed', price_cents = p_price_cents,
      mint_fee_paid_cents = COALESCE(mint_fee_paid_cents, v_fee), updated_at = NOW()
  WHERE id = p_collection;

  RETURN jsonb_build_object('status', 'listed', 'fee_cents', v_fee,
                            'total_copies', v_total, 'already_published', FALSE);
END;
$$;

-- ── client wrappers ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.collection_create(
  p_title TEXT, p_description TEXT DEFAULT NULL, p_cover_art_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.collection_create_internal(auth.uid(), p_title, p_description, p_cover_art_url);
$$;

CREATE OR REPLACE FUNCTION public.collection_update(
  p_collection UUID, p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL, p_cover_art_url TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.collection_update_internal(auth.uid(), p_collection, p_title, p_description, p_cover_art_url);
$$;

CREATE OR REPLACE FUNCTION public.collection_publish(
  p_collection UUID, p_price_cents INTEGER, p_supplies JSONB
)
RETURNS JSONB
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.collection_publish_internal(auth.uid(), p_collection, p_price_cents, p_supplies);
$$;

-- ── grants ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.collection_create_internal(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.collection_update_internal(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.collection_publish_internal(UUID, UUID, INTEGER, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_collection_minter(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.platform_fee(TEXT) FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.collection_create(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.collection_update(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.collection_publish(UUID, INTEGER, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_collection_minter_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.collection_create(TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.collection_update(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.collection_publish(UUID, INTEGER, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection_minter_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_collection_minter(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_fee(TEXT) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — collection lifecycle end-to-end in sim on the mkt-smoke-1
-- identity (KYC + social rows added, removed at cleanup). Skips when the payments
-- rail is live (sim rail unavailable), mirroring mig 156.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u UUID; v_kyc UUID; v_conn UUID;
  v_coll UUID; v_m1 UUID; v_m2 UUID; v_c1 UUID; v_c2 UUID;
  v_usd BIGINT; v_cur BIGINT;
  v_res JSONB; v_q INTEGER; v_c INTEGER; v_err BOOLEAN;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  IF v_u IS NULL THEN RAISE EXCEPTION 'mig 171 smoke requires the mig-155 smoke user'; END IF;
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'N2.2 smoke SKIPPED (battle_payments_mode is live)';
    RETURN;
  END IF;

  -- Eligibility scaffolding (removed at cleanup).
  v_err := FALSE;
  BEGIN
    PERFORM public.collection_create_internal(v_u, 'pre-KYC must fail');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: collection create must require eligibility'; END IF;

  INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_u, 'approved')
  RETURNING id INTO v_kyc;
  INSERT INTO public.platform_connections
    (user_id, platform, platform_user_id, platform_username, access_token, is_active)
  VALUES (v_u, 'youtube', 'n2-smoke-channel', '@n2_smoke_minter', 'smoke-token', TRUE)
  RETURNING id INTO v_conn;

  v_coll := public.collection_create_internal(v_u, 'N2 Smoke Series', 'apply-time smoke', NULL);

  -- Two member cards through the real mint path (moment → moderation → mint),
  -- collection-stamped: the personal slot must stay FREE throughout.
  v_m1 := public.moment_record(v_u, 'youtube', 'n2-smoke-' || gen_random_uuid()::TEXT,
                               'https://example.com/post1', NULL, 900000, TRUE, '@n2_smoke_minter');
  v_m2 := public.moment_record(v_u, 'youtube', 'n2-smoke-' || gen_random_uuid()::TEXT,
                               'https://example.com/post2', NULL, 1200, TRUE, '@n2_smoke_minter');
  PERFORM public.moment_pre_gen_moderate(v_m1, 'approved', NULL, FALSE, 'sim');
  PERFORM public.moment_pre_gen_moderate(v_m2, 'approved', NULL, FALSE, 'sim');
  UPDATE public.moments SET collection_id = v_coll WHERE id IN (v_m1, v_m2);

  v_c1 := public.moment_mint(v_m1, 'athlete', 'creature', 'on_summon');
  v_c2 := public.moment_mint(v_m2, 'musician', 'creature', 'on_summon');
  -- Mirror cinematic_complete_mint's ownership grant (serial 1 to the minter).
  PERFORM public.chit_grant(v_u, v_c1, 1, 'mint', v_m1);
  PERFORM public.chit_grant(v_u, v_c2, 1, 'mint', v_m2);
  UPDATE public.moment_chits SET finalized_at = NOW(), is_active = TRUE WHERE id IN (v_c1, v_c2);

  IF public.self_mint_slot(v_u) IS NOT NULL THEN
    RAISE EXCEPTION 'SMOKE FAIL: collection cards must not occupy the personal self-mint slot';
  END IF;
  IF (SELECT COUNT(*) FROM public.collection_chits WHERE collection_id = v_coll) <> 2 THEN
    RAISE EXCEPTION 'SMOKE FAIL: both cards must register as collection members';
  END IF;
  IF (SELECT status FROM public.collections WHERE id = v_coll) <> 'minting' THEN
    RAISE EXCEPTION 'SMOKE FAIL: collection must move draft → minting on first member';
  END IF;

  -- The personal swap/delete flows must refuse collection cards.
  v_err := FALSE;
  BEGIN
    PERFORM public.chit_swap_retire(v_u, v_c1, v_c2);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: swap-retire must refuse a collection card'; END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.chit_delete_owned(v_u, v_c1);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: delete must refuse a collection card'; END IF;

  -- Publish: supplies 3 + 5 → fee = 500 + 50×8 = 900c; copies serialize 1..N.
  PERFORM public.sim_seed_balance(v_u);
  SELECT balance_usd_cents INTO v_usd FROM public.sim_usd_balances WHERE user_id = v_u;
  v_res := public.collection_publish_internal(v_u, v_coll, 2500, jsonb_build_array(
    jsonb_build_object('chit_id', v_c1, 'total_supply', 3),
    jsonb_build_object('chit_id', v_c2, 'total_supply', 5)));
  IF (v_res->>'fee_cents')::INTEGER <> 900 THEN
    RAISE EXCEPTION 'SMOKE FAIL: mint fee must be 900c (got %)', v_res->>'fee_cents';
  END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u;
  IF v_cur <> v_usd - 900 THEN RAISE EXCEPTION 'SMOKE FAIL: fee must debit the sim USD rail'; END IF;

  SELECT COUNT(*) INTO v_c FROM public.chit_copies
  WHERE chit_id = v_c1 AND owner_user_id = v_u AND state = 'owned';
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u AND chit_id = v_c1;
  IF v_c <> 3 OR v_q <> 3 THEN
    RAISE EXCEPTION 'SMOKE FAIL: c1 must have 3 minter-owned copies (copies %, qty %)', v_c, v_q;
  END IF;
  IF (SELECT COUNT(*) FROM public.chit_copies WHERE chit_id = v_c2) <> 5
     OR (SELECT MAX(serial_number) FROM public.chit_copies WHERE chit_id = v_c2) <> 5
     OR EXISTS (SELECT 1 FROM public.chit_copies WHERE chit_id = v_c2 AND total_supply <> 5) THEN
    RAISE EXCEPTION 'SMOKE FAIL: c2 must serialize exactly 1..5 with denormalized supply 5';
  END IF;
  IF (SELECT status FROM public.collections WHERE id = v_coll) <> 'listed'
     OR (SELECT price_cents FROM public.collections WHERE id = v_coll) <> 2500 THEN
    RAISE EXCEPTION 'SMOKE FAIL: publish must list at the minter-set price';
  END IF;

  -- Supply is now fixed forever (mig-170 backstop) + replayed publish is a no-op.
  v_err := FALSE;
  BEGIN
    UPDATE public.moment_chits SET total_supply = 10 WHERE id = v_c2;
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: supply must be immutable after publish'; END IF;
  v_res := public.collection_publish_internal(v_u, v_coll, 9999, '[]'::JSONB);
  IF NOT (v_res->>'already_published')::BOOLEAN THEN
    RAISE EXCEPTION 'SMOKE FAIL: replayed publish must be a no-op';
  END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_u;
  IF v_cur <> v_usd - 900 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed publish must not re-charge'; END IF;

  -- Cleanup: dispose copies, retire chits, close the collection, drop scaffolding.
  PERFORM public.chit_grant(v_u, v_c1, -3, 'platform_correction');
  PERFORM public.chit_grant(v_u, v_c2, -5, 'platform_correction');
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_c1, v_c2);
  UPDATE public.collections SET status = 'closed', updated_at = NOW() WHERE id = v_coll;
  DELETE FROM public.kyc_verifications WHERE id = v_kyc;
  DELETE FROM public.platform_connections WHERE id = v_conn;

  RAISE NOTICE 'N2.2 smoke OK: eligibility gated, slot exempt, walls hold, fee 900c, copies 3+5 serialized, supply frozen, publish idempotent';
END $$;
