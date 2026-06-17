-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 110 — Licensing Marketplace: License Templates (Toggle Parameters)
-- Doc 5. Defines every parameter for a given tier. The AI contract assembler
-- (lkn-generate-contract) translates these toggles into pre-approved clauses.
-- All toggles default to the most restrictive setting; the licensor opts in.
--
-- ADJUSTED: renumbered 097 -> 110. Schema-qualified + RLS added.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE public.lkn_license_templates (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tier_id                     UUID NOT NULL UNIQUE REFERENCES public.lkn_license_tiers(id) ON DELETE CASCADE,
  listing_id                  UUID NOT NULL REFERENCES public.lkn_listings(id),  -- denorm

  -- ── DURATION ──
  duration_type               TEXT NOT NULL DEFAULT 'fixed'
    CHECK (duration_type IN ('perpetual', 'fixed', 'project_specific')),
  expires_at                  TIMESTAMPTZ,       -- required if duration_type = 'fixed'
  project_description         TEXT,              -- required if duration_type = 'project_specific'

  -- ── TERRITORY ──
  territory                   TEXT NOT NULL DEFAULT 'worldwide'
    CHECK (territory IN ('worldwide', 'us_only', 'eu_only', 'specific')),
  territory_countries         TEXT[],            -- populated if territory = 'specific'

  -- ── PURPOSE (what the licensee can use the likeness FOR) ──
  purpose_ai_generated_content   BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_voice_cloning       BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_image_generation    BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_ai_model_training      BOOLEAN NOT NULL DEFAULT FALSE,  -- training datasets
  purpose_commercial_advertising BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_film     BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_tv       BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_entertainment_game     BOOLEAN NOT NULL DEFAULT FALSE,  -- video games / apps
  purpose_music                  BOOLEAN NOT NULL DEFAULT FALSE,  -- music video, album art
  purpose_social_media           BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_merchandise            BOOLEAN NOT NULL DEFAULT FALSE,  -- physical products
  purpose_nft_digital_asset      BOOLEAN NOT NULL DEFAULT FALSE,
  purpose_editorial_news         BOOLEAN NOT NULL DEFAULT TRUE,   -- always true (free speech baseline)
  purpose_custom_description     TEXT,                            -- additional allowed use

  -- ── CONTENT RESTRICTIONS (what the licensee CANNOT depict) ──
  restrict_profanity             BOOLEAN NOT NULL DEFAULT TRUE,   -- true = profanity NOT allowed
  restrict_adult_content         BOOLEAN NOT NULL DEFAULT TRUE,
  restrict_political_content     BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_religious_content     BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_violence              BOOLEAN NOT NULL DEFAULT TRUE,
  restrict_substance_use         BOOLEAN NOT NULL DEFAULT TRUE,   -- alcohol, tobacco, drugs
  restrict_competitor_brands     BOOLEAN NOT NULL DEFAULT FALSE,
  restrict_illegal_activity      BOOLEAN NOT NULL DEFAULT TRUE,   -- always enforced
  restricted_topics              TEXT[],                          -- free-text banned topics

  -- ── AI-SPECIFIC CONTROLS ──
  ai_generated_must_be_labeled   BOOLEAN NOT NULL DEFAULT TRUE,   -- "AI-generated" disclosure required
  ai_max_generated_instances     INTEGER,                         -- NULL = unlimited
  ai_no_deepfake_sexual          BOOLEAN NOT NULL DEFAULT TRUE,   -- always enforced; legal baseline
  ai_no_misleading_context       BOOLEAN NOT NULL DEFAULT TRUE,   -- no false impressions

  -- ── SUBLICENSING ──
  sublicensing_allowed           BOOLEAN NOT NULL DEFAULT FALSE,
  sublicensing_requires_approval BOOLEAN NOT NULL DEFAULT TRUE,

  -- ── APPROVAL RIGHTS ──
  approval_required_before_publish            BOOLEAN NOT NULL DEFAULT FALSE,
  approval_required_before_commercial_release BOOLEAN NOT NULL DEFAULT FALSE,
  approval_contact_email         TEXT,

  -- ── REVENUE SHARE ──
  revenue_share_pct              DECIMAL(5,2) NOT NULL DEFAULT 0,  -- 0 = no ongoing share
  -- ADJUSTED: dropped the stray NULL from doc5's IN-list (a CHECK passes on NULL
  -- automatically; the column is nullable). Keeps the constraint well-formed.
  revenue_share_applies_to       TEXT CHECK (revenue_share_applies_to IN (
    'gross_revenue', 'net_revenue', 'advertising_revenue'
  )),

  -- ── REVOCATION ──
  revocation_type                TEXT NOT NULL DEFAULT 'for_cause'
    CHECK (revocation_type IN ('for_cause', 'at_will_30_days', 'irrevocable')),

  -- ── CUSTOM ADDENDUM (attorney-drafted, uploaded as PDF) ──
  addendum_storage_path          TEXT,              -- Supabase Storage path
  addendum_description           TEXT,              -- plain-English summary

  -- ── AI-GENERATED CONTRACT (populated by lkn-generate-contract) ──
  generated_contract_text        TEXT,              -- full contract in plain English
  generated_contract_html        TEXT,              -- formatted version for display/signing
  contract_generated_at          TIMESTAMPTZ,
  contract_model_used            TEXT DEFAULT 'claude-sonnet-4-6',

  created_at                     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_templates_listing_idx ON public.lkn_license_templates (listing_id);

-- ── Row Level Security ───────────────────────────────────────────────────────
-- Public can read the template of an active listing (the listing detail page
-- renders permitted uses / restrictions from it). Licensor manages their own.
ALTER TABLE public.lkn_license_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_templates_public_read_active" ON public.lkn_license_templates
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.lkn_listings l
            WHERE l.id = listing_id AND l.status = 'active')
  );

CREATE POLICY "lkn_templates_owner_all" ON public.lkn_license_templates
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.lkn_listings l
            WHERE l.id = listing_id AND l.licensor_user_id = auth.uid())
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.lkn_listings l
            WHERE l.id = listing_id AND l.licensor_user_id = auth.uid())
  );
