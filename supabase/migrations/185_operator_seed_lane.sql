-- ═══════════════════════════════════════════════════════════════════════════════
-- 185 — OPERATOR SEED LANE
-- "Run the real cinematic pipeline against a card that has no post behind it."
--
-- THE PROBLEM
--   The mint pipeline's first gate (moment-ingest) is an allowlisted post URL plus
--   an OAuth-linked platform_connections row. That is Hard Rule 37 and it stays.
--   But house content has no social post to link — and pre-launch there is no way
--   to exercise the generation pipeline (illustration → cutscene → post-gen
--   moderation → preview) for a card the platform authors itself. mig 181 opened a
--   URL-less lane (admin_seed_moment) but it stops at admin_seed_attach_media:
--   media is bolted on after the fact, the CINEMATIC pipeline never runs.
--
-- WHAT THIS ADDS
--   A moment flagged is_platform_seed: no source_url, no OAuth link, owned by an
--   ADMIN operator so every downstream stage (moment-clip-attach, moment-classify,
--   cinematic-mint, chit_record_preview, chit_finalize_preview) works UNCHANGED —
--   they all key off moments.owner_user_id = the caller.
--
-- WHAT IT DOES NOT WEAKEN (this is the whole point)
--   * Hard Rule 37's consent leg is satisfied by OWNERSHIP, not by a social link —
--     the same carve-out mig 181 §5 already documents for platform Lane-A content.
--     There is no new path for a normal user: admin_seed_moment_operator RAISEs
--     unless profiles.is_admin.
--   * Moderation is NOT skipped. The seed moment still needs a recorded pre-gen
--     verdict before moment_mint will touch it, the uploaded clip is still
--     re-moderated at attach, and the finished MP4 still faces post-gen screening.
--     Minor-safety stays absolute on both legs.
--   * Stats stay ladder-derived (Hard Rule 34): the operator names a TARGET TIER and
--     the band's engagement FLOOR is fed through tier_for_engagement, exactly as
--     admin_seed_moment does. Tier is never hand-set.
--   * The card is stamped is_generic + seed_source='platform', so mig 181 §8's four
--     leak walls (marketplace / barter / wager stake / collection membership) and the
--     ascension refusal all apply to it. A card minted with no real post behind it can
--     never become a tradeable good — which is exactly what Hard Rule 37 protects.
--
-- SLOT: a seed card never occupies or consumes the ONE personal self-mint slot
-- (minting spec P4) — the operator is authoring house content, not their own card.
-- Same exemption shape as the collection lane (mig 171).
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. THE FLAG
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS is_platform_seed BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.moments.is_platform_seed IS
  'TRUE = authored through the operator seed lane (mig 185): no source_url, no OAuth '
  'platform link, owner is an admin. Hard Rule 37''s consent leg is satisfied by '
  'platform ownership of the content. Exempt from the personal self-mint slot; the '
  'resulting chit is stamped is_generic + seed_source=''platform'' so every leak wall '
  'in mig 181 §8 applies to it.';

CREATE INDEX IF NOT EXISTS moments_platform_seed_idx
  ON public.moments (owner_user_id) WHERE is_platform_seed;

-- A seed moment has no post, so it must never carry a source URL (belt for the
-- "it's really just an unverified user mint" failure mode).
ALTER TABLE public.moments DROP CONSTRAINT IF EXISTS moments_seed_has_no_url;
ALTER TABLE public.moments
  ADD CONSTRAINT moments_seed_has_no_url
  CHECK (NOT is_platform_seed OR source_url IS NULL);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. admin_seed_moment_operator — the URL-less source record, owned by the operator
