-- Migration 095: N.O.R.A. Emergency Fund — AI evaluation records.
-- One row per evaluation pass. Internal only — no client SELECT policy.
-- The AI never makes a funding recommendation. It facilitates process only.

CREATE TABLE ubi_ai_evaluations (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id               UUID NOT NULL REFERENCES ubi_withdrawal_requests(id) ON DELETE CASCADE,
  evaluation_pass          INTEGER NOT NULL DEFAULT 1,

  documents_requested      JSONB NOT NULL DEFAULT '[]'::JSONB,
  voter_summary            TEXT,
  internal_assessment      TEXT,

  documents_consistent     BOOLEAN,
  requires_additional_docs JSONB DEFAULT '[]'::JSONB,

  within_fund_scope        BOOLEAN,

  model_used               TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
  input_tokens             INTEGER,
  output_tokens            INTEGER,

  evaluated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (request_id, evaluation_pass)
);

CREATE INDEX evaluations_request_idx ON ubi_ai_evaluations (request_id);

ALTER TABLE ubi_ai_evaluations ENABLE ROW LEVEL SECURITY;

-- No client SELECT — internal audit only (service role edge functions)
