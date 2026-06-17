-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 113 — Licensing Marketplace: Public License Registry
-- Doc 5. Public-facing license status page for each agreement, served at
-- noraplatforms.com/license/[license_id]. No PII. Kept in sync by a trigger
-- on lkn_agreements (INSERT or status change).
--
-- ADJUSTED: renumbered 100 -> 113. Schema-qualified + public-read RLS added.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE public.lkn_public_registry (
  license_id                  TEXT PRIMARY KEY REFERENCES public.lkn_agreements(license_id),
  licensor_display_name       TEXT NOT NULL,
  licensor_image_url          TEXT,
  listing_category            TEXT NOT NULL,
  license_status              TEXT NOT NULL,
  effective_date              DATE NOT NULL,
  expiration_date             DATE,
  territory                   TEXT NOT NULL,
  permitted_purposes          TEXT[] NOT NULL,  -- human-readable list
  content_restrictions        TEXT[] NOT NULL,  -- human-readable list
  ai_use_allowed              BOOLEAN NOT NULL,
  last_verified_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Synced by trigger after lkn_agreements INSERT or status change.
CREATE OR REPLACE FUNCTION public.sync_lkn_public_registry()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_listing      public.lkn_listings%ROWTYPE;
  v_template     public.lkn_license_templates%ROWTYPE;
  v_purposes     TEXT[] := '{}';
  v_restrictions TEXT[] := '{}';
BEGIN
  SELECT * INTO v_listing  FROM public.lkn_listings           WHERE id = NEW.listing_id;
  SELECT * INTO v_template FROM public.lkn_license_templates  WHERE id = NEW.template_id;

  -- Human-readable permitted purposes from template
  IF v_template.purpose_ai_generated_content   THEN v_purposes := v_purposes || 'AI-generated content'; END IF;
  IF v_template.purpose_entertainment_game     THEN v_purposes := v_purposes || 'Video games & apps'; END IF;
  IF v_template.purpose_commercial_advertising THEN v_purposes := v_purposes || 'Commercial advertising'; END IF;
  IF v_template.purpose_entertainment_film     THEN v_purposes := v_purposes || 'Film production'; END IF;
  IF v_template.purpose_music                  THEN v_purposes := v_purposes || 'Music & music video'; END IF;
  IF v_template.purpose_social_media           THEN v_purposes := v_purposes || 'Social media content'; END IF;
  IF v_template.purpose_merchandise            THEN v_purposes := v_purposes || 'Merchandise'; END IF;

  -- Human-readable restrictions
  IF v_template.restrict_profanity     THEN v_restrictions := v_restrictions || 'No profanity'; END IF;
  IF v_template.restrict_adult_content THEN v_restrictions := v_restrictions || 'No adult content'; END IF;
  IF v_template.restrict_violence      THEN v_restrictions := v_restrictions || 'No depictions of violence'; END IF;

  INSERT INTO public.lkn_public_registry (
    license_id, licensor_display_name, licensor_image_url, listing_category,
    license_status, effective_date, expiration_date, territory,
    permitted_purposes, content_restrictions, ai_use_allowed
  ) VALUES (
    NEW.license_id, v_listing.licensor_display_name, v_listing.licensor_image_url,
    v_listing.category, NEW.status, NEW.effective_date, NEW.expiration_date,
    v_template.territory, v_purposes, v_restrictions,
    v_template.purpose_ai_generated_content OR v_template.purpose_ai_voice_cloning
      OR v_template.purpose_ai_image_generation
  )
  ON CONFLICT (license_id) DO UPDATE SET
    license_status   = EXCLUDED.license_status,
    last_verified_at = NOW();

  RETURN NEW;
END;
$$;

CREATE TRIGGER lkn_sync_public_registry
  AFTER INSERT OR UPDATE ON public.lkn_agreements
  FOR EACH ROW EXECUTE FUNCTION public.sync_lkn_public_registry();

-- ── Row Level Security: public registry is intentionally world-readable ──────
-- No PII here; this is the human-readable equivalent of the verification API.
-- Writes happen only through the SECURITY DEFINER trigger above.
ALTER TABLE public.lkn_public_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_public_registry_read_all" ON public.lkn_public_registry
  FOR SELECT USING (TRUE);