--
-- Deliberately NOT the mig-181 admin_seed_moment: that one parks the moment on the
-- platform identity (which has no login, so no wizard session can ever drive it).
-- This one hands ownership to a real, admin-flagged operator account precisely so
-- the existing owner-scoped pipeline runs end to end with zero changes.
--
-- Idempotent on the derived external id so a resumed wizard re-uses the same row;
-- an ALREADY-MINTED collision is a clear error rather than a confusing failure four
-- stages later inside moment_mint.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_seed_moment_operator(
  p_operator    UUID,
  p_slug        TEXT,           -- operator-chosen label, e.g. 'bottle-flip'
  p_target_tier TEXT,           -- F..S; the engagement floor is derived from it
  p_post_title  TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_floor    BIGINT;
  v_external TEXT;
  v_existing public.moments%ROWTYPE;
  v_id       UUID;
BEGIN
  IF p_operator IS NULL THEN RAISE EXCEPTION 'Operator required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_operator AND is_admin) THEN
    RAISE EXCEPTION 'The seed lane is admin-only';
  END IF;
  IF p_slug IS NULL OR btrim(p_slug) = '' THEN RAISE EXCEPTION 'Seed name required'; END IF;

  -- Tier targeted by its OWN threshold floor, then derived back (Hard Rule 34) —
  -- identical to mig 181 §5. The operator never writes a stat.
  SELECT min_engagement INTO v_floor
  FROM public.engagement_tier_thresholds WHERE tier = p_target_tier;
  IF v_floor IS NULL THEN RAISE EXCEPTION 'Unknown target tier: %', p_target_tier; END IF;

  -- Deterministic per (operator, slug) so a resumed wizard lands on the same moment.
  v_external := 'seed:' || LEFT(p_operator::TEXT, 8) || ':' ||
                LEFT(regexp_replace(lower(btrim(p_slug)), '[^a-z0-9]+', '-', 'g'), 80);

  SELECT * INTO v_existing FROM public.moments
  WHERE source_platform = 'platform' AND source_external_id = v_external;

  IF FOUND THEN
    IF v_existing.owner_user_id <> p_operator THEN
      RAISE EXCEPTION 'Seed name % already belongs to another operator', p_slug;
    END IF;
    IF v_existing.minted_chit_id IS NOT NULL THEN
      RAISE EXCEPTION
        'Seed name "%" was already minted into card % — pick a different name',
        p_slug, v_existing.minted_chit_id;
    END IF;
    -- Resume: refresh the tier target + title, keep the clip/moderation state.
    UPDATE public.moments
    SET engagement_count     = v_floor,
        engagement_synced_at = NOW(),
        post_title           = COALESCE(LEFT(p_post_title, 300), post_title)
    WHERE id = v_existing.id;
    RETURN v_existing.id;
  END IF;

  INSERT INTO public.moments
    (owner_user_id, source_platform, source_external_id, source_url, thumbnail_url,
     post_title, engagement_count, engagement_synced_at, consent_granted_at,
     creator_handle, is_platform_seed)
  VALUES
    (p_operator, 'platform', v_external, NULL, NULL,
     LEFT(p_post_title, 300), v_floor, NOW(), NOW(),
     '@nora', TRUE)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Service-only, like every other mint-pipeline function (the mig 141 posture): a
-- client that could call this directly could author itself a card with no source.
REVOKE ALL ON FUNCTION public.admin_seed_moment_operator(UUID, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. moment_mint — the seed branch
-- mig 171's body verbatim, plus the marked seed lane and the platform stamp.
-- ═══════════════════════════════════════════════════════════════════════════════
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

  IF v_m.is_platform_seed THEN
    -- Operator seed lane (mig 185): house content authored by an admin. The personal
    -- self-mint slot is neither consumed nor swapped, and a seed card can never enter
    -- the collection lane (it is stamped generic below, which collection_chits refuses
    -- outright — fail here with the honest reason instead of at the trigger).
    IF p_swap_of IS NOT NULL THEN
      RAISE EXCEPTION 'A platform seed mint never swap-retires the personal card';
    END IF;
    IF v_m.collection_id IS NOT NULL THEN
      RAISE EXCEPTION 'A platform seed card cannot be minted into a collection';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_m.owner_user_id AND is_admin) THEN
      RAISE EXCEPTION 'Seed moment % is not owned by an admin operator', p_moment_id;
    END IF;

  ELSIF v_m.collection_id IS NOT NULL THEN
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

  IF v_m.is_platform_seed THEN
    -- The stamp is what makes this safe: mig 181 §8's marketplace / barter / wager /
    -- collection walls and the ascension refusal all key off exactly these two
    -- columns. A card with no post behind it is in-game use only, forever.
    UPDATE public.moment_chits
    SET is_generic  = TRUE,
        seed_source = 'platform'
    WHERE id = v_chit;
  END IF;

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

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. self_mint_slot — seed cards never occupy the personal slot
-- mig 171's body plus the marked filter. Without this, an operator's FIRST seed card
-- would block them from ever minting their own personal card (and vice versa).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.self_mint_slot(p_user UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT mc.id
  FROM public.moment_chits mc
  JOIN public.moments m ON m.id = mc.moment_id
  WHERE m.owner_user_id = p_user
    AND NOT m.is_platform_seed                 -- mig 185: house content, not their card
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

REVOKE ALL ON FUNCTION public.self_mint_slot(UUID) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. APPLY-TIME SMOKE
-- Runs against a dedicated smoke identity, never a real account (mig 181's posture:
-- seed residue must not land on a live profile). The identity is created once and
-- REUSED on re-runs rather than deleted: deleting it would cascade into
-- chit_acquisition_ledger and trip that table's append-only guard (mig 117). Leaving
-- it is the repo's stated discipline — "append-only residue lives on is_test_account
-- users; P7 sweeps" (mig 170) — so it carries is_test_account (Hard Rule 15 filters
-- it from every ranking and discovery query) and its admin flag is dropped on exit.
-- Proves: admin-only gate · no URL · tier derived from the floor · moderation still
-- mandatory · the chit lands generic+platform · the personal slot is untouched · a
-- SECOND seed mint is not blocked by the first.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_op    UUID;
  v_nobody UUID;
  v_m1 UUID; v_m2 UUID; v_c1 UUID; v_c2 UUID;
  v_c public.moment_chits%ROWTYPE;
  v_mom public.moments%ROWTYPE;
  v_floor BIGINT;
  v_err BOOLEAN;
BEGIN
  SELECT id INTO v_op FROM auth.users WHERE email = 'seed-lane-smoke@noraplatforms.com';
  IF v_op IS NULL THEN
    v_op := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_op, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'seed-lane-smoke@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"Seed Lane Smoke"}');
  END IF;
  -- Explicit rather than relying on the auth.users → handle_new_user trigger to have
  -- produced the row: if that trigger is ever absent or deferred, the smoke would
  -- otherwise fail with a confusing "admin-only" from three calls deeper.
  INSERT INTO public.profiles (id, is_admin, is_test_account)
  VALUES (v_op, TRUE, TRUE)
  ON CONFLICT (id) DO UPDATE SET is_admin = TRUE, is_test_account = TRUE;

  -- admin-only gate: a non-admin is refused
  SELECT id INTO v_nobody FROM public.profiles WHERE NOT COALESCE(is_admin, FALSE) LIMIT 1;
  IF v_nobody IS NOT NULL THEN
    v_err := FALSE;
    BEGIN
      PERFORM public.admin_seed_moment_operator(v_nobody, 'smoke-denied', 'C');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE;
    END;
    IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: seed lane must be admin-only'; END IF;
  END IF;

  -- the seed moment: no URL, engagement pinned to the target band's floor
  v_m1 := public.admin_seed_moment_operator(v_op, 'Smoke Card One', 'C', 'smoke brief');
  SELECT * INTO v_mom FROM public.moments WHERE id = v_m1;
  SELECT min_engagement INTO v_floor FROM public.engagement_tier_thresholds WHERE tier = 'C';
  IF v_mom.source_url IS NOT NULL THEN RAISE EXCEPTION 'SMOKE FAIL: seed moment must carry no source url'; END IF;
  IF NOT v_mom.is_platform_seed THEN RAISE EXCEPTION 'SMOKE FAIL: seed flag not set'; END IF;
  IF v_mom.engagement_count <> v_floor THEN
    RAISE EXCEPTION 'SMOKE FAIL: engagement must be the target tier floor (% vs %)',
      v_mom.engagement_count, v_floor;
  END IF;

  -- idempotent per (operator, slug): the wizard's resume path re-uses the row
  IF public.admin_seed_moment_operator(v_op, 'smoke card one', 'C') <> v_m1 THEN
    RAISE EXCEPTION 'SMOKE FAIL: same seed name must resume the same moment';
  END IF;

  -- moderation is NOT skipped for house content
  v_err := FALSE;
  BEGIN
    PERFORM public.moment_mint(v_m1, 'athlete', 'creature', 'on_summon');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: an unmoderated seed moment must not mint'; END IF;

  PERFORM public.moment_pre_gen_moderate(v_m1, 'approved', NULL, FALSE, 'sim');
  v_c1 := public.moment_mint(v_m1, 'athlete', 'creature', 'on_summon');

  SELECT * INTO v_c FROM public.moment_chits WHERE id = v_c1;
  IF NOT v_c.is_generic OR v_c.seed_source IS DISTINCT FROM 'platform' THEN
    RAISE EXCEPTION 'SMOKE FAIL: seed card must be stamped generic+platform (generic=%, source=%)',
      v_c.is_generic, v_c.seed_source;
  END IF;
  IF v_c.tier <> public.tier_for_engagement(v_floor) THEN
    RAISE EXCEPTION 'SMOKE FAIL: tier must be ladder-derived';
  END IF;

  -- hold a copy: the operator owns it, yet it must NOT occupy the personal slot
  PERFORM public.chit_grant(v_op, v_c1, 1, 'event');
  IF public.self_mint_slot(v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'SMOKE FAIL: a seed card must never occupy the self-mint slot';
  END IF;

  -- ...and a SECOND seed mint is not blocked by the first (the founder's actual need)
  v_m2 := public.admin_seed_moment_operator(v_op, 'Smoke Card Two', 'D');
  PERFORM public.moment_pre_gen_moderate(v_m2, 'approved', NULL, FALSE, 'sim');
  v_c2 := public.moment_mint(v_m2, 'gamer', 'creature', 'on_summon');
  IF v_c2 IS NULL THEN RAISE EXCEPTION 'SMOKE FAIL: second seed mint must succeed'; END IF;

  -- the leak walls hold: a seed card can never be staked. Assert on the REASON —
  -- a bare "it raised" would also pass for "no second player", proving nothing.
  v_err := FALSE;
  BEGIN
    PERFORM public.ccg_create_wager_match(
      v_op, NULL, v_c1, COALESCE(v_nobody, gen_random_uuid()), NULL, v_c2, TRUE);
  EXCEPTION WHEN OTHERS THEN v_err := (SQLERRM LIKE '%Generic cards cannot be staked%');
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: a seed card must never be wagerable'; END IF;

  -- cleanup. Three things are deliberately NOT deleted, because the tables that hold
  -- them refuse it by design: chit_acquisition_ledger and chit_copy_transfers are
  -- append-only (migs 117 / 170), so the holding is zeroed with a COMPENSATING entry
  -- and the operator row is retired in place rather than dropped — deleting the auth
  -- user would cascade into the ledger and RAISE. The moments and the catalog rows
  -- have no such guard, so those go properly.
  PERFORM public.chit_grant(v_op, v_c1, -1, 'platform_correction');
  UPDATE public.moment_chits SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_c1, v_c2);
  DELETE FROM public.moments WHERE id IN (v_m1, v_m2);
  -- no dormant admin left behind; is_test_account keeps the identity out of every
  -- ranking and discovery query in the meantime (Hard Rule 15).
  UPDATE public.profiles SET is_admin = FALSE WHERE id = v_op;

  RAISE NOTICE 'mig 185 smoke OK: operator seed lane (admin-gated, url-less, moderated, '
               'ladder-derived, generic+platform stamped, slot-exempt, unstakeable)';
END $$;
