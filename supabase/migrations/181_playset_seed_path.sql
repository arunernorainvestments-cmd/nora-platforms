-- Migration 181: Standard Playset — admin seed-mint path + generic/starter enforcement.
--
-- Standard Playset spec (NORA_PLATFORMS_STANDARD_PLAYSET_SPEC.md) PHASE S1. Gives the
-- platform a sanctioned way to author its own cards (Lane A: original meme-FORMAT content,
-- platform-owned outright) WITHOUT weakening a single user-facing rule:
--
--   * No user rule is suspended (§0.2). Users keep exactly one personal self-mint; the
--     seed path is a service-role path on a platform-managed identity, so it bypasses the
--     per-USER slot and nothing else. Moderation and ladder-derivation are NOT bypassed.
--   * Stats stay ladder-derived (Hard Rule 34): admin_seed_chit targets a tier by feeding
--     the tier band's engagement FLOOR through tier_for_engagement() — the same derivation
--     every user mint runs — then calls create_moment_chit(). No hand-set atk/hp/cost, ever.
--   * Platform cards never ascend, never reach the marketplace, never enter a barter, a
--     wager escrow, a collection, or the Mystery Pool submission path.
--
-- REPO-CHECK resolutions (recorded here + in the PR description, per spec §0):
--
--   S1.1 (does is_generic already exist?) — YES. Collections N6 (mig 175) added
--     moment_chits.is_generic plus the marketplace listing ban in
--     marketplace_list_chit_internal. This migration EXTENDS that concept rather than
--     owning it: starter cards ARE generic cards (is_generic = TRUE), and the remaining
--     leak paths N6 never had to close (barter, wager escrow, collection membership,
--     ascension) are closed here.
--
--   S1.2 (how does authored content target a tier?) — tier_for_engagement(BIGINT) reads
--     engagement_tier_thresholds (mig 122). The sanctioned way to target a tier for
--     authored content is therefore to pass that tier's threshold FLOOR as the platform
--     moment's engagement_count and let the same function decide — the tier is still
--     *derived*, and a ladder re-tune moves platform cards exactly like user cards.
--     Recorded as seed_source = 'platform'; ascension skips those cards (guard below).
--
--   S1.3 (does CardFace survive a null source_platform?) — the platform moment carries
--     source_platform = 'platform', which is neither in the mint allowlist nor in the
--     Flutter badge map, so the badge renders as absent. The Dart side additionally gets an
--     explicit "NORA" platform variant (card_face.dart, this PR) so the attribution reads
--     as authored, not as a missing value.
--
--   S1.4 (NEW — found while tracing mig 170) — SUPPLY. chit_copies serializes every
--     acquisition and moment_chits.total_supply is hard-capped at 1000. A playset card
--     granted 2 copies to every account would exhaust its supply at 500 users and then
--     start RAISEing inside signup. Starter cards are therefore UNSERIALIZED: the copy
--     machinery skips them (branch below), because "#3 of 100" is meaningless for a card
--     every account holds and which can never be traded, listed, staked, or pooled. The
--     mig-170 invariant (quantity == owned-copy count) is restated as: it holds for every
--     chit that is not a starter. Mystery-pool generics (mig 175) are untouched — they
--     keep fixed supply and real serials because they DO move between users.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. CATALOG COLUMNS — seed provenance + playset membership
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS seed_source TEXT
    CHECK (seed_source IS NULL OR seed_source IN ('platform')),
  ADD COLUMN IF NOT EXISTS is_starter  BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.moment_chits.seed_source IS
  'NULL = user-minted. ''platform'' = authored through admin_seed_chit (Standard Playset '
  'spec S1): platform-owned Lane-A content, moderated + ladder-derived, never ascends.';

COMMENT ON COLUMN public.moment_chits.is_starter IS
  'Member of the Standard Playset granted free to every account at signup. Implies '
  'is_generic (never listable/tradeable/barterable/stakeable) AND unserialized supply — '
  'the chit_copies machinery skips starters (mig 181 REPO-CHECK S1.4).';

CREATE INDEX IF NOT EXISTS moment_chits_starter_idx
  ON public.moment_chits (is_starter) WHERE is_starter;

-- A starter is always generic, and a platform card never carries a user's moment class.
ALTER TABLE public.moment_chits DROP CONSTRAINT IF EXISTS moment_chits_starter_is_generic;
ALTER TABLE public.moment_chits
  ADD CONSTRAINT moment_chits_starter_is_generic
  CHECK (NOT is_starter OR is_generic);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. LEDGER VOCABULARY — the signup grant reason.
