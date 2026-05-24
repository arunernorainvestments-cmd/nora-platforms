-- Migration 076: Campaign revenue events + distributions.
-- Revenue verification is layered: creator_upload (MVP) → csv_export →
-- api_pull → data_partnership → oracle (on-chain, post NORA coin launch).
-- Distributions use identical math for sim and live; only the payment rail
-- differs. Flipping campaign.mode = 'live' requires no code change.

-- ─────────────────────────────────────────────────────────────────────────────
-- campaign_revenue_events
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.campaign_revenue_events (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id             UUID NOT NULL REFERENCES public.campaigns(id),

  source                  TEXT NOT NULL CHECK (source IN (
    'spotify','youtube','apple_music','amazon_music','tidal',
    'soundcloud','bandcamp','twitch','distrokid','tunecore',
    'manual','other'
  )),

  period_start            DATE NOT NULL,
  period_end              DATE NOT NULL,

  -- Revenue breakdown (all in USD cents)
  gross_revenue_usd_cents BIGINT NOT NULL DEFAULT 0,
  platform_fee_usd_cents  BIGINT NOT NULL DEFAULT 0, -- streaming platform's cut
  net_revenue_usd_cents   BIGINT NOT NULL DEFAULT 0, -- NORA distributes this

  -- Display metrics
  stream_count            BIGINT DEFAULT 0,
  view_count              BIGINT DEFAULT 0,
  download_count          BIGINT DEFAULT 0,

  -- Verification
  evidence_type           TEXT NOT NULL DEFAULT 'creator_upload'
    CHECK (evidence_type IN (
      'creator_upload','csv_export','api_pull','data_partnership','oracle'
    )),
  evidence_url            TEXT,
  verification_status     TEXT NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending','verified','disputed','rejected')),
  verified_by_user_id     UUID REFERENCES auth.users(id),
  verified_at             TIMESTAMPTZ,
  dispute_reason          TEXT,
  is_simulated            BOOLEAN NOT NULL DEFAULT FALSE,

  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT period_order CHECK (period_end >= period_start)
);

CREATE INDEX revenue_events_campaign_idx ON public.campaign_revenue_events (campaign_id, period_start);
CREATE INDEX revenue_events_status_idx   ON public.campaign_revenue_events (verification_status);

-- ─────────────────────────────────────────────────────────────────────────────
-- campaign_distributions
-- One row per backer per revenue event. Created when event is verified.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.campaign_distributions (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  revenue_event_id        UUID NOT NULL REFERENCES public.campaign_revenue_events(id),
  campaign_id             UUID NOT NULL REFERENCES public.campaigns(id),
  backer_user_id          UUID NOT NULL REFERENCES auth.users(id),

  -- Ownership snapshot at distribution time (never recalculated after creation)
  royalty_pct_at_time     DECIMAL(10,6) NOT NULL,

  gross_usd_cents         BIGINT NOT NULL,
  platform_fee_usd_cents  BIGINT NOT NULL DEFAULT 0,
  net_usd_cents           BIGINT NOT NULL,

  status                  TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','processing','completed','failed','unclaimed')),

  -- Live mode: populated when Stripe transfer fires
  stripe_transfer_id      TEXT,
  -- Live mode: backer's Stripe Connect account for payouts (populated at Phase 5)
  backer_stripe_account_id TEXT,

  is_simulated            BOOLEAN NOT NULL DEFAULT FALSE,
  distributed_at          TIMESTAMPTZ,
  failed_reason           TEXT,

  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (revenue_event_id, backer_user_id)
);

CREATE INDEX distributions_backer_idx  ON public.campaign_distributions (backer_user_id, status);
CREATE INDEX distributions_event_idx   ON public.campaign_distributions (revenue_event_id);
CREATE INDEX distributions_campaign_idx ON public.campaign_distributions (campaign_id, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.campaign_revenue_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_distributions ENABLE ROW LEVEL SECURITY;

-- Revenue events: public read for verified events on public campaigns.
CREATE POLICY "revenue_events_public_read" ON public.campaign_revenue_events
  FOR SELECT USING (
    verification_status = 'verified'
    AND EXISTS (
      SELECT 1 FROM public.campaigns c
      WHERE c.id = campaign_id
        AND c.status IN ('open','funded','active','closed')
    )
  );

-- Creator can read all events for their own campaigns.
CREATE POLICY "revenue_events_creator_read" ON public.campaign_revenue_events
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.campaigns c
      WHERE c.id = campaign_id AND c.creator_id = auth.uid()
    )
  );

