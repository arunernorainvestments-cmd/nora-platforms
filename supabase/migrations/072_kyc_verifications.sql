-- Migration 072: KYC verifications table.
-- Identity verification via Stripe Identity (Phase 5 / live mode).
-- In simulated mode, kyc_simulate_approve() auto-approves with minimal data.
-- Re-verification required annually (expires_at = verified_at + 1 year).

CREATE TABLE public.kyc_verifications (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Verification status
  status                        TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','in_review','approved','rejected','expired')),
  provider                      TEXT NOT NULL DEFAULT 'stripe_identity',
  provider_session_id           TEXT,

  -- Verified identity (populated by provider on approval)
  verified_legal_name           TEXT,
  date_of_birth                 DATE,
  identity_document_type        TEXT CHECK (identity_document_type IN (
    'passport','drivers_license','national_id','residence_permit')),
  identity_document_country     TEXT,   -- ISO 3166-1 alpha-2
  verified_address_line1        TEXT,
  verified_address_city         TEXT,
  verified_address_country      TEXT,   -- ISO 3166-1 alpha-2

  -- AML / PEP
  pep_status                    BOOLEAN DEFAULT FALSE,
  sanctions_screened_at         TIMESTAMPTZ,
  sanctions_result              TEXT CHECK (sanctions_result IN ('clear','flagged','review')),
  source_of_funds_declaration   TEXT,

  -- Reg CF investor limits (US residents only — enforced at investment time)
  annual_income_usd_cents       BIGINT,
  net_worth_usd_cents           BIGINT,
  is_accredited_investor        BOOLEAN DEFAULT FALSE,
  reg_cf_invested_ytd_cents     BIGINT NOT NULL DEFAULT 0,
  reg_cf_limit_year             SMALLINT,

  -- Trusted contact / next of kin
  trusted_contact_name          TEXT,
  trusted_contact_email         TEXT,
  trusted_contact_phone         TEXT,
  trusted_contact_relationship  TEXT
    CHECK (trusted_contact_relationship IN ('spouse','parent','sibling','attorney','other')),
  trusted_contact_country       TEXT,

  -- Timestamps
  submitted_at                  TIMESTAMPTZ,
  verified_at                   TIMESTAMPTZ,
  expires_at                    TIMESTAMPTZ,
  rejected_reason               TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (user_id)
);

CREATE INDEX kyc_verifications_status_idx ON public.kyc_verifications (status);

-- RLS: users can see and update their own KYC row only.
ALTER TABLE public.kyc_verifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "kyc_select_own" ON public.kyc_verifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "kyc_insert_own" ON public.kyc_verifications
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "kyc_update_own" ON public.kyc_verifications
  FOR UPDATE USING (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- kyc_simulate_approve(p_user_id)
-- Used in simulation mode. Upserts a KYC row with status = 'approved',
-- no Stripe call, minimal data. Idempotent — safe to call multiple times.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.kyc_simulate_approve(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.kyc_verifications (
    user_id,
    status,
    provider,
    verified_at,
    expires_at,
    submitted_at
  )
  VALUES (
    p_user_id,
    'approved',
    'simulated',
    NOW(),
    NOW() + INTERVAL '1 year',
    NOW()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET status       = 'approved',
        provider     = 'simulated',
        verified_at  = NOW(),
        expires_at   = NOW() + INTERVAL '1 year';
END;
$$;
