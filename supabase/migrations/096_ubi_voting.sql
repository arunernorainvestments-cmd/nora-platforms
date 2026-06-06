-- Migration 096: N.O.R.A. Emergency Fund — Voting panels, assignments, votes, cast-vote RPC.
-- Individual vote values are permanently private (Hard Rule #3):
--   - No index on ubi_panel_votes.vote
--   - No client SELECT policy on ubi_panel_votes
--   - Running totals hidden until panel closes

-- ── Voting panels ─────────────────────────────────────────────────────────────

CREATE TABLE ubi_voting_panels (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id       UUID NOT NULL REFERENCES ubi_withdrawal_requests(id),
  vote_round       INTEGER NOT NULL DEFAULT 1,
  panel_size       INTEGER NOT NULL,

  status           TEXT NOT NULL DEFAULT 'assembling'
    CHECK (status IN ('assembling', 'open', 'closed', 'timed_out')),

  -- Running totals — hidden from voters until closed (enforced via RLS)
  votes_yes        INTEGER NOT NULL DEFAULT 0,
  votes_no         INTEGER NOT NULL DEFAULT 0,
  votes_received   INTEGER NOT NULL DEFAULT 0,

  outcome          TEXT CHECK (outcome IN ('approved', 'denied', 'inconclusive')),

  opened_at        TIMESTAMPTZ,
  closes_at        TIMESTAMPTZ,
  extended_until   TIMESTAMPTZ,
  closed_at        TIMESTAMPTZ,

  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (request_id, vote_round)
);

ALTER TABLE ubi_voting_panels ENABLE ROW LEVEL SECURITY;

-- Requesters can see their own panel status
CREATE POLICY "ubi_panels_requester_read"
  ON ubi_voting_panels FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM ubi_withdrawal_requests r
      WHERE r.id = ubi_voting_panels.request_id
        AND r.requester_user_id = auth.uid()
    )
  );

-- ubi_panels_member_read added after ubi_panel_assignments is created below.

-- ── Panel assignments ─────────────────────────────────────────────────────────

CREATE TABLE ubi_panel_assignments (
  id                               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  panel_id                         UUID NOT NULL REFERENCES ubi_voting_panels(id) ON DELETE CASCADE,
  request_id                       UUID NOT NULL REFERENCES ubi_withdrawal_requests(id),
  voter_user_id                    UUID NOT NULL REFERENCES auth.users(id),

  assignment_status                TEXT NOT NULL DEFAULT 'pending'
    CHECK (assignment_status IN (
      'pending', 'opened', 'voted', 'inactive', 'replaced'
    )),

  replaced_by_assignment_id        UUID REFERENCES ubi_panel_assignments(id),
  is_replacement                   BOOLEAN NOT NULL DEFAULT FALSE,
  replaced_inactive_assignment_id  UUID REFERENCES ubi_panel_assignments(id),

  notified_at                      TIMESTAMPTZ,
  opened_at                        TIMESTAMPTZ,
  voted_at                         TIMESTAMPTZ,
  personal_deadline                TIMESTAMPTZ,

  created_at                       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (panel_id, voter_user_id)
);

CREATE INDEX assignments_panel_idx    ON ubi_panel_assignments (panel_id, assignment_status);
CREATE INDEX assignments_voter_idx    ON ubi_panel_assignments (voter_user_id, assignment_status);
CREATE INDEX assignments_inactive_idx ON ubi_panel_assignments (personal_deadline, assignment_status)
  WHERE assignment_status IN ('pending', 'opened');

ALTER TABLE ubi_panel_assignments ENABLE ROW LEVEL SECURITY;

-- Voters can read their own assignments
CREATE POLICY "ubi_assignments_own_read"
  ON ubi_panel_assignments FOR SELECT
  USING (voter_user_id = auth.uid());

-- Panel members can see panel metadata (added here after ubi_panel_assignments exists)
CREATE POLICY "ubi_panels_member_read"
  ON ubi_voting_panels FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM ubi_panel_assignments a
      WHERE a.panel_id = ubi_voting_panels.id
        AND a.voter_user_id = auth.uid()
    )
  );

-- ── Panel votes ───────────────────────────────────────────────────────────────
-- Individual votes are permanently private. No client SELECT policy.
-- No index on vote column — values must never be queryable by clients.

CREATE TABLE ubi_panel_votes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id   UUID NOT NULL UNIQUE REFERENCES ubi_panel_assignments(id),
  panel_id        UUID NOT NULL REFERENCES ubi_voting_panels(id),
  voter_user_id   UUID NOT NULL REFERENCES auth.users(id),

  vote            TEXT NOT NULL CHECK (vote IN ('yes', 'no')),

  voted_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX votes_panel_idx ON ubi_panel_votes (panel_id);
-- No index on vote column (Hard Rule #3)

ALTER TABLE ubi_panel_votes ENABLE ROW LEVEL SECURITY;
-- No client SELECT policy — vote values are permanently private

-- ── ubi_cast_vote RPC ─────────────────────────────────────────────────────────
-- SECURITY DEFINER — runs as postgres, bypasses RLS for internal state updates.
-- Individual vote values are never surfaced outside this function.

CREATE OR REPLACE FUNCTION ubi_cast_vote(
  p_assignment_id UUID,
  p_vote          TEXT
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_assignment  ubi_panel_assignments%ROWTYPE;
  v_panel       ubi_voting_panels%ROWTYPE;
BEGIN
  IF p_vote NOT IN ('yes', 'no') THEN
    RAISE EXCEPTION 'Invalid vote value: %', p_vote;
  END IF;

  SELECT * INTO v_assignment
  FROM ubi_panel_assignments
  WHERE id = p_assignment_id AND voter_user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignment not found or not yours';
  END IF;
  IF v_assignment.assignment_status NOT IN ('pending', 'opened') THEN
    RAISE EXCEPTION 'Assignment is not in a voteable state: %', v_assignment.assignment_status;
  END IF;

  SELECT * INTO v_panel
  FROM ubi_voting_panels
  WHERE id = v_assignment.panel_id AND status = 'open';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Panel is not open for voting';
  END IF;
  IF v_panel.closes_at < NOW()
    AND (v_panel.extended_until IS NULL OR v_panel.extended_until < NOW())
  THEN
    RAISE EXCEPTION 'Voting window has closed';
  END IF;

  INSERT INTO ubi_panel_votes (
    assignment_id, panel_id, voter_user_id, vote
  ) VALUES (
    p_assignment_id, v_assignment.panel_id, auth.uid(), p_vote
  );

  UPDATE ubi_panel_assignments
  SET assignment_status = 'voted', voted_at = NOW()
  WHERE id = p_assignment_id;

  -- Update running totals (hidden from voters until panel closes via application layer)
  UPDATE ubi_voting_panels
  SET
    votes_yes      = votes_yes + CASE p_vote WHEN 'yes' THEN 1 ELSE 0 END,
    votes_no       = votes_no  + CASE p_vote WHEN 'no'  THEN 1 ELSE 0 END,
    votes_received = votes_received + 1
  WHERE id = v_assignment.panel_id;

  -- Mark assignment as opened if still pending (voter submitted without opening)
  UPDATE ubi_panel_assignments
  SET opened_at = COALESCE(opened_at, NOW())
  WHERE id = p_assignment_id;
END;
$$;

GRANT EXECUTE ON FUNCTION ubi_cast_vote(UUID, TEXT) TO authenticated;