-- Creator can insert revenue events for their own active/funded campaigns.
CREATE POLICY "revenue_events_creator_insert" ON public.campaign_revenue_events
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.campaigns c
      WHERE c.id = campaign_id
        AND c.creator_id = auth.uid()
        AND c.status IN ('funded','active')
    )
  );

-- Backers can read their own distributions.
CREATE POLICY "distributions_backer_read" ON public.campaign_distributions
  FOR SELECT USING (auth.uid() = backer_user_id);

-- Creators can read all distributions for their campaigns.
CREATE POLICY "distributions_creator_read" ON public.campaign_distributions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.campaigns c
      WHERE c.id = campaign_id AND c.creator_id = auth.uid()
    )
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- process_campaign_distributions(p_event_id)
--
-- Called after a revenue event is marked 'verified'.
-- Identical calculation for sim and live — only payment rail differs:
--   sim  → credits sim_usd_balances immediately, marks completed
--   live → creates queued rows for Stripe Connect processing by edge function
--
-- Returns the number of distribution rows created.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.process_campaign_distributions(p_event_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event     RECORD;
  v_campaign  RECORD;
  v_backer    RECORD;
  v_count     INT := 0;

  v_backer_royalty_pct    DECIMAL(10,6);
  v_gross_cents           BIGINT;
  v_platform_fee_cents    BIGINT;
  v_net_cents             BIGINT;
BEGIN
  -- Load and validate event
  SELECT * INTO v_event
  FROM public.campaign_revenue_events
  WHERE id = p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Revenue event not found: %', p_event_id;
  END IF;
  IF v_event.verification_status != 'verified' THEN
    RAISE EXCEPTION 'Revenue event must be verified before distributions can be processed';
  END IF;

  -- Check distributions haven't already been created for this event
  IF EXISTS (
    SELECT 1 FROM public.campaign_distributions WHERE revenue_event_id = p_event_id
  ) THEN
    RAISE EXCEPTION 'Distributions already created for event %', p_event_id;
  END IF;

  -- Load campaign (for fee snapshot and mode)
  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = v_event.campaign_id;

  IF v_campaign.net_revenue_usd_cents IS NOT NULL THEN NULL; END IF; -- silence unused warning

  -- Iterate backers: each distinct to_user_id in the ownership ledger
  FOR v_backer IN
    SELECT
      to_user_id,
      SUM(royalty_pct) AS total_royalty_pct
    FROM public.campaign_ownership_ledger
    WHERE campaign_id = v_event.campaign_id
      AND event_type IN ('purchase','secondary_sale')
      AND to_user_id IS NOT NULL
    GROUP BY to_user_id
  LOOP
    v_backer_royalty_pct := v_backer.total_royalty_pct;

    -- Gross = net_revenue × (backer_royalty_pct / 100)
    v_gross_cents := FLOOR(v_event.net_revenue_usd_cents
                           * v_backer_royalty_pct / 100.0)::BIGINT;

    -- Platform distribution fee (snapshotted on campaign at creation)
    v_platform_fee_cents := FLOOR(v_gross_cents
                                  * v_campaign.platform_distribution_fee_pct)::BIGINT;

    v_net_cents := v_gross_cents - v_platform_fee_cents;

    -- Skip zero distributions (rounding edge case)
    IF v_net_cents <= 0 THEN CONTINUE; END IF;

    -- Create distribution row
    INSERT INTO public.campaign_distributions (
      revenue_event_id,
      campaign_id,
      backer_user_id,
      royalty_pct_at_time,
      gross_usd_cents,
      platform_fee_usd_cents,
      net_usd_cents,
      status,
      is_simulated
    ) VALUES (
      p_event_id,
      v_event.campaign_id,
      v_backer.to_user_id,
      v_backer_royalty_pct,
      v_gross_cents,
      v_platform_fee_cents,
      v_net_cents,
      'queued',
      v_event.is_simulated
    );

    -- Sim mode: pay out immediately via sim_usd_balances
    IF v_campaign.mode = 'simulated' THEN
      PERFORM public.sim_seed_balance(v_backer.to_user_id);

      UPDATE public.sim_usd_balances
      SET balance_usd_cents       = balance_usd_cents + v_net_cents,
          lifetime_returned_cents = lifetime_returned_cents + v_net_cents,
          updated_at              = NOW()
      WHERE user_id = v_backer.to_user_id;

      INSERT INTO public.sim_usd_transactions (
        user_id, type, amount_usd_cents, reference_id, description
      ) VALUES (
        v_backer.to_user_id,
        'distribution',
        v_net_cents,
        v_event.campaign_id,
        'Royalty distribution: ' || v_campaign.title
      );

      -- Mark completed immediately for sim
      UPDATE public.campaign_distributions
      SET status         = 'completed',
          distributed_at = NOW()
      WHERE revenue_event_id = p_event_id
        AND backer_user_id   = v_backer.to_user_id;
    END IF;

    -- Live mode: row stays 'queued' — picked up by campaign-process-revenue
    -- edge function which fires Stripe Connect transfers.

    v_count := v_count + 1;
  END LOOP;

  -- Transition campaign to 'active' if it was 'funded' and this is the first event
  IF v_campaign.status = 'funded' THEN
    UPDATE public.campaigns
    SET status = 'active'
    WHERE id = v_event.campaign_id;
  END IF;

  RETURN v_count;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- campaign_submit_revenue_event(...)
-- Creator-callable RPC. Creates a revenue event for their campaign.
-- In sim mode: auto-verifies and immediately triggers distribution.
-- In live mode: creates a 'pending' event for admin review.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.campaign_submit_revenue_event(
  p_campaign_id             UUID,
  p_source                  TEXT,
  p_period_start            DATE,
  p_period_end              DATE,
  p_gross_revenue_usd_cents BIGINT,
  p_platform_fee_usd_cents  BIGINT,
  p_net_revenue_usd_cents   BIGINT,
  p_stream_count            BIGINT DEFAULT 0,
  p_view_count              BIGINT DEFAULT 0,
  p_evidence_url            TEXT   DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_campaign  RECORD;
  v_event_id  UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Validate caller is the campaign creator
  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = p_campaign_id AND creator_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign not found or not owned by you';
  END IF;
  IF v_campaign.status NOT IN ('funded', 'active') THEN
    RAISE EXCEPTION 'Campaign must be funded or active to submit revenue (status: %)',
      v_campaign.status;
  END IF;
  IF p_net_revenue_usd_cents <= 0 THEN
    RAISE EXCEPTION 'net_revenue_usd_cents must be positive';
  END IF;

  -- Insert event
  INSERT INTO public.campaign_revenue_events (
    campaign_id,
    source,
    period_start,
    period_end,
    gross_revenue_usd_cents,
    platform_fee_usd_cents,
    net_revenue_usd_cents,
    stream_count,
    view_count,
    evidence_url,
    evidence_type,
    verification_status,
    verified_at,
    is_simulated
  ) VALUES (
    p_campaign_id,
    p_source,
    p_period_start,
    p_period_end,
    p_gross_revenue_usd_cents,
    p_platform_fee_usd_cents,
    p_net_revenue_usd_cents,
    p_stream_count,
    p_view_count,
    p_evidence_url,
    'creator_upload',
    CASE WHEN v_campaign.mode = 'simulated' THEN 'verified' ELSE 'pending' END,
    CASE WHEN v_campaign.mode = 'simulated' THEN NOW() ELSE NULL END,
    v_campaign.mode = 'simulated'
  )
  RETURNING id INTO v_event_id;

  -- Sim mode: immediately process distributions
  IF v_campaign.mode = 'simulated' THEN
    PERFORM public.process_campaign_distributions(v_event_id);
  END IF;

  RETURN v_event_id;
END;
$$;
