-- Migration 184: the mint-reveal share loop + Founding Market Makers (Playset spec PHASE S4).
--
-- The §0.5 virality review's rank-1 and rank-2 items, as product, not as a marketing plan:
--
--   S4.1  Every completed mint produces a shareable 9:16 REVEAL asset. "My post became a
--         playable card" is the viral atom, and the person sharing it brings their own
--         audience — so the platform manufactures the shareable unit instead of hoping one
--         appears. reveal_asset_url hangs off the chit; the composer (edge fn
--         mint-reveal-compose + the stitch worker) fills it; the client shares it.
--
--   S4.2  A Founding Market Makers cohort flag, so 10–25 creators can be white-gloved
--         through KYC + social link + their own mint BEFORE public launch. Their reveals
--         are the launch campaign.
--
-- REPO-CHECK resolutions:
--
--   S4.1 (can nora-stitch compose the reveal, or is a second worker needed?) — ONE WORKER,
--     one small extension. /stitch already composes N segments (video + animated stills,
--     xfade, audio, arbitrary output WxH), so the 9:16 reveal — card-art still → cutscene
--     excerpt → tier/CardFace still — is expressible today. The one thing it could not do
--     was hold a persistent watermark over the whole composition, so this PR adds an
--     optional `watermark` overlay to /stitch (workers/stitch/server.js) rather than
--     standing up a second compose service. Sim mode composes from placeholder media, the
--     same honest-placeholder posture as the mint pipeline.
--     Client share: Flutter web has no universal share sheet, so the UI uses the browser
--     share API where present and falls back to download + copy-link (never a dead end).
--
--   S4.2 (can the cohort be onboarded against prod safely pre-launch?) — YES, and the one
--     real hazard is Hard Rule 15: founding Market Makers are REAL accounts whose whole
--     purpose is to appear in discovery. Flagging one as a test account would silently
--     erase them from every ranking. Enforced here as a constraint, not a convention: a
--     profile can never be both is_founding_market_maker and is_test_account.
--
-- Referral: the join link carries the existing referral code (/join?ref=…, mig 003/042).
-- Reward logic stays deferred to the challenge-emission framework, and there are NO card
-- rewards for referrals — free card emission tied to invites is exactly the sybil vector
-- the non-tradeable starter set exists to avoid (spec S4.1 "DO NOT").

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. THE REVEAL ASSET
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS reveal_asset_url    TEXT,
  ADD COLUMN IF NOT EXISTS reveal_generated_at TIMESTAMPTZ;

COMMENT ON COLUMN public.moment_chits.reveal_asset_url IS
  'Shareable 9:16 mint-reveal MP4 in battle-media (Playset spec S4.1) — the viral atom. '
  'Composed from artifacts the mint pipeline already produced; never a provider URL.';

