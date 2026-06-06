-- ─────────────────────────────────────────────────────────────────────────────
-- 087 — Celebrity Integration (Redesign Doc 1)
--
-- Adds columns linking the 25 Hot Topic celebs into the full market maker
-- system. Each celeb will get a system-managed profiles row created by the
-- `celebrity-integration-seed` edge function (built in doc 3), which is run
-- ONCE manually after this migration with the ADMIN_SEED_KEY env var set.
--
-- The doc's DO $$ block is intentionally omitted here: it can't create
-- auth.users rows from raw SQL (GoTrue owns that surface). The edge function
-- creates auth users via the service role, then this migration's columns
-- carry the linkage.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE profiles
  ADD COLUMN is_celeb             BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN celeb_id             UUID REFERENCES celebs(id),
  ADD COLUMN managed_by_platform  BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX profiles_is_celeb_idx
  ON profiles (is_celeb) WHERE is_celeb = TRUE;

CREATE INDEX profiles_celeb_id_idx
  ON profiles (celeb_id) WHERE celeb_id IS NOT NULL;

ALTER TABLE celebs
  ADD COLUMN profile_id              UUID REFERENCES profiles(id),
  ADD COLUMN managed_wallet_usd_cents BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN is_integrated           BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX celebs_profile_id_idx
  ON celebs (profile_id) WHERE profile_id IS NOT NULL;

-- Per doc:
--   managed_by_platform = TRUE → no login path, platform controls offerings,
--     match revenue accrues to celebs.managed_wallet_usd_cents instead of
--     token_balances (see distribute_match_revenue in doc 2).
--
-- AFTER deploying this migration: run the celebrity-integration-seed edge
-- function once with the x-admin-key header set to ADMIN_SEED_KEY. The
-- function will create one auth.users + profiles row per celeb and flip
-- celebs.is_integrated to TRUE.
