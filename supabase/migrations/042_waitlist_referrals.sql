-- Migration 042: Waitlist referral mechanics
-- Extends the existing waitlist table (which already has id as PK from migration 022).
-- Adds: referral_token, referred_by, referral_count.
-- Preserves all existing rows.

-- ── 1. Add columns (nullable first so backfill can run) ──────────────────────

ALTER TABLE waitlist
  ADD COLUMN IF NOT EXISTS referral_token text,
  ADD COLUMN IF NOT EXISTS referred_by    text,
  ADD COLUMN IF NOT EXISTS referral_count integer NOT NULL DEFAULT 0;

-- ── 2. Token generator (no uniqueness check — collision prob negligible at scale) ──

CREATE OR REPLACE FUNCTION generate_waitlist_token()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  bytes bytea;
  token text;
BEGIN
  bytes := gen_random_bytes(8);
  token := encode(bytes, 'base64');
  token := replace(replace(replace(token, '/', '_'), '+', '-'), '=', '');
  RETURN substring(token, 1, 10);
END;
$$;

-- ── 3. Backfill referral_token for any existing rows ─────────────────────────

UPDATE waitlist
SET referral_token = generate_waitlist_token()
WHERE referral_token IS NULL;

-- ── 4. Enforce NOT NULL + UNIQUE now that all rows have tokens ────────────────

ALTER TABLE waitlist
  ALTER COLUMN referral_token SET NOT NULL,
  ALTER COLUMN referral_token SET DEFAULT generate_waitlist_token();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'waitlist_referral_token_unique' AND conrelid = 'waitlist'::regclass
  ) THEN
    ALTER TABLE waitlist ADD CONSTRAINT waitlist_referral_token_unique UNIQUE (referral_token);
  END IF;
END $$;

-- ── 5. Primary key guard (already exists from migration 022 — no-op) ─────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'waitlist_pkey' AND conrelid = 'waitlist'::regclass
  ) THEN
    ALTER TABLE waitlist ADD PRIMARY KEY (id);
  END IF;
END $$;

-- ── 6. Indexes ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_waitlist_referral_token ON waitlist(referral_token);
CREATE INDEX IF NOT EXISTS idx_waitlist_referred_by    ON waitlist(referred_by);
CREATE INDEX IF NOT EXISTS idx_waitlist_created_at     ON waitlist(created_at);

-- ── 7. referred_by immutability trigger ──────────────────────────────────────

CREATE OR REPLACE FUNCTION protect_waitlist_referred_by()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.referred_by IS NOT NULL AND NEW.referred_by IS DISTINCT FROM OLD.referred_by THEN
    RAISE EXCEPTION 'referred_by is immutable after initial insert';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS waitlist_referred_by_immutable ON waitlist;

CREATE TRIGGER waitlist_referred_by_immutable
  BEFORE UPDATE ON waitlist
  FOR EACH ROW
  EXECUTE FUNCTION protect_waitlist_referred_by();

-- ── 8. Queue position functions (used by edge functions via service role) ─────

-- Returns queue_position and total_count for a given email.
CREATE OR REPLACE FUNCTION waitlist_position_by_email(p_email text)
RETURNS TABLE(queue_position bigint, total_count bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    (
      SELECT count(*) + 1
      FROM waitlist
      WHERE (
        -EXTRACT(EPOCH FROM created_at) + referral_count * 86400.0
      ) > (
        SELECT -EXTRACT(EPOCH FROM created_at) + referral_count * 86400.0
        FROM waitlist
        WHERE email = p_email
      )
    ) AS queue_position,
    (SELECT count(*) FROM waitlist) AS total_count;
$$;

-- Returns full row + queue_position + total_count for a given referral_token.
CREATE OR REPLACE FUNCTION waitlist_position_by_token(p_token text)
RETURNS TABLE(
  email          text,
  referral_token text,
  referral_count integer,
  created_at     timestamptz,
  queue_position bigint,
  total_count    bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH target AS (
    SELECT w.email, w.referral_token, w.referral_count, w.created_at,
           -EXTRACT(EPOCH FROM w.created_at) + w.referral_count * 86400.0 AS score
    FROM waitlist w
    WHERE w.referral_token = p_token
  )
  SELECT
    t.email,
    t.referral_token,
    t.referral_count,
    t.created_at,
    (SELECT count(*) + 1 FROM waitlist
     WHERE (-EXTRACT(EPOCH FROM created_at) + referral_count * 86400.0) > t.score
    ) AS queue_position,
    (SELECT count(*) FROM waitlist) AS total_count
  FROM target t;
$$;

-- RLS note: existing INSERT policy and no-SELECT policy remain unchanged.
-- Service role (used by edge functions) retains full access.
