-- ─────────────────────────────────────────────────────────────────────────────
-- 090 — KYC Simplification (Redesign Doc 1)
--
-- Removes Reg CF-specific columns from kyc_verifications now that the
-- Campaigns / Reg CF flow is deprecated. Identity verification (legal name,
-- DOB, sanctions screening, trusted contact) is kept — still needed for live
-- marketplace purchases and AML.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.kyc_verifications
  DROP COLUMN IF EXISTS annual_income_usd_cents,
  DROP COLUMN IF EXISTS net_worth_usd_cents,
  DROP COLUMN IF EXISTS is_accredited_investor,
  DROP COLUMN IF EXISTS reg_cf_invested_ytd_cents,
  DROP COLUMN IF EXISTS reg_cf_limit_year;
