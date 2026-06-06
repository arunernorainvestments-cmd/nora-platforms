-- Migration 094: N.O.R.A. Emergency Fund — Withdrawal requests and supporting documents.
-- Documents (ubi_request_documents) are NEVER exposed to clients — AI only (Hard Rule #2).

CREATE TABLE ubi_withdrawal_requests (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_user_id           UUID NOT NULL REFERENCES auth.users(id),

  amount_requested_usd_cents  BIGINT NOT NULL CHECK (amount_requested_usd_cents > 0),

  -- Private — never shown to voters
  request_narrative           TEXT NOT NULL,

  emergency_category          TEXT NOT NULL CHECK (emergency_category IN (
    'medical', 'housing', 'utilities', 'food',
    'transportation', 'funeral', 'disaster', 'other'
  )),

  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft', 'pending_ai_review', 'pending_documents', 'pending_vote',
      'voting', 'approved', 'disbursed', 'denied',
      'revote_requested', 'revote_voting', 'revote_denied',
      'withdrawn', 'voided'
    )),

  current_vote_round          INTEGER NOT NULL DEFAULT 1,
  revote_eligible             BOOLEAN NOT NULL DEFAULT TRUE,

  cooldown_until              TIMESTAMPTZ,

  stripe_payout_id            TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  submitted_at                TIMESTAMPTZ,
  approved_at                 TIMESTAMPTZ,
  disbursed_at                TIMESTAMPTZ,
  denied_at                   TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX requests_user_idx   ON ubi_withdrawal_requests (requester_user_id, status);
CREATE INDEX requests_status_idx ON ubi_withdrawal_requests (status, submitted_at DESC);

ALTER TABLE ubi_withdrawal_requests ENABLE ROW LEVEL SECURITY;

-- Users can read their own requests
CREATE POLICY "ubi_requests_own_read"
  ON ubi_withdrawal_requests FOR SELECT
  USING (requester_user_id = auth.uid());

-- ── Supporting documents ──────────────────────────────────────────────────────
-- Stored in private Supabase Storage bucket 'ubi-documents'.
-- The AI reads them via service role in ubi-ai-evaluate.
-- NO client access: no signed URLs, no paths returned to Flutter. Ever.

CREATE TABLE ubi_request_documents (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id            UUID NOT NULL REFERENCES ubi_withdrawal_requests(id) ON DELETE CASCADE,
  requester_user_id     UUID NOT NULL REFERENCES auth.users(id),

  document_type         TEXT NOT NULL,
  document_label        TEXT NOT NULL,
  storage_path          TEXT NOT NULL,
  file_name             TEXT NOT NULL,
  file_size_bytes       INTEGER NOT NULL,
  mime_type             TEXT NOT NULL CHECK (mime_type IN (
    'application/pdf', 'image/jpeg', 'image/png', 'image/webp'
  )),

  ai_reviewed           BOOLEAN NOT NULL DEFAULT FALSE,
  ai_reviewed_at        TIMESTAMPTZ,

  uploaded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX documents_request_idx ON ubi_request_documents (request_id);

ALTER TABLE ubi_request_documents ENABLE ROW LEVEL SECURITY;

-- No client SELECT policy — documents are AI-only (Hard Rule #2)
-- Service role edge functions manage all document rows
