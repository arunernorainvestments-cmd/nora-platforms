-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 112 — Licensing Marketplace: Verification API Keys & Call Log
-- Doc 5. API keys for third-party platforms querying the verification endpoint.
-- Free to register. Free tier: 1,000 calls/day. Paid: $0.001/call above that.
--
-- ADJUSTED: renumbered 099 -> 112. Schema-qualified.
-- ADJUSTED: RLS enabled with NO client policies on both tables — API keys are
--           secrets and must NEVER be client-readable (Hard Rule 31). All access
--           is via the service role inside lkn-register-api-key / lkn-verify.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE public.lkn_api_keys (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key                     TEXT NOT NULL UNIQUE,  -- generated: lkn_live_[40 random chars]
  api_key_preview             TEXT NOT NULL,         -- first 12 chars for display
  owner_name                  TEXT NOT NULL,
  owner_email                 TEXT NOT NULL,
  owner_website               TEXT,
  intended_use_description    TEXT,

  -- Tier
  tier                        TEXT NOT NULL DEFAULT 'free'
    CHECK (tier IN ('free', 'commercial', 'partner')),
  daily_call_limit            INTEGER NOT NULL DEFAULT 1000,

  -- Usage tracking (reset daily by cron)
  calls_today                 INTEGER NOT NULL DEFAULT 0,
  calls_total                 BIGINT NOT NULL DEFAULT 0,
  last_reset_date             DATE NOT NULL DEFAULT CURRENT_DATE,

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_api_keys_key_idx ON public.lkn_api_keys (api_key, is_active);

-- Verification call log (for billing, abuse detection, analytics)
CREATE TABLE public.lkn_api_call_log (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key_id                  UUID NOT NULL REFERENCES public.lkn_api_keys(id),

  -- What was queried
  license_id                  TEXT,             -- if querying a specific license
  licensor_nora_id            UUID,             -- if querying by licensor
  licensee_nora_id            UUID,             -- if querying by licensee
  use_category                TEXT,             -- what the caller wants to do

  -- Result
  response_status             TEXT NOT NULL CHECK (response_status IN (
    'valid', 'invalid', 'expired', 'not_found', 'rate_limited', 'error'
  )),
  response_time_ms            INTEGER,

  caller_ip_hash              TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_call_log_key_idx ON public.lkn_api_call_log (api_key_id, created_at DESC);
CREATE INDEX lkn_call_log_lic_idx ON public.lkn_api_call_log (license_id);

-- ── Row Level Security: lock everything to the service role ──────────────────
-- No policies are defined intentionally. With RLS enabled and no policy, the
-- anon/authenticated roles get zero rows; only the service role (used by the
-- edge functions) can read/write. API keys must never reach a client.
ALTER TABLE public.lkn_api_keys    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lkn_api_call_log ENABLE ROW LEVEL SECURITY;

-- ── Daily reset of calls_today ───────────────────────────────────────────────
SELECT cron.schedule(
  'lkn-api-daily-reset',
  '0 0 * * *',
  $$UPDATE public.lkn_api_keys SET calls_today = 0, last_reset_date = CURRENT_DATE
    WHERE last_reset_date < CURRENT_DATE;$$
);
