-- Migration 093: N.O.R.A. Emergency Fund — Pool, contributions, eligible voters.
-- Internal prefix: ubi_. All money movement is via Stripe API or sim mode only.
-- Stripe Treasury is sim-mode-only until the application clears (Hard Rule #4 in project memory).

-- ── Pool configuration (single-row global config) ────────────────────────────

CREATE TABLE ubi_pool_config (
  id                               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_treasury_account_id       TEXT,
  stripe_treasury_financial_account TEXT,
  mode                             TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated', 'live')),
  is_open_for_contributions        BOOLEAN NOT NULL DEFAULT TRUE,
  is_open_for_requests             BOOLEAN NOT NULL DEFAULT TRUE,
  max_request_pct_of_pool          DECIMAL(5,4) NOT NULL DEFAULT 0.1000,
  max_request_usd_cents            BIGINT NOT NULL DEFAULT 100000,
  min_contribution_to_vote_cents   BIGINT NOT NULL DEFAULT 100,
  vote_window_hours                INTEGER NOT NULL DEFAULT 72,
  inactive_voter_hours             INTEGER NOT NULL DEFAULT 24,
  post_approval_cooldown_days      INTEGER NOT NULL DEFAULT 90,
  created_at                       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO ubi_pool_config DEFAULT VALUES;

ALTER TABLE ubi_pool_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ubi_pool_config_public_read"
  ON ubi_pool_config FOR SELECT USING (TRUE);

-- ── Pool balance cache ────────────────────────────────────────────────────────
-- Authoritative balance lives in Stripe Treasury; this is a cached display value.

CREATE TABLE ubi_pool_balance_cache (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  balance_usd_cents     BIGINT NOT NULL DEFAULT 0,
  sim_balance_usd_cents BIGINT NOT NULL DEFAULT 0,
  last_synced_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO ubi_pool_balance_cache DEFAULT VALUES;

ALTER TABLE ubi_pool_balance_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ubi_pool_balance_public_read"
  ON ubi_pool_balance_cache FOR SELECT USING (TRUE);

-- ── Contributions ─────────────────────────────────────────────────────────────

CREATE TABLE ubi_pool_contributions (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id                  UUID REFERENCES auth.users(id),
  contributor_email        TEXT,

  amount_usd_cents         BIGINT NOT NULL CHECK (amount_usd_cents >= 100),
  is_recurring             BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id TEXT,
  stripe_subscription_id   TEXT,
  is_simulated             BOOLEAN NOT NULL DEFAULT FALSE,
  is_anonymous_display     BOOLEAN NOT NULL DEFAULT FALSE,

  status                   TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'failed', 'refunded')),
  confirmed_at             TIMESTAMPTZ,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX contributions_user_idx   ON ubi_pool_contributions (user_id, status);
CREATE INDEX contributions_status_idx ON ubi_pool_contributions (status, confirmed_at DESC);

ALTER TABLE ubi_pool_contributions ENABLE ROW LEVEL SECURITY;

-- Users can view their own contributions
CREATE POLICY "ubi_contributions_own_read"
  ON ubi_pool_contributions FOR SELECT
  USING (user_id = auth.uid());

-- Service role (edge functions) manages contributions — no client INSERT/UPDATE

-- ── Eligible voters view ──────────────────────────────────────────────────────
-- Users who have contributed at least min_contribution_to_vote_cents lifetime.

CREATE VIEW ubi_eligible_voters AS
  SELECT
    c.user_id,
    SUM(c.amount_usd_cents)  AS total_contributed_cents,
    COUNT(*)                 AS contribution_count,
    MAX(c.confirmed_at)      AS last_contributed_at
  FROM ubi_pool_contributions c
  WHERE c.status = 'confirmed'
    AND c.user_id IS NOT NULL
  GROUP BY c.user_id
  HAVING SUM(c.amount_usd_cents) >= (
    SELECT min_contribution_to_vote_cents FROM ubi_pool_config LIMIT 1
  );