-- The CHECK is rewritten WHOLESALE by every migration that extends it
-- (117 → 142 → 154 → 171 → 172 → 175 → here); the whole vocabulary must be carried
-- forward or the re-add fails against live rows.
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT IF EXISTS chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired',
    'marketplace_escrow','marketplace_return','marketplace_purchase',
    'collection_mint','collection_sale',
    'mystery_pool_submit','mystery_box_grant',
    'starter_grant'
  ));

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. COPY MACHINERY — starters are unserialized (REPO-CHECK S1.4).
-- Body is mig 175's verbatim plus the marked early return; the whole function is
-- restated because CREATE OR REPLACE cannot patch a fragment.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.apply_chit_ledger_to_copies()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n       INTEGER;
  v_supply  INTEGER;
  v_state   TEXT;
  v_copy    public.chit_copies%ROWTYPE;
  v_moved   INTEGER := 0;
  v_serial  INTEGER;
  v_starter BOOLEAN;
  i         INTEGER;
BEGIN
  SELECT total_supply, is_starter INTO v_supply, v_starter
  FROM public.moment_chits WHERE id = NEW.chit_id FOR UPDATE;
  IF v_supply IS NULL THEN
    RAISE EXCEPTION 'chit_copies machinery: unknown chit %', NEW.chit_id;
  END IF;

  -- S1 (mig 181): the Standard Playset is granted to EVERY account, so its supply is
  -- unbounded by design and cannot be serialized against the 1000-copy cap. Starters
  -- never trade, list, stake or pool, so there is nothing for a copy row to track:
  -- chit_ownership.quantity is the whole truth for them.
  IF COALESCE(v_starter, FALSE) THEN
    RETURN NEW;
  END IF;

  IF NEW.quantity_delta < 0 THEN
    v_n := -NEW.quantity_delta;
    v_state := CASE NEW.reason
      WHEN 'marketplace_escrow'   THEN 'listed_escrow'
      WHEN 'wager_escrow'         THEN 'wager_escrow'
      WHEN 'mystery_pool_submit'  THEN 'mystery_pool'
      ELSE 'released'
    END;

    FOR v_copy IN
      SELECT * FROM public.chit_copies
      WHERE chit_id = NEW.chit_id AND owner_user_id = NEW.user_id AND state = 'owned'
      ORDER BY serial_number
      LIMIT v_n
      FOR UPDATE
    LOOP
      UPDATE public.chit_copies
      SET state       = v_state,
          escrow_ref  = CASE WHEN v_state = 'released' THEN NULL ELSE NEW.reference_id END,
          transit_ref = CASE WHEN v_state = 'released' THEN NEW.reference_id ELSE NULL END,
          updated_at  = NOW()
      WHERE id = v_copy.id;
      v_moved := v_moved + 1;
    END LOOP;

    IF v_moved < v_n THEN
      RAISE EXCEPTION 'chit_copies machinery: user % holds % owned copies of chit %, needed %',
        NEW.user_id, v_moved, NEW.chit_id, v_n;
    END IF;

  ELSE
    v_n := NEW.quantity_delta;

    FOR i IN 1..v_n LOOP
      v_copy := NULL;

      IF NEW.reason = 'marketplace_purchase' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'listed_escrow' AND escrow_ref = NEW.reference_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'marketplace_return' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'listed_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id = NEW.user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'wager_won' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'wager_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id IS NOT DISTINCT FROM NEW.counterparty_user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'wager_return' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'wager_escrow' AND escrow_ref = NEW.reference_id
          AND owner_user_id = NEW.user_id
        ORDER BY serial_number LIMIT 1 FOR UPDATE;

      ELSIF NEW.reason = 'mystery_box_grant' THEN
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE id = NEW.reference_id AND chit_id = NEW.chit_id AND state = 'mystery_pool'
        FOR UPDATE;

      ELSIF NEW.reason IN ('mint','collection_mint') THEN
        NULL;  -- create-only below

      ELSE
        SELECT * INTO v_copy FROM public.chit_copies
        WHERE chit_id = NEW.chit_id AND state = 'released'
          AND transit_ref IS NOT DISTINCT FROM NEW.reference_id
          AND (NEW.counterparty_user_id IS NULL OR owner_user_id = NEW.counterparty_user_id)
        ORDER BY serial_number LIMIT 1 FOR UPDATE;
        IF v_copy.id IS NULL THEN
          SELECT * INTO v_copy FROM public.chit_copies
          WHERE chit_id = NEW.chit_id AND state = 'released'
            AND transit_ref IS NOT DISTINCT FROM NEW.reference_id
          ORDER BY serial_number LIMIT 1 FOR UPDATE;
        END IF;
        IF v_copy.id IS NULL THEN
          SELECT * INTO v_copy FROM public.chit_copies
          WHERE chit_id = NEW.chit_id AND state = 'released'
          ORDER BY serial_number LIMIT 1 FOR UPDATE;
        END IF;
      END IF;

      IF v_copy.id IS NOT NULL THEN
        UPDATE public.chit_copies
        SET owner_user_id = NEW.user_id, state = 'owned',
            escrow_ref = NULL, transit_ref = NULL, updated_at = NOW()
        WHERE id = v_copy.id;
        IF v_copy.owner_user_id IS DISTINCT FROM NEW.user_id THEN
          INSERT INTO public.chit_copy_transfers
            (copy_id, chit_id, serial_number, from_user_id, to_user_id, reason, reference_id)
          VALUES
            (v_copy.id, NEW.chit_id, v_copy.serial_number,
             v_copy.owner_user_id, NEW.user_id, NEW.reason, NEW.reference_id);
        END IF;

      ELSIF NEW.reason IN ('marketplace_purchase','marketplace_return','wager_won',
                           'wager_return','mystery_box_grant') THEN
        RAISE EXCEPTION 'chit_copies machinery: no escrowed copy for % (chit %, ref %)',
          NEW.reason, NEW.chit_id, NEW.reference_id;

      ELSE
        SELECT COALESCE(MAX(serial_number), 0) + 1 INTO v_serial
        FROM public.chit_copies WHERE chit_id = NEW.chit_id;
        IF v_serial > v_supply THEN
          RAISE EXCEPTION 'chit_copies machinery: supply exhausted for chit % (% of %)',
            NEW.chit_id, v_serial, v_supply;
        END IF;
        INSERT INTO public.chit_copies
          (chit_id, serial_number, total_supply, owner_user_id, state)
        VALUES (NEW.chit_id, v_serial, v_supply, NEW.user_id, 'owned')
        RETURNING * INTO v_copy;
        INSERT INTO public.chit_copy_transfers
          (copy_id, chit_id, serial_number, from_user_id, to_user_id, reason, reference_id)
        VALUES
          (v_copy.id, NEW.chit_id, v_serial, NULL, NEW.user_id, NEW.reason, NEW.reference_id);
      END IF;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. PLATFORM MINTER IDENTITY — the "no login" managed account
