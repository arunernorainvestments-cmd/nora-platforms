-- Migration 135: minting pipeline (Phase 6 — P6.1).
--
-- Moments → chits. The external edge pipeline handles social fetch, cel-shaded animation,
-- and AI family classification; the DB owns the orchestration + the invariant that a chit's
-- power is engagement-derived, never user-set (Hard Rule 34):
--   link (consent) → recommend (highest engagement) → [animate/classify externally] →
--   moderate → assign tier from engagement → mint via create_moment_chit.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 6.1.

-- ── extend moments with the pipeline state ──────────────────────────────────────
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS archetype_family  TEXT CHECK (archetype_family IN (
    'athlete','musician','artist','scientist','comedian',
    'influencer','politician','business','gamer','actor')),
  ADD COLUMN IF NOT EXISTS mint_status       TEXT NOT NULL DEFAULT 'linked'
    CHECK (mint_status IN ('linked','recommended','moderated','minted','rejected')),
  ADD COLUMN IF NOT EXISTS moderation_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (moderation_status IN ('pending','approved','rejected')),
  ADD COLUMN IF NOT EXISTS source_status     TEXT NOT NULL DEFAULT 'active'
    CHECK (source_status IN ('active','deleted','expired')),
  ADD COLUMN IF NOT EXISTS minted_chit_id    UUID REFERENCES public.moment_chits(id);

-- ── record / upsert a linked social moment (consent at link) ────────────────────
CREATE OR REPLACE FUNCTION public.moment_record(
  p_owner UUID, p_platform TEXT, p_external_id TEXT, p_url TEXT,
  p_thumbnail TEXT, p_engagement BIGINT, p_consent BOOLEAN DEFAULT TRUE
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.moments
    (owner_user_id, source_platform, source_external_id, source_url, thumbnail_url,
     engagement_count, engagement_synced_at, consent_granted_at)
  VALUES (p_owner, p_platform, p_external_id, p_url, p_thumbnail,
     GREATEST(COALESCE(p_engagement,0),0), NOW(),
     CASE WHEN p_consent THEN NOW() ELSE NULL END)
  ON CONFLICT (source_platform, source_external_id) DO UPDATE
    SET engagement_count = GREATEST(EXCLUDED.engagement_count, 0),
        engagement_synced_at = NOW(),
        thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, public.moments.thumbnail_url)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── recommend the owner's highest-engagement un-minted moment ────────────────────
CREATE OR REPLACE FUNCTION public.moment_recommend(p_owner UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT id FROM public.moments
  WHERE owner_user_id = p_owner AND source_status = 'active' AND minted_chit_id IS NULL
  ORDER BY engagement_count DESC
  LIMIT 1;
$$;

-- ── moderation gate ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.moment_moderate(p_moment_id UUID, p_approved BOOLEAN)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.moments
  SET moderation_status = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
      mint_status = CASE WHEN p_approved THEN 'moderated' ELSE 'rejected' END
  WHERE id = p_moment_id;
END;
$$;

-- ── mint: assign engagement tier + create the chit (users never set power) ───────
CREATE OR REPLACE FUNCTION public.moment_mint(
  p_moment_id         UUID,
  p_family            TEXT,          -- from AI classification
  p_chit_type         TEXT,
  p_timing            TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_name              TEXT DEFAULT NULL,
  p_keywords          TEXT[] DEFAULT '{}',
  p_vibe_gate         INTEGER DEFAULT NULL,
  p_moment_video_ref  TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_m public.moments%ROWTYPE; v_tier TEXT; v_chit UUID;
BEGIN
  SELECT * INTO v_m FROM public.moments WHERE id = p_moment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Moment not found: %', p_moment_id; END IF;
  IF v_m.consent_granted_at IS NULL THEN RAISE EXCEPTION 'No consent on moment'; END IF;
  IF v_m.moderation_status <> 'approved' THEN RAISE EXCEPTION 'Moment not moderation-approved'; END IF;
  IF v_m.minted_chit_id IS NOT NULL THEN RAISE EXCEPTION 'Moment already minted'; END IF;
  IF v_m.source_status <> 'active' THEN RAISE EXCEPTION 'Moment source is not active'; END IF;

  -- Tier assigned from CURRENT engagement (not user-set).
  v_tier := public.tier_for_engagement(v_m.engagement_count);

  v_chit := public.create_moment_chit(
    COALESCE(p_name, 'Moment ' || LEFT(p_moment_id::TEXT, 8)),
    p_family, p_chit_type, v_tier, p_timing, p_effect_template_id,
    'consent_minted', p_moment_id, COALESCE(p_keywords,'{}'), p_vibe_gate,
    v_m.thumbnail_url, p_moment_video_ref, NULL);

  UPDATE public.moments
  SET archetype_family = p_family, minted_chit_id = v_chit, mint_status = 'minted'
  WHERE id = p_moment_id;

  RETURN v_chit;
END;
$$;

-- ── RLS: owners see their own moments (mig 116 policy covers SELECT own) ─────────
-- Writes are via SECURITY DEFINER pipeline fns only.

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: engagement→tier mapping (mint's tier assignment) + mint rejects a
-- missing moment. (Full owner-scoped mint needs a real auth user — test-account pass.)
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_err BOOLEAN := FALSE;
BEGIN
  IF public.tier_for_engagement(0)       <> 'F' THEN RAISE EXCEPTION 'SMOKE FAIL: 0→F'; END IF;
  IF public.tier_for_engagement(999)     <> 'F' THEN RAISE EXCEPTION 'SMOKE FAIL: 999→F'; END IF;
  IF public.tier_for_engagement(1000)    <> 'E' THEN RAISE EXCEPTION 'SMOKE FAIL: 1k→E'; END IF;
  IF public.tier_for_engagement(60000)   <> 'C' THEN RAISE EXCEPTION 'SMOKE FAIL: 60k→C'; END IF;
  IF public.tier_for_engagement(6000000) <> 'S' THEN RAISE EXCEPTION 'SMOKE FAIL: 6M→S'; END IF;

  BEGIN
    PERFORM public.moment_mint(gen_random_uuid(), 'athlete', 'creature', 'on_summon');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: mint of missing moment should raise'; END IF;

  RAISE NOTICE 'P6.1 mint smoke OK: engagement→tier boundaries + missing-moment guard';
END $$;
