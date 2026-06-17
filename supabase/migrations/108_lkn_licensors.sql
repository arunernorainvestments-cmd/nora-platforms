-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 108 — Right of Publicity Licensing Marketplace: Licensor Profiles
-- Doc 5. Tables prefixed lkn_. Append-only license records build on this.
--
-- ADJUSTED: doc5 numbered this 095; renumbered 108 (repo was at 107 — 095-100
--           are Emergency Fund/battle migrations). See doc5 self-audit protocol.
-- ADJUSTED: schema-qualified public.* and added RLS (doc5 SQL omitted both).
--           The nora-arena mobile app shares the anon key (doc6), so every
--           lkn_ table must be locked down at the DB layer, not just the API.
-- NOTE: the private Storage bucket 'lkn-partner-docs' is created manually via
--       the Supabase dashboard/CLI (this repo never creates buckets in SQL).
-- ─────────────────────────────────────────────────────────────────────────────

-- Licensor verification tiers:
-- Tier 1: Self  — individual using their own likeness (KYC + >=1 linked platform)
-- Tier 2: Agent — management/label/legal rep acting for talent (Partners Portal)
-- Tier 3: Celeb — platform-verified, from existing celebs table (is_integrated)

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS lkn_licensor_status TEXT DEFAULT NULL
    CHECK (lkn_licensor_status IN ('pending', 'verified', 'suspended', 'rejected')),
  ADD COLUMN IF NOT EXISTS lkn_licensor_tier  TEXT DEFAULT NULL
    CHECK (lkn_licensor_tier IN ('self', 'agent', 'celeb')),
  ADD COLUMN IF NOT EXISTS lkn_verified_at    TIMESTAMPTZ;

-- ── Licensor verification records (one row per verification event) ───────────
CREATE TABLE public.lkn_licensor_verifications (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  verification_tier           TEXT NOT NULL CHECK (verification_tier IN ('self','agent','celeb')),

  -- Tier 1 (self): KYC + social media links
  kyc_verification_id         UUID REFERENCES public.kyc_verifications(id),
  -- Minimum 1 linked platform required for self-tier
  linked_platform_count       INTEGER NOT NULL DEFAULT 0,

  -- Tier 2 (agent): Partners Portal approval
  partner_application_id      UUID,  -- FK added after lkn_partners is created below

  -- Tier 3 (celeb): linked from celebs table
  celeb_id                    UUID REFERENCES public.celebs(id),

  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  reviewed_by                 UUID REFERENCES auth.users(id),  -- N.O.R.A. staff account
  reviewed_at                 TIMESTAMPTZ,
  rejection_reason            TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_verif_user_idx   ON public.lkn_licensor_verifications (user_id, status);
CREATE INDEX lkn_verif_status_idx ON public.lkn_licensor_verifications (status, created_at DESC);

-- ── N.O.R.A. Partners Portal submissions ────────────────────────────────────
-- Management, labels, legal reps apply here to act on behalf of talent.
CREATE TABLE public.lkn_partners (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Applicant contact
  company_name                TEXT NOT NULL,
  representative_name         TEXT NOT NULL,
  representative_email        TEXT NOT NULL,
  representative_phone        TEXT,
  company_website             TEXT,

  -- Talent they represent
  talent_names                TEXT[] NOT NULL,  -- list of names they manage
  representation_type         TEXT NOT NULL CHECK (representation_type IN (
    'management', 'label', 'legal', 'publicist', 'studio', 'agency', 'other'
  )),

  -- Supporting documents (private Storage bucket 'lkn-partner-docs')
  document_storage_paths      TEXT[] NOT NULL DEFAULT '{}',

  -- Review
  status                      TEXT NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'under_review', 'approved', 'rejected')),
  nora_notes                  TEXT,
  reviewed_by                 UUID REFERENCES auth.users(id),
  reviewed_at                 TIMESTAMPTZ,

  -- Once approved, this partner gets a user account on the platform
  partner_user_id             UUID REFERENCES auth.users(id),

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_partners_status_idx ON public.lkn_partners (status, created_at DESC);
CREATE INDEX lkn_partners_email_idx  ON public.lkn_partners (representative_email);

-- ADJUSTED: wire the deferred FK now that lkn_partners exists.
ALTER TABLE public.lkn_licensor_verifications
  ADD CONSTRAINT lkn_verif_partner_fk
  FOREIGN KEY (partner_application_id) REFERENCES public.lkn_partners(id);

-- ── Row Level Security ───────────────────────────────────────────────────────
-- ADJUSTED: all writes that require N.O.R.A. review (approvals, partner intake)
-- go through SECURITY DEFINER edge functions using the service role, which
-- bypasses RLS. Client-facing policies below are intentionally read-own only.

ALTER TABLE public.lkn_licensor_verifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_verif_select_own" ON public.lkn_licensor_verifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "lkn_verif_insert_own" ON public.lkn_licensor_verifications
  FOR INSERT WITH CHECK (auth.uid() = user_id);

ALTER TABLE public.lkn_partners ENABLE ROW LEVEL SECURITY;

-- Partner applications arrive via the public lkn-partner-apply edge function
-- (service role). Once a partner_user_id is linked, that user can read their row.
CREATE POLICY "lkn_partners_select_linked" ON public.lkn_partners
  FOR SELECT USING (auth.uid() = partner_user_id);