-- (celebrity-integration-seed / mystery-pool custodian pattern). Flagged
-- is_test_account so Hard Rule 15 sweeps keep it out of every ranking and
-- discovery query: it authors cards, it never plays.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM auth.users WHERE email = 'playset@noraplatforms.com';
  IF v_id IS NULL THEN
    v_id := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'playset@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"NORA Platform Playset"}');
  END IF;
  UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_id;
END $$;

CREATE OR REPLACE FUNCTION public.playset_seed_identity()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT id FROM auth.users WHERE email = 'playset@noraplatforms.com';
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. admin_seed_moment — the platform-owned source record.
-- Platform Lane-A content is owned outright, so there is no OAuth-ownership check
-- (Hard Rule 37's consent leg is satisfied by ownership, not by a social link) — but
-- everything else about a moment still applies: it carries a source record, it is
-- moderated before generation, and it is the anchor every downstream guard reads.
-- Idempotent on (source_platform, source_external_id) so a re-run re-uses the row.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_seed_moment(
  p_slug            TEXT,           -- stable brief id, e.g. 'playset:bottle-flip'
  p_target_tier     TEXT,           -- F..S; the engagement floor is derived from it
  p_thumbnail_url   TEXT DEFAULT NULL,
  p_post_title      TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_owner UUID := public.playset_seed_identity();
  v_floor BIGINT;
  v_id    UUID;
BEGIN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'playset seed identity is missing'; END IF;
  IF p_slug IS NULL OR btrim(p_slug) = '' THEN RAISE EXCEPTION 'seed slug required'; END IF;

  -- S1.2: target a tier by its OWN threshold floor, then let tier_for_engagement decide.
  SELECT min_engagement INTO v_floor
  FROM public.engagement_tier_thresholds WHERE tier = p_target_tier;
  IF v_floor IS NULL THEN RAISE EXCEPTION 'Unknown target tier: %', p_target_tier; END IF;

  INSERT INTO public.moments
    (owner_user_id, source_platform, source_external_id, source_url, thumbnail_url,
     post_title, engagement_count, engagement_synced_at, consent_granted_at, creator_handle)
  VALUES
    (v_owner, 'platform', p_slug, NULL, p_thumbnail_url,
     p_post_title, v_floor, NOW(), NOW(), '@nora')
  ON CONFLICT (source_platform, source_external_id) DO UPDATE
    SET engagement_count = EXCLUDED.engagement_count,
        engagement_synced_at = NOW(),
        thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, public.moments.thumbnail_url),
        post_title    = COALESCE(EXCLUDED.post_title, public.moments.post_title)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. admin_seed_chit — the service-role mint path for platform cards.
--
-- What it does NOT do (the whole point):
--   * does not set stats — create_moment_chit derives them from the ladder;
--   * does not skip moderation — the moment must carry an actual recorded verdict
--     from moment_pre_gen_moderate (status approved AND moderated_at AND a model
--     string). Platform content is not exempt (spec S1 "DO NOT").
--   * does not consume or bypass any USER's self-mint slot — the moment belongs to
--     the platform identity, so self_mint_slot() (which is user-scoped) never sees it.
--
-- Keywords: the effect template's grants_keywords ALWAYS apply; a brief may add
-- evergreen keywords on top (taunt/charge/shield/stealth — the CHECK on the column is
-- the allowlist). This is authored, house-owned balance, exactly like the mig-125
-- catalog seeds; it is not user input and it never touches cost/atk/hp/effect.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_seed_chit(
  p_moment_id          UUID,
  p_name               TEXT,
  p_family             TEXT,
  p_chit_type          TEXT,
  p_effect_template_id UUID,
  p_keywords           TEXT[] DEFAULT '{}',
  p_description        TEXT   DEFAULT NULL,
  p_vibe_gate          INTEGER DEFAULT NULL,
  p_is_starter         BOOLEAN DEFAULT TRUE,
  p_card_art_url       TEXT   DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_m      public.moments%ROWTYPE;
  v_tmpl   public.effect_templates%ROWTYPE;
  v_owner  UUID := public.playset_seed_identity();
  v_tier   TEXT;
  v_rank   INTEGER;
  v_kw     TEXT[];
  v_chit   UUID;
BEGIN
  SELECT * INTO v_m FROM public.moments WHERE id = p_moment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Seed moment not found: %', p_moment_id; END IF;
  IF v_m.owner_user_id IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'admin_seed_chit only mints platform-owned moments';
  END IF;
  IF v_m.minted_chit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Seed moment % already minted into chit %', p_moment_id, v_m.minted_chit_id;
  END IF;

  -- Moderation is mandatory for platform content too (spec S1 "DO NOT skip moderation").
  IF v_m.moderation_status <> 'approved'
     OR v_m.moderated_at IS NULL
     OR COALESCE(btrim(v_m.moderation_model), '') = '' THEN
    RAISE EXCEPTION
      'Seed moment % has no recorded pre-gen moderation verdict — run moment_pre_gen_moderate first',
      p_moment_id;
  END IF;

  -- Tier: derived (S1.2), never passed in.
  v_tier := public.tier_for_engagement(v_m.engagement_count);
  IF v_tier IS NULL THEN RAISE EXCEPTION 'Tier derivation failed for seed moment %', p_moment_id; END IF;

  -- Economy guard (spec §1.2 / gate "No A/S starters"): the free floor must never
  -- outclass the paid ceiling. Enforced here, not just in the slate data.
  SELECT tier_rank INTO v_rank FROM public.tier_ladder WHERE tier = v_tier;
  IF COALESCE(p_is_starter, TRUE) AND v_rank > (SELECT tier_rank FROM public.tier_ladder WHERE tier = 'C') THEN
    RAISE EXCEPTION 'Starter cards may not exceed tier C (got %) — economy guard', v_tier;
  END IF;

  IF p_effect_template_id IS NOT NULL THEN
    SELECT * INTO v_tmpl FROM public.effect_templates WHERE id = p_effect_template_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown effect template: %', p_effect_template_id; END IF;
  END IF;

  -- template-granted keywords ∪ authored evergreen keywords
  SELECT ARRAY(SELECT DISTINCT k FROM unnest(
           COALESCE(v_tmpl.grants_keywords, '{}'::TEXT[]) || COALESCE(p_keywords, '{}'::TEXT[])
         ) AS k WHERE k IS NOT NULL)
    INTO v_kw;

  v_chit := public.create_moment_chit(
    p_name, p_family, p_chit_type, v_tier,
    v_tmpl.timing_type, p_effect_template_id,
    'consent_minted', p_moment_id, v_kw, p_vibe_gate,
    COALESCE(p_card_art_url, v_m.thumbnail_url), NULL, p_description);

  UPDATE public.moment_chits
  SET is_generic             = TRUE,
      is_starter             = COALESCE(p_is_starter, TRUE),
      seed_source            = 'platform',
      character_class        = 'consent_minted',
      original_minter_handle = 'NORA',
      source_platform        = 'platform',
      finalized_at           = NOW()
  WHERE id = v_chit;

  UPDATE public.moments
  SET archetype_family = p_family, minted_chit_id = v_chit, mint_status = 'minted'
  WHERE id = p_moment_id;

  RETURN v_chit;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. admin_seed_attach_media — the sim→live media upgrade leg.
-- Cards are grantable and playable with placeholder media (the P6 pattern); when a
-- real render lands it is attached here. Two invariants ride along:
--   Hard Rule 38: the media lives in the battle-media bucket, never a provider URL.
--   Spec S1/§0.5:  post-generation moderation is mandatory — an unapproved verdict
--                  cannot attach, ever (clean bookends never vouch for the middle).
--
-- Either leg may be attached ALONE. Card art is the first thing a seed card gets
-- (it is what the collection, deck-builder and market surfaces render) and it
-- arrives long before any cutscene, so an art-only attach must not require an MP4 —
-- and must not blank an existing cutscene on the way through.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_seed_attach_media(
  p_chit_id      UUID,
  p_mp4_url      TEXT,           -- NULL = leave the cutscene untouched
  p_verdict      TEXT,
  p_card_art_url TEXT DEFAULT NULL,
  p_template_id  TEXT DEFAULT NULL,
  p_seed         BIGINT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_c public.moment_chits%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;
  IF v_c.seed_source IS DISTINCT FROM 'platform' THEN
    RAISE EXCEPTION 'admin_seed_attach_media only touches platform-seeded cards';
  END IF;
  IF p_verdict <> 'approved' THEN
    RAISE EXCEPTION 'Post-generation moderation verdict is % — media cannot be attached', p_verdict;
  END IF;
  IF p_mp4_url IS NULL AND p_card_art_url IS NULL THEN
    RAISE EXCEPTION 'Nothing to attach: pass an mp4 url, a card-art url, or both';
  END IF;
  IF p_mp4_url IS NOT NULL AND p_mp4_url NOT LIKE '%/battle-media/%' THEN
    RAISE EXCEPTION 'mp4 url must be a battle-media object (Hard Rule 38)';
  END IF;
  IF p_card_art_url IS NOT NULL AND p_card_art_url NOT LIKE '%/battle-media/%' THEN
    RAISE EXCEPTION 'card art url must be a battle-media object (Hard Rule 38)';
  END IF;

  UPDATE public.moment_chits
  SET mp4_cutscene_url      = COALESCE(p_mp4_url, mp4_cutscene_url),
      card_art_url          = COALESCE(p_card_art_url, card_art_url),
      match_cut_template_id = COALESCE(p_template_id, match_cut_template_id),
      generation_seed       = COALESCE(p_seed, generation_seed),
      updated_at            = NOW()
  WHERE id = p_chit_id;
END;
$$;

-- Service-only: the whole seed path is an operator tool, like every other
-- mint-pipeline function (mig 141 posture).
REVOKE ALL ON FUNCTION public.admin_seed_moment(TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_seed_chit(UUID, TEXT, TEXT, TEXT, UUID, TEXT[], TEXT, INTEGER, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_seed_attach_media(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.playset_seed_identity() FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. THE LEAK PATHS — generic cards are in-game assets, not goods.
-- N6 closed the marketplace. These are the four that were still open.
-- ═══════════════════════════════════════════════════════════════════════════════

-- 8a. Wager escrow. mig 142's body verbatim plus the marked guard.
CREATE OR REPLACE FUNCTION public.ccg_create_wager_match(
  p_seat1_user UUID, p_seat1_deck UUID, p_seat1_stake UUID,
  p_seat2_user UUID, p_seat2_deck UUID, p_seat2_stake UUID,
  p_is_test BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_match UUID; v_seat SMALLINT; v_user UUID; v_stake UUID;
BEGIN
  IF p_seat1_user IS NULL OR p_seat2_user IS NULL THEN
    RAISE EXCEPTION 'Wager matches need two real players';
  END IF;
  IF p_seat1_user = p_seat2_user THEN
    RAISE EXCEPTION 'A user cannot wager against themself';
  END IF;

  FOR v_seat IN 1..2 LOOP
    v_user  := CASE v_seat WHEN 1 THEN p_seat1_user  ELSE p_seat2_user  END;
    v_stake := CASE v_seat WHEN 1 THEN p_seat1_stake ELSE p_seat2_stake END;
    IF v_stake IS NULL THEN RAISE EXCEPTION 'Seat % stake chit required', v_seat; END IF;

    -- S1 (mig 181): a platform-authored card is never a stake — it has no scarcity
    -- to wager and transferring one would put a non-tradeable asset in play.
    IF EXISTS (SELECT 1 FROM public.moment_chits WHERE id = v_stake AND is_generic) THEN
      RAISE EXCEPTION 'Generic cards cannot be staked in a wager match';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.moment_chits mc
      JOIN public.chit_ownership co ON co.chit_id = mc.id AND co.user_id = v_user
      WHERE mc.id = v_stake AND mc.retired_at IS NULL AND mc.is_active AND co.quantity > 0
    ) THEN
      RAISE EXCEPTION 'Seat % does not hold a live, finalized copy of stake chit %', v_seat, v_stake;
    END IF;
  END LOOP;

  v_match := public.ccg_create_match(p_seat1_user, p_seat1_deck, p_seat2_user, p_seat2_deck, p_is_test);
  UPDATE public.ccg_matches SET match_type = 'wager' WHERE id = v_match;

  FOR v_seat IN 1..2 LOOP
    v_user  := CASE v_seat WHEN 1 THEN p_seat1_user  ELSE p_seat2_user  END;
    v_stake := CASE v_seat WHEN 1 THEN p_seat1_stake ELSE p_seat2_stake END;
    INSERT INTO public.ccg_wager_escrow (match_id, seat, user_id, chit_id)
    VALUES (v_match, v_seat, v_user, v_stake);
    PERFORM public.chit_grant(v_user, v_stake, -1, 'wager_escrow', v_match);
  END LOOP;

  RETURN v_match;
END;
$$;

REVOKE ALL ON FUNCTION public.ccg_create_wager_match(UUID, UUID, UUID, UUID, UUID, UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated;

-- 8b. Barter. mig 119's body verbatim plus the marked guard (both sides — a generic
-- can be neither offered nor requested).
CREATE OR REPLACE FUNCTION public.chit_barter_create_offer(
  p_counterparty  UUID,
  p_offer         JSONB,
  p_request       JSONB
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_initiator UUID := auth.uid();
  v_offer_id  UUID;
  v_kyc       BOOLEAN;
BEGIN
  IF v_initiator IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF v_initiator = p_counterparty THEN RAISE EXCEPTION 'Cannot barter with yourself'; END IF;

  -- S1 (mig 181): platform-authored cards are in-game use only, on both sides.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(p_offer->'chits','[]'::jsonb)
                              || COALESCE(p_request->'chits','[]'::jsonb)) AS e
    JOIN public.moment_chits mc ON mc.id = (e->>'chit_id')::UUID
    WHERE mc.is_generic
  ) THEN
    RAISE EXCEPTION 'Generic cards cannot be bartered';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_offer->'chits','[]'::jsonb)) AS e
    LEFT JOIN public.chit_ownership co
      ON co.user_id = v_initiator AND co.chit_id = (e->>'chit_id')::UUID
    WHERE COALESCE(co.quantity,0) < (e->>'quantity')::INTEGER
  ) THEN
    RAISE EXCEPTION 'You do not own all offered chits';
  END IF;

  v_kyc := public._barter_touches_licensed(p_offer) OR public._barter_touches_licensed(p_request);

  INSERT INTO public.chit_barter_offers
    (initiator_user_id, counterparty_user_id, offer, request, requires_kyc)
  VALUES (v_initiator, p_counterparty, p_offer, p_request, v_kyc)
  RETURNING id INTO v_offer_id;

  RETURN v_offer_id;
END;
$$;

-- 8c. Collection membership — a generic can never become a collection card (which
-- would make it sellable through the collection lane). Trigger, not application code.
CREATE OR REPLACE FUNCTION public.collection_chits_block_generic()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.moment_chits WHERE id = NEW.chit_id AND is_generic) THEN
    RAISE EXCEPTION 'Generic cards cannot join a collection (chit %)', NEW.chit_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS collection_chits_no_generic ON public.collection_chits;
CREATE TRIGGER collection_chits_no_generic
  BEFORE INSERT OR UPDATE ON public.collection_chits
  FOR EACH ROW EXECUTE FUNCTION public.collection_chits_block_generic();

-- 8d. Ascension — platform cards never ascend (locked decision, spec §2 / Q3).
-- Belt: the re-derivation itself refuses. Braces: the weekly refresh skips them
-- (they hang off a platform-owned moment, so a user scan never reached them anyway).
CREATE OR REPLACE FUNCTION public.moment_chit_rederive(p_chit_id UUID, p_new_tier TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_c public.moment_chits%ROWTYPE; v_stats JSONB;
BEGIN
  SELECT * INTO v_c FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;

  -- S1 (mig 181): ascension is the reward for real engagement on YOUR content.
  IF v_c.seed_source = 'platform' OR v_c.is_generic THEN
    RAISE EXCEPTION 'Platform-authored cards never ascend (chit %)', p_chit_id;
  END IF;

  v_stats := public.derive_chit_stats(p_new_tier, v_c.chit_type, v_c.effect_ref);

  UPDATE public.moment_chits SET
    tier             = p_new_tier,
    aura_cost        = (v_stats->>'aura_cost')::INTEGER,
    atk              = (v_stats->>'atk')::INTEGER,
    hp               = (v_stats->>'hp')::INTEGER,
    effect_magnitude = (v_stats->>'effect_magnitude')::INTEGER,
    updated_at       = NOW()
  WHERE id = p_chit_id;
END;
$$;

REVOKE ALL ON FUNCTION public.moment_chit_rederive(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- mig 157's body verbatim plus the marked filter.
CREATE OR REPLACE FUNCTION public.chit_ascension_refresh(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
  r RECORD;
  v_new_tier TEXT; v_new_rank INTEGER; v_cur_rank INTEGER; v_jump INTEGER;
  v_ascended JSONB := '[]'::JSONB;
  v_queued   JSONB := '[]'::JSONB;
BEGIN
  SELECT MAX(refreshed_at) INTO v_last FROM public.chit_ascension_log WHERE user_id = p_user_id;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '7 days' THEN
    RAISE EXCEPTION 'Ascension refresh is available once per 7 days';
  END IF;

  FOR r IN
    SELECT m.engagement_count AS eng, mc.id AS chit_id, mc.name AS chit_name, mc.tier AS cur_tier
    FROM public.moments m
    JOIN public.moment_chits mc ON mc.id = m.minted_chit_id
    WHERE m.owner_user_id = p_user_id
      AND m.source_status = 'active'
      AND m.minted_chit_id IS NOT NULL
      AND NOT mc.is_generic                          -- S1 (mig 181): platform cards never ascend
      AND mc.seed_source IS DISTINCT FROM 'platform' -- S1 (mig 181)
      AND NOT EXISTS (SELECT 1 FROM public.marketplace_listings ml
                      WHERE ml.chit_id = mc.id AND ml.status = 'active')
  LOOP
    v_new_tier := public.tier_for_engagement(r.eng);
    SELECT tier_rank INTO v_new_rank FROM public.tier_ladder WHERE tier = v_new_tier;
    SELECT tier_rank INTO v_cur_rank FROM public.tier_ladder WHERE tier = r.cur_tier;

    IF v_new_rank > v_cur_rank THEN
      v_jump := v_new_rank - v_cur_rank;
      IF v_jump >= 3 THEN
        INSERT INTO public.ascension_review_queue (chit_id, user_id, from_tier, to_tier, engagement)
        VALUES (r.chit_id, p_user_id, r.cur_tier, v_new_tier, r.eng);
        v_queued := v_queued || jsonb_build_object(
          'chit_id', r.chit_id, 'name', r.chit_name,
          'from_tier', r.cur_tier, 'to_tier', v_new_tier);
      ELSE
        PERFORM public.moment_chit_rederive(r.chit_id, v_new_tier);
        v_ascended := v_ascended || jsonb_build_object(
          'chit_id', r.chit_id, 'name', r.chit_name,
          'from_tier', r.cur_tier, 'to_tier', v_new_tier);
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.chit_ascension_log (user_id) VALUES (p_user_id);
  RETURN jsonb_build_object(
    'ascended',          jsonb_array_length(v_ascended),
    'queued_for_review', jsonb_array_length(v_queued),
    'ascensions',        v_ascended,
    'queued',            v_queued,
    'next_refresh_at',   NOW() + INTERVAL '7 days'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.chit_ascension_refresh(UUID) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE (rollback-sentinel subtxn, mig 150/157 pattern — no residue).
-- Proves: the seed path refuses unmoderated content · tier is ladder-derived from the
-- band floor, not passed in · A/S starters are refused · the card is generic, starter,
-- unserialized, and playable · listing / staking / bartering / collecting / ascending
-- one all RAISE · media attach honours Hard Rule 38 + post-gen moderation · the
-- non-starter invariant (quantity == owned copies) still holds table-wide.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_mom UUID; v_mom2 UUID; v_chit UUID; v_tmpl UUID; v_coll UUID;
  v_c public.moment_chits%ROWTYPE;
  v_err BOOLEAN; v_msg TEXT; v_url TEXT; v_n INTEGER; v_q INTEGER;
BEGIN
  BEGIN
    SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
    SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
    IF v_u1 IS NULL OR v_u2 IS NULL THEN
      RAISE EXCEPTION 'mig 181 smoke needs the mig-155 smoke users';
    END IF;

    SELECT id INTO v_tmpl FROM public.effect_templates WHERE key = 'athlete_on_summon_highlight';

    -- ── moderation is not optional, even for the platform ──────────────────────
    v_mom := public.admin_seed_moment('playset:s1-smoke', 'D', NULL, 'S1 smoke brief');
    v_err := FALSE;
    BEGIN
      PERFORM public.admin_seed_chit(v_mom, 'S1 smoke card', 'athlete', 'creature', v_tmpl);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
    END;
    IF NOT v_err OR v_msg NOT LIKE '%pre-gen moderation%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: unmoderated seed must be refused (got %)', v_msg;
    END IF;

    -- ── moderated: tier derives from the D band floor, stats from the ladder ───
    PERFORM public.moment_pre_gen_moderate(v_mom, 'approved', '{"platform_lane_a": true}'::JSONB, FALSE, 'sim');
    v_chit := public.admin_seed_chit(v_mom, 'S1 smoke card', 'athlete', 'creature', v_tmpl,
                                     ARRAY['taunt']::TEXT[], 'S1 smoke.', NULL, TRUE, NULL);
    SELECT * INTO v_c FROM public.moment_chits WHERE id = v_chit;
    IF v_c.tier <> 'D' THEN
      RAISE EXCEPTION 'SMOKE FAIL: D-band floor must derive tier D (got %)', v_c.tier;
    END IF;
    IF v_c.aura_cost IS NULL OR v_c.atk IS NULL OR v_c.hp IS NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: stats must be ladder-derived, not null';
    END IF;
    IF NOT v_c.is_generic OR NOT v_c.is_starter OR v_c.seed_source <> 'platform'
       OR v_c.original_minter_handle <> 'NORA' OR v_c.finalized_at IS NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: seed stamps wrong (%, %, %, %)',
        v_c.is_generic, v_c.is_starter, v_c.seed_source, v_c.original_minter_handle;
    END IF;
    -- template keyword (charge) ∪ authored keyword (taunt)
    IF NOT ('charge' = ANY(v_c.keywords)) OR NOT ('taunt' = ANY(v_c.keywords)) THEN
      RAISE EXCEPTION 'SMOKE FAIL: keywords must union template grants + brief (got %)', v_c.keywords;
    END IF;

    -- ── no A/S starters (economy guard) ───────────────────────────────────────
    v_mom2 := public.admin_seed_moment('playset:s1-smoke-hi', 'S', NULL, NULL);
    PERFORM public.moment_pre_gen_moderate(v_mom2, 'approved', NULL, FALSE, 'sim');
    v_err := FALSE;
    BEGIN
      PERFORM public.admin_seed_chit(v_mom2, 'S1 smoke overpowered', 'gamer', 'creature', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
    END;
    IF NOT v_err OR v_msg NOT LIKE '%may not exceed tier C%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: an S-tier starter must be refused (got %)', v_msg;
    END IF;

    -- ── grantable + playable, and UNSERIALIZED (REPO-CHECK S1.4) ──────────────
    PERFORM public.chit_grant(v_u1, v_chit, 2, 'starter_grant');
    SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_chit;
    IF v_q <> 2 THEN RAISE EXCEPTION 'SMOKE FAIL: grant must yield 2 copies (got %)', v_q; END IF;
    SELECT COUNT(*) INTO v_n FROM public.chit_copies WHERE chit_id = v_chit;
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'SMOKE FAIL: starters must not be serialized (got % copy rows)', v_n;
    END IF;

    -- ── every leak path RAISEs ────────────────────────────────────────────────
    v_err := FALSE;
    BEGIN PERFORM public.marketplace_list_chit_internal(v_u1, v_chit, 'token', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%Generic cards cannot be listed%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: listing a starter must RAISE (got %)', v_msg;
    END IF;

    v_err := FALSE;
    BEGIN PERFORM public.ccg_create_wager_match(v_u1, NULL, v_chit, v_u2, NULL, v_chit, TRUE);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%cannot be staked%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: staking a starter must RAISE (got %)', v_msg;
    END IF;

    -- Direct INSERT (mig 175 smoke pattern): the point is the membership trigger, and
    -- collection_create_internal would first demand minter eligibility we do not need here.
    INSERT INTO public.collections (market_maker_user_id, title)
    VALUES (v_u1, 'S1 smoke collection') RETURNING id INTO v_coll;
    v_err := FALSE;
    BEGIN
      INSERT INTO public.collection_chits (collection_id, chit_id) VALUES (v_coll, v_chit);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%cannot join a collection%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: collecting a starter must RAISE (got %)', v_msg;
    END IF;

    v_err := FALSE;
    BEGIN PERFORM public.moment_chit_rederive(v_chit, 'A');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%never ascend%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: ascending a starter must RAISE (got %)', v_msg;
    END IF;

    -- ── media attach: bucket + post-gen verdict both enforced ─────────────────
    v_err := FALSE;
    BEGIN PERFORM public.admin_seed_attach_media(v_chit, 'https://cdn.example.com/battle-media/x.mp4', 'rejected');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%moderation verdict%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: rejected media must not attach (got %)', v_msg;
    END IF;
    v_err := FALSE;
    BEGIN PERFORM public.admin_seed_attach_media(v_chit, 'https://provider.example.com/out.mp4', 'approved');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%battle-media%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: a hotlinked provider URL must not attach (got %)', v_msg;
    END IF;
    PERFORM public.admin_seed_attach_media(
      v_chit, 'https://cceisywxwhgljdpisjrl.supabase.co/storage/v1/object/public/battle-media/seed/x.mp4', 'approved');
    SELECT mp4_cutscene_url INTO v_msg FROM public.moment_chits WHERE id = v_chit;
    IF v_msg IS NULL THEN RAISE EXCEPTION 'SMOKE FAIL: approved battle-media attach must land'; END IF;

    -- art-only attach: allowed, bucket-guarded, and it must NOT blank the cutscene
    v_err := FALSE;
    BEGIN PERFORM public.admin_seed_attach_media(v_chit, NULL, 'approved', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%Nothing to attach%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: an empty attach must RAISE (got %)', v_msg;
    END IF;
    v_err := FALSE;
    BEGIN
      PERFORM public.admin_seed_attach_media(v_chit, NULL, 'approved', 'https://provider.example.com/art.png');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%card art url must be a battle-media object%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: a hotlinked art URL must not attach (got %)', v_msg;
    END IF;
    PERFORM public.admin_seed_attach_media(
      v_chit, NULL, 'approved',
      'https://cceisywxwhgljdpisjrl.supabase.co/storage/v1/object/public/battle-media/playset/art/x.png');
    SELECT card_art_url, mp4_cutscene_url INTO v_msg, v_url FROM public.moment_chits WHERE id = v_chit;
    IF v_msg IS NULL THEN RAISE EXCEPTION 'SMOKE FAIL: art-only attach must land'; END IF;
    IF v_url IS NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: an art-only attach must not blank the cutscene';
    END IF;

    -- ── the copy invariant, restated for non-starters ─────────────────────────
    SELECT COUNT(*) INTO v_n FROM (
      SELECT o.user_id, o.chit_id, o.quantity,
             (SELECT COUNT(*) FROM public.chit_copies c
              WHERE c.chit_id = o.chit_id AND c.owner_user_id = o.user_id
                AND c.state = 'owned') AS copies
      FROM public.chit_ownership o
      JOIN public.moment_chits mc ON mc.id = o.chit_id
      WHERE NOT mc.is_starter
    ) t WHERE t.quantity <> t.copies;
    IF v_n > 0 THEN
      RAISE EXCEPTION 'SMOKE FAIL: % non-starter rows where quantity <> owned copies', v_n;
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'S1 smoke OK: moderation enforced, tier derived, no A/S starters, unserialized, all leak paths closed';
      ELSE
        RAISE;
      END IF;
  END;
END $$;