-- Server-only writer: same Hard Rule 38 discipline as every other media field.
CREATE OR REPLACE FUNCTION public.chit_set_reveal_asset(p_chit_id UUID, p_url TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_url IS NULL OR p_url NOT LIKE '%/battle-media/%' THEN
    RAISE EXCEPTION 'reveal asset must be a battle-media object (Hard Rule 38)';
  END IF;

  UPDATE public.moment_chits
  SET reveal_asset_url = p_url, reveal_generated_at = NOW(), updated_at = NOW()
  WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.chit_set_reveal_asset(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- What the client needs to render the share sheet: the asset, the caption, and the
-- join link with THIS user's referral code already attached (no reward logic here —
-- the token is wired, the emission framework decides later what it is worth).
CREATE OR REPLACE FUNCTION public.mint_reveal_share_payload(p_chit_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_c    public.moment_chits%ROWTYPE;
  v_ref  TEXT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_c FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found'; END IF;

  -- Only a holder of the card may share its reveal.
  IF NOT EXISTS (SELECT 1 FROM public.chit_ownership
                 WHERE user_id = v_user AND chit_id = p_chit_id AND quantity > 0) THEN
    RAISE EXCEPTION 'You do not hold this card';
  END IF;

  SELECT referral_code INTO v_ref FROM public.profiles WHERE id = v_user;

  RETURN jsonb_build_object(
    'chit_id',    v_c.id,
    'name',       v_c.name,
    'tier',       v_c.tier,
    'asset_url',  v_c.reveal_asset_url,
    'card_art',   v_c.card_art_url,
    'ready',      v_c.reveal_asset_url IS NOT NULL,
    'caption',    'My moment is a playable card now — ' || v_c.name ||
                  ' (' || v_c.tier || '-Tier) on NORA.',
    'join_url',   'https://noraplatforms.com/join' ||
                  CASE WHEN v_ref IS NULL THEN '' ELSE '?ref=' || v_ref END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.mint_reveal_share_payload(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mint_reveal_share_payload(UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. FOUNDING MARKET MAKERS
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_founding_market_maker BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS founding_cohort_joined_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS profiles_founding_mm_idx
  ON public.profiles (is_founding_market_maker) WHERE is_founding_market_maker;

COMMENT ON COLUMN public.profiles.is_founding_market_maker IS
  'Founding Market Makers cohort (Playset spec S4.2): a cosmetic badge + launch-day '
  'featured row. Real accounts — never is_test_account (Hard Rule 15, REPO-CHECK S4.2).';

-- REPO-CHECK S4.2, enforced: a founding MM must be discoverable.
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_founding_mm_not_test;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_founding_mm_not_test
  CHECK (NOT (is_founding_market_maker AND is_test_account));

-- Client-proof: the cohort flag is set by operators, exactly like is_test_account.
CREATE OR REPLACE FUNCTION public.protect_founding_market_maker()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF OLD.is_founding_market_maker IS DISTINCT FROM NEW.is_founding_market_maker
     AND current_setting('role', true) NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    NEW.is_founding_market_maker  := OLD.is_founding_market_maker;
    NEW.founding_cohort_joined_at := OLD.founding_cohort_joined_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_founding_mm ON public.profiles;
CREATE TRIGGER trg_protect_founding_mm
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.protect_founding_market_maker();

CREATE OR REPLACE FUNCTION public.set_founding_market_maker(p_user UUID, p_on BOOLEAN DEFAULT TRUE)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_on AND EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user AND is_test_account) THEN
    RAISE EXCEPTION 'A founding Market Maker cannot be a test account (Hard Rule 15) — user %', p_user;
  END IF;

  UPDATE public.profiles
  SET is_founding_market_maker  = p_on,
      founding_cohort_joined_at = CASE WHEN p_on THEN COALESCE(founding_cohort_joined_at, NOW()) ELSE NULL END
  WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found: %', p_user; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.set_founding_market_maker(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- The launch-day featured row: cohort members and the card they minted. Public read
-- (it is a showcase), test accounts excluded by construction, and it exposes nothing
-- beyond what a profile page already shows.
CREATE OR REPLACE FUNCTION public.founding_market_maker_showcase(p_limit INTEGER DEFAULT 25)
RETURNS TABLE (
  user_id          UUID,
  display_name     TEXT,
  avatar_url       TEXT,
  joined_at        TIMESTAMPTZ,
  chit_id          UUID,
  chit_name        TEXT,
  tier             TEXT,
  card_art_url     TEXT,
  reveal_asset_url TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p.id, p.display_name, p.avatar_url, p.founding_cohort_joined_at,
         mc.id, mc.name, mc.tier, mc.card_art_url, mc.reveal_asset_url
  FROM public.profiles p
  LEFT JOIN LATERAL (
    SELECT c.id, c.name, c.tier, c.card_art_url, c.reveal_asset_url
    FROM public.moment_chits c
    JOIN public.moments m ON m.id = c.moment_id
    WHERE m.owner_user_id = p.id
      AND c.retired_at IS NULL AND c.is_active
      AND NOT c.is_generic
    ORDER BY c.created_at DESC
    LIMIT 1
  ) mc ON TRUE
  WHERE p.is_founding_market_maker AND NOT p.is_test_account
  ORDER BY p.founding_cohort_joined_at NULLS LAST
  LIMIT GREATEST(COALESCE(p_limit, 25), 1);
$$;

REVOKE ALL ON FUNCTION public.founding_market_maker_showcase(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.founding_market_maker_showcase(INTEGER) TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — reveal writes are bucket-guarded, share payload is holder-only,
-- and the cohort flag can never land on a test account.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u UUID; v_chit UUID; v_err BOOLEAN; v_msg TEXT; v_url TEXT; v_n INTEGER;
BEGIN
  BEGIN
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            's4-smoke@noraplatforms.com', '', NOW(), NOW(), NOW(), '{"full_name":"S4 Smoke"}');

    v_chit := public.create_moment_chit('S4 smoke card', 'gamer', 'creature', 'D');

    -- a provider URL can never become a reveal asset
    v_err := FALSE;
    BEGIN PERFORM public.chit_set_reveal_asset(v_chit, 'https://provider.example.com/reveal.mp4');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%battle-media%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: a provider URL must not become a reveal asset (got %)', v_msg;
    END IF;

    PERFORM public.chit_set_reveal_asset(
      v_chit, 'https://cceisywxwhgljdpisjrl.supabase.co/storage/v1/object/public/battle-media/reveals/x.mp4');
    SELECT reveal_asset_url INTO v_url FROM public.moment_chits WHERE id = v_chit;
    IF v_url IS NULL THEN RAISE EXCEPTION 'SMOKE FAIL: battle-media reveal must attach'; END IF;

    -- cohort flag never lands on a test account (Hard Rule 15)
    UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_u;
    v_err := FALSE;
    BEGIN PERFORM public.set_founding_market_maker(v_u, TRUE);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%cannot be a test account%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: a test account must not join the founding cohort (got %)', v_msg;
    END IF;

    -- a real account joins, shows up in the showcase, and leaves cleanly
    UPDATE public.profiles SET is_test_account = FALSE WHERE id = v_u;
    PERFORM public.set_founding_market_maker(v_u, TRUE);
    SELECT COUNT(*) INTO v_n FROM public.founding_market_maker_showcase(50) WHERE user_id = v_u;
    IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: cohort member must appear in the showcase'; END IF;

    -- and the CHECK constraint is the backstop if anything tries the other order
    v_err := FALSE;
    BEGIN UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_u;
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; END;
    IF NOT v_err THEN
      RAISE EXCEPTION 'SMOKE FAIL: a founding MM must not be flaggable as a test account';
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'S4 smoke OK: reveal assets are battle-media only, cohort excludes test accounts, showcase reads';
      ELSE
        RAISE;
      END IF;
  END;
END $$;
