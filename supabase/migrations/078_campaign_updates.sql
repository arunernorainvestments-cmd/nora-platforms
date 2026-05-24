-- ── Campaign Updates + Notification Fan-out ──────────────────────────────────
-- Creators post updates to all backers. Fan-out inserts notifications.
-- Also extends the notifications type check to include campaign types.

-- ─────────────────────────────────────────────────────────────────────────────
-- Extend notifications.type check constraint
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'market_opened',
    'bet_won',
    'bet_lost',
    'market_closing_soon',
    'referral_bonus',
    'token_earned',
    'campaign_proposal',
    'campaign_update',
    'campaign_vote_reminder'
  ));

-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE: campaign_updates
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE campaign_updates (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id               UUID NOT NULL REFERENCES campaigns(id),
  creator_id                UUID NOT NULL REFERENCES auth.users(id),

  title                     TEXT NOT NULL,
  body                      TEXT NOT NULL,
  update_type               TEXT NOT NULL CHECK (update_type IN (
    'milestone', 'progress', 'proposal', 'revenue', 'urgent'
  )),
  linked_proposal_id        UUID REFERENCES campaign_proposals(id),
  linked_revenue_event_id   UUID REFERENCES campaign_revenue_events(id),

  is_simulated              BOOLEAN NOT NULL DEFAULT FALSE,
  published_at              TIMESTAMPTZ,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX updates_campaign_idx ON campaign_updates (campaign_id, published_at DESC);

ALTER TABLE campaign_updates ENABLE ROW LEVEL SECURITY;

-- Public read: all published updates
CREATE POLICY "public read updates"
  ON campaign_updates FOR SELECT
  USING (published_at IS NOT NULL);

-- Creator inserts updates for their own campaigns
CREATE POLICY "creator insert updates"
  ON campaign_updates FOR INSERT
  WITH CHECK (creator_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: campaign_post_update
-- Creator publishes an update; all current backers get a notification.
-- SECURITY DEFINER (postgres superuser) bypasses notification RLS to fan-out.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION campaign_post_update(
  p_campaign_id             UUID,
  p_title                   TEXT,
  p_body                    TEXT,
  p_update_type             TEXT,
  p_linked_proposal_id      UUID DEFAULT NULL,
  p_linked_revenue_event_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign  campaigns%ROWTYPE;
  v_update_id UUID;
  v_backer    RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;

  SELECT * INTO v_campaign FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CAMPAIGN_NOT_FOUND'; END IF;
  IF v_campaign.creator_id != auth.uid() THEN RAISE EXCEPTION 'NOT_CREATOR'; END IF;

  INSERT INTO campaign_updates (
    campaign_id, creator_id, title, body, update_type,
    linked_proposal_id, linked_revenue_event_id,
    is_simulated, published_at
  ) VALUES (
    p_campaign_id, auth.uid(), p_title, p_body, p_update_type,
    p_linked_proposal_id, p_linked_revenue_event_id,
    v_campaign.mode = 'simulated', NOW()
  )
  RETURNING id INTO v_update_id;

  -- Fan-out: notify every unique current backer (excluding creator if also a backer)
  FOR v_backer IN
    SELECT DISTINCT to_user_id AS backer_id
    FROM campaign_ownership_ledger
    WHERE campaign_id = p_campaign_id
      AND to_user_id IS NOT NULL
      AND to_user_id != auth.uid()
  LOOP
    INSERT INTO notifications (user_id, type, title, body, reference_id)
    VALUES (
      v_backer.backer_id,
      'campaign_update',
      p_title,
      LEFT(p_body, 200),
      v_update_id
    );
  END LOOP;

  RETURN v_update_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: campaign_notify_proposal (called after proposal creation)
-- Fans out a campaign_proposal notification to all current backers.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION campaign_notify_proposal(
  p_proposal_id UUID
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_proposal  campaign_proposals%ROWTYPE;
  v_campaign  campaigns%ROWTYPE;
  v_backer    RECORD;
  v_count     INTEGER := 0;
BEGIN
  SELECT * INTO v_proposal FROM campaign_proposals WHERE id = p_proposal_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT * INTO v_campaign FROM campaigns WHERE id = v_proposal.campaign_id;

  FOR v_backer IN
    SELECT DISTINCT to_user_id AS backer_id
    FROM campaign_ownership_ledger
    WHERE campaign_id = v_proposal.campaign_id
      AND to_user_id IS NOT NULL
      AND to_user_id != v_proposal.creator_id
  LOOP
    INSERT INTO notifications (user_id, type, title, body, reference_id)
    VALUES (
      v_backer.backer_id,
      'campaign_proposal',
      'New proposal: ' || v_proposal.title,
      'A governance proposal has been submitted for ' || v_campaign.title
        || '. Voting closes in 72 hours.',
      v_proposal.id
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;
