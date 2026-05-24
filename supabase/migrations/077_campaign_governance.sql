-- ── Campaign Governance: Proposals + Votes ───────────────────────────────────
-- Phase 3. Creators propose spending escrowed capital. Backers vote.
-- Sim: approved proposals auto-execute via process_governance_tick().
-- Live: approved proposals queue a Stripe Connect transfer (edge function).

-- ─────────────────────────────────────────────────────────────────────────────
-- TABLES
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE campaign_proposals (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id                 UUID NOT NULL REFERENCES campaigns(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  title                       TEXT NOT NULL,
  description                 TEXT NOT NULL,
  amount_requested_usd_cents  BIGINT NOT NULL CHECK (amount_requested_usd_cents > 0),
  purpose_category            TEXT NOT NULL CHECK (purpose_category IN (
    'equipment','software','marketing','travel','production',
    'licensing','legal','distribution','other'
  )),
  recipient_description       TEXT NOT NULL,

  status                      TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','approved','rejected','cancelled','executed','expired')),

  -- 72-hour voting window, opens immediately on creation
  voting_opens_at             TIMESTAMPTZ NOT NULL,
  voting_closes_at            TIMESTAMPTZ NOT NULL,

  -- Denormalized tallies updated on each vote (royalty_pct weighted)
  total_royalty_pct_voted     DECIMAL(10,6) NOT NULL DEFAULT 0,
  royalty_pct_approved        DECIMAL(10,6) NOT NULL DEFAULT 0,
  royalty_pct_rejected        DECIMAL(10,6) NOT NULL DEFAULT 0,
  -- 25% of campaign royalty_pct_offered must vote for result to be binding
  quorum_pct_required         DECIMAL(10,6) NOT NULL DEFAULT 25.000000,

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  executed_at                 TIMESTAMPTZ,
  stripe_transfer_id          TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT voting_window_order CHECK (voting_closes_at > voting_opens_at)
);

CREATE INDEX proposals_campaign_idx ON campaign_proposals (campaign_id, status);
CREATE INDEX proposals_creator_idx  ON campaign_proposals (creator_id, created_at);

-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE campaign_votes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id       UUID NOT NULL REFERENCES campaign_proposals(id),
  voter_user_id     UUID NOT NULL REFERENCES auth.users(id),

  vote              TEXT NOT NULL CHECK (vote IN ('yes','no','abstain')),
  -- Snapshot of net royalty stake at vote time (prevents post-proposal gaming)
  royalty_pct_weight DECIMAL(10,6) NOT NULL,

  voted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (proposal_id, voter_user_id)
);

CREATE INDEX votes_proposal_idx ON campaign_votes (proposal_id);
CREATE INDEX votes_voter_idx    ON campaign_votes (voter_user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE campaign_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_votes     ENABLE ROW LEVEL SECURITY;

-- Proposals: public read (all non-cancelled statuses visible to everyone)
CREATE POLICY "public read proposals"
  ON campaign_proposals FOR SELECT
  USING (status != 'cancelled' OR creator_id = auth.uid());

-- Creator inserts for their own campaigns
CREATE POLICY "creator insert proposals"
  ON campaign_proposals FOR INSERT
  WITH CHECK (creator_id = auth.uid());

-- Creator can cancel their own open proposals only
CREATE POLICY "creator cancel proposals"
  ON campaign_proposals FOR UPDATE
  USING (creator_id = auth.uid() AND status = 'open')
  WITH CHECK (status = 'cancelled');

-- Votes: each user reads only their own votes
CREATE POLICY "read own votes"
  ON campaign_votes FOR SELECT
  USING (voter_user_id = auth.uid());

-- Backers insert their own votes
CREATE POLICY "backer cast vote"
  ON campaign_votes FOR INSERT
  WITH CHECK (voter_user_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: campaign_create_proposal
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION campaign_create_proposal(
  p_campaign_id                UUID,
  p_title                      TEXT,
  p_description                TEXT,
  p_amount_requested_usd_cents BIGINT,
  p_purpose_category           TEXT,
  p_recipient_description      TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign      campaigns%ROWTYPE;
  v_proposal_id   UUID;
  v_max_amount    BIGINT;
  v_last_rejected TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT * INTO v_campaign FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND'; END IF;
  IF v_campaign.creator_id != auth.uid() THEN RAISE EXCEPTION 'NOT_CREATOR'; END IF;

  -- Campaign must be funded or active for proposals
  IF v_campaign.status NOT IN ('funded', 'active') THEN
    RAISE EXCEPTION 'CAMPAIGN_NOT_ELIGIBLE';
  END IF;

  -- Max 20% of escrow per proposal
  v_max_amount := FLOOR(v_campaign.escrow_balance_usd_cents::NUMERIC * 0.20);
  IF p_amount_requested_usd_cents > v_max_amount THEN
    RAISE EXCEPTION 'EXCEEDS_ESCROW_CAP';
  END IF;

  -- 30-day cooling period after any rejection
  SELECT MAX(created_at) INTO v_last_rejected
  FROM campaign_proposals
  WHERE campaign_id = p_campaign_id
    AND creator_id  = auth.uid()
    AND status      = 'rejected'
    AND created_at  > NOW() - INTERVAL '30 days';

  IF v_last_rejected IS NOT NULL THEN
    RAISE EXCEPTION 'COOLING_PERIOD_ACTIVE';
  END IF;

  INSERT INTO campaign_proposals (
    campaign_id, creator_id,
    title, description, amount_requested_usd_cents, purpose_category, recipient_description,
    voting_opens_at, voting_closes_at,
    is_simulated
  ) VALUES (
    p_campaign_id, auth.uid(),
    p_title, p_description, p_amount_requested_usd_cents, p_purpose_category, p_recipient_description,
    NOW(), NOW() + INTERVAL '72 hours',
    v_campaign.mode = 'simulated'
  )
  RETURNING id INTO v_proposal_id;

  RETURN v_proposal_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: campaign_cast_vote
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION campaign_cast_vote(
  p_proposal_id UUID,
  p_vote        TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_proposal       campaign_proposals%ROWTYPE;
  v_royalty_weight DECIMAL(10,6);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF p_vote NOT IN ('yes','no','abstain') THEN RAISE EXCEPTION 'INVALID_VOTE'; END IF;

  SELECT * INTO v_proposal FROM campaign_proposals WHERE id = p_proposal_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPOSAL_NOT_FOUND'; END IF;
  IF v_proposal.status != 'open' THEN RAISE EXCEPTION 'PROPOSAL_NOT_OPEN'; END IF;
  IF NOW() NOT BETWEEN v_proposal.voting_opens_at AND v_proposal.voting_closes_at THEN
    RAISE EXCEPTION 'OUTSIDE_VOTING_WINDOW';
  END IF;

  -- Duplicate vote check
  IF EXISTS (
    SELECT 1 FROM campaign_votes
    WHERE proposal_id = p_proposal_id AND voter_user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'ALREADY_VOTED';
  END IF;

  -- Net royalty stake: sum of inbound ledger rows minus outbound rows
  SELECT COALESCE(SUM(
    CASE WHEN to_user_id   = auth.uid() THEN  royalty_pct
         WHEN from_user_id = auth.uid() THEN -royalty_pct
         ELSE 0 END
  ), 0)
  INTO v_royalty_weight
  FROM campaign_ownership_ledger
  WHERE campaign_id = v_proposal.campaign_id
    AND (to_user_id = auth.uid() OR from_user_id = auth.uid());

  IF v_royalty_weight <= 0 THEN RAISE EXCEPTION 'NOT_A_BACKER'; END IF;

  -- Insert vote
  INSERT INTO campaign_votes (proposal_id, voter_user_id, vote, royalty_pct_weight)
  VALUES (p_proposal_id, auth.uid(), p_vote, v_royalty_weight);

  -- Update denormalized tallies
  UPDATE campaign_proposals SET
    total_royalty_pct_voted = total_royalty_pct_voted + v_royalty_weight,
    royalty_pct_approved    = royalty_pct_approved
                            + CASE WHEN p_vote = 'yes' THEN v_royalty_weight ELSE 0 END,
    royalty_pct_rejected    = royalty_pct_rejected
                            + CASE WHEN p_vote = 'no'  THEN v_royalty_weight ELSE 0 END
  WHERE id = p_proposal_id;

  RETURN 'OK';
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: process_governance_tick
-- Called every minute by pg_cron.
-- Closes expired voting windows, tallies results, auto-executes approved sim proposals.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION process_governance_tick()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_proposal  campaign_proposals%ROWTYPE;
  v_campaign  campaigns%ROWTYPE;
  v_outcome   TEXT;
  v_count     INTEGER := 0;
BEGIN
  FOR v_proposal IN
    SELECT * FROM campaign_proposals
    WHERE status = 'open' AND voting_closes_at <= NOW()
    FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_campaign FROM campaigns WHERE id = v_proposal.campaign_id;

    -- Quorum: total_royalty_pct_voted >= quorum_pct_required% of royalty_pct_offered
    IF v_proposal.total_royalty_pct_voted >=
       (v_campaign.royalty_pct_offered * v_proposal.quorum_pct_required / 100.0) THEN
      -- Quorum met — simple majority decides
      IF v_proposal.royalty_pct_approved > v_proposal.royalty_pct_rejected THEN
        v_outcome := 'approved';
      ELSE
        v_outcome := 'rejected';
      END IF;
    ELSE
      v_outcome := 'expired'; -- quorum not reached
    END IF;

    UPDATE campaign_proposals SET status = v_outcome WHERE id = v_proposal.id;

    -- Auto-execute approved simulated proposals immediately
    IF v_outcome = 'approved' AND v_campaign.mode = 'simulated' THEN
      -- Deduct from campaign escrow (guard against double-spend)
      UPDATE campaigns SET
        escrow_balance_usd_cents =
          escrow_balance_usd_cents - v_proposal.amount_requested_usd_cents
      WHERE id = v_campaign.id
        AND escrow_balance_usd_cents >= v_proposal.amount_requested_usd_cents;

      IF FOUND THEN
        -- Credit creator sim balance
        INSERT INTO sim_usd_balances (user_id, balance_usd_cents)
        VALUES (v_campaign.creator_id, v_proposal.amount_requested_usd_cents)
        ON CONFLICT (user_id) DO UPDATE SET
          balance_usd_cents = sim_usd_balances.balance_usd_cents
                            + v_proposal.amount_requested_usd_cents,
          updated_at        = NOW();

        INSERT INTO sim_usd_transactions (
          user_id, type, amount_usd_cents, reference_id, description
        ) VALUES (
          v_campaign.creator_id,
          'governance_release',
          v_proposal.amount_requested_usd_cents,
          v_proposal.id,
          'Governance proposal approved: ' || v_proposal.title
        );

        UPDATE campaign_proposals SET
          status      = 'executed',
          executed_at = NOW()
        WHERE id = v_proposal.id;
      END IF;
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- pg_cron: run governance tick every minute
-- ─────────────────────────────────────────────────────────────────────────────

SELECT cron.schedule(
  'governance-tick',
  '* * * * *',
  'SELECT public.process_governance_tick()'
);
