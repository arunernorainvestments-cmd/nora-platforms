-- Migration 074: Campaigns + ownership ledger + investment RPCs.
-- Fee rates snapshotted at campaign creation so future rate changes don't
-- affect existing campaigns.
-- All monetary values in integer USD cents. Percentages as DECIMAL(10,6).
-- Ownership ledger is append-only — never UPDATE, only INSERT.

-- ─────────────────────────────────────────────────────────────────────────────
-- campaigns
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.campaigns (
  id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id                      UUID NOT NULL REFERENCES auth.users(id),

  -- Identity
  title                           TEXT NOT NULL,
  description                     TEXT,
  category                        TEXT NOT NULL CHECK (category IN (
    'album','ep','single','film','documentary','podcast',
    'software','game','tour','merchandise','other'
  )),
  cover_image_url                 TEXT,

  -- The offer
  funding_goal_usd_cents          BIGINT NOT NULL CHECK (funding_goal_usd_cents > 0),
  current_funding_usd_cents       BIGINT NOT NULL DEFAULT 0,
  royalty_pct_offered             DECIMAL(10,6) NOT NULL
    CHECK (royalty_pct_offered > 0 AND royalty_pct_offered <= 100),
  royalty_term_years              SMALLINT DEFAULT NULL, -- NULL = perpetual
  min_investment_usd_cents        BIGINT NOT NULL DEFAULT 1000, -- $10 minimum

  -- Lifecycle
  mode                            TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated','live')),
  status                          TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft',
      'pending',
      'open',
      'funded',
      'active',
      'failed',
      'closed'
    )),
  opens_at                        TIMESTAMPTZ,
  closes_at                       TIMESTAMPTZ,

  -- Revenue source anchors
  spotify_album_id                TEXT,
  spotify_artist_id               TEXT,
  youtube_channel_id              TEXT,
  youtube_video_id                TEXT,
  apple_music_album_id            TEXT,
  distrokid_release_id            TEXT,
  tunecore_release_id             TEXT,

  -- Escrow (live mode only)
  escrow_stripe_account_id        TEXT,
  escrow_balance_usd_cents        BIGINT NOT NULL DEFAULT 0,

  -- Reg CF compliance
  sec_form_c_filing_id            TEXT,
  sec_filing_date                 DATE,

  -- On-chain migration (future)
  onchain_contract_address        TEXT DEFAULT NULL,
  onchain_token_symbol            TEXT DEFAULT NULL,

  -- Platform fees snapshotted at creation time
  platform_success_fee_pct        DECIMAL(5,4) NOT NULL DEFAULT 0.0300,      -- 3%
  platform_distribution_fee_pct   DECIMAL(5,4) NOT NULL DEFAULT 0.0150,      -- 1.5%
  platform_secondary_fee_pct      DECIMAL(5,4) NOT NULL DEFAULT 0.0050,      -- 0.5% per side

  created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  funded_at                       TIMESTAMPTZ,
  closed_at                       TIMESTAMPTZ,

  CONSTRAINT closes_after_opens CHECK (closes_at IS NULL OR opens_at IS NULL OR closes_at > opens_at),
  CONSTRAINT royalty_term_positive CHECK (royalty_term_years IS NULL OR royalty_term_years > 0)
);

CREATE INDEX campaigns_creator_idx ON public.campaigns (creator_id, status);
CREATE INDEX campaigns_status_idx  ON public.campaigns (status, closes_at);
CREATE INDEX campaigns_mode_idx    ON public.campaigns (mode, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- campaign_ownership_ledger (immutable — never UPDATE, only INSERT)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.campaign_ownership_ledger (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  campaign_id               UUID NOT NULL REFERENCES public.campaigns(id),
  -- NULL from_user_id = initial mint (new investment)
  -- NULL to_user_id   = burn (future: creator buyback)
  from_user_id              UUID REFERENCES auth.users(id),
  to_user_id                UUID REFERENCES auth.users(id),

  royalty_pct               DECIMAL(10,6) NOT NULL CHECK (royalty_pct > 0),
  usd_cents_paid            BIGINT NOT NULL DEFAULT 0,

  event_type                TEXT NOT NULL CHECK (event_type IN (
    'purchase',
    'secondary_sale',
    'inheritance',
    'platform_correction'
  )),

  stripe_payment_intent_id  TEXT,
  is_simulated              BOOLEAN NOT NULL DEFAULT FALSE,

  notes                     TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ownership_ledger_campaign_idx   ON public.campaign_ownership_ledger (campaign_id, created_at);
CREATE INDEX ownership_ledger_to_user_idx    ON public.campaign_ownership_ledger (to_user_id, campaign_id);
CREATE INDEX ownership_ledger_from_user_idx  ON public.campaign_ownership_ledger (from_user_id, campaign_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_ownership_ledger ENABLE ROW LEVEL SECURITY;

-- Public can read open/funded/active/failed/closed campaigns.
CREATE POLICY "campaigns_public_read" ON public.campaigns
  FOR SELECT USING (status IN ('open','funded','active','failed','closed'));

-- Creator can read their own campaigns at any status.
CREATE POLICY "campaigns_creator_read_own" ON public.campaigns
  FOR SELECT USING (auth.uid() = creator_id);

-- Creator can insert new campaigns (always start as draft/simulated).
CREATE POLICY "campaigns_creator_insert" ON public.campaigns
  FOR INSERT WITH CHECK (
    auth.uid() = creator_id
    AND status = 'draft'
    AND mode = 'simulated'
  );

-- Creator can update their own draft campaigns only.
CREATE POLICY "campaigns_creator_update_draft" ON public.campaigns
  FOR UPDATE USING (auth.uid() = creator_id AND status = 'draft');

-- Ownership ledger: backers can see rows where they are buyer or seller.
CREATE POLICY "ledger_select_participant" ON public.campaign_ownership_ledger
  FOR SELECT USING (
    auth.uid() = to_user_id OR auth.uid() = from_user_id
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- campaign_invest_simulated(p_campaign_id, p_royalty_pct, p_usd_cents)
-- Atomic simulated investment:
--   1. KYC gate: user must have approved KYC (or simulate-approve first)
--   2. Deduct from sim_usd_balances
--   3. Mint ownership_ledger row
--   4. Increment campaigns.current_funding_usd_cents
-- Returns the new ledger row id.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.campaign_invest_simulated(
  p_campaign_id   UUID,
  p_royalty_pct   DECIMAL(10,6),
  p_usd_cents     BIGINT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id       UUID := auth.uid();
  v_campaign      RECORD;
  v_balance       BIGINT;
  v_ledger_id     UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- KYC gate
  IF NOT EXISTS (
    SELECT 1 FROM public.kyc_verifications
    WHERE user_id = v_user_id AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'KYC_REQUIRED';
  END IF;

  -- Lock and validate campaign
  SELECT * INTO v_campaign
  FROM public.campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign not found';
  END IF;
  IF v_campaign.status != 'open' THEN
    RAISE EXCEPTION 'Campaign is not open for investment (status: %)', v_campaign.status;
  END IF;
  IF v_campaign.mode != 'simulated' THEN
    RAISE EXCEPTION 'Use the live investment flow for non-simulated campaigns';
  END IF;
  IF p_usd_cents < v_campaign.min_investment_usd_cents THEN
    RAISE EXCEPTION 'Minimum investment is % cents', v_campaign.min_investment_usd_cents;
  END IF;
  IF p_royalty_pct <= 0 THEN
    RAISE EXCEPTION 'royalty_pct must be positive';
  END IF;

  -- Validate royalty_pct doesn't exceed what's still available
  -- (sum of existing purchases vs. total offered)
  IF (
    SELECT COALESCE(SUM(royalty_pct), 0)
    FROM public.campaign_ownership_ledger
    WHERE campaign_id = p_campaign_id
      AND from_user_id IS NULL
      AND event_type = 'purchase'
  ) + p_royalty_pct > v_campaign.royalty_pct_offered THEN
    RAISE EXCEPTION 'Royalty stake requested exceeds remaining available percentage';
  END IF;

  -- Seed sim balance if user has none, then check funds
  PERFORM public.sim_seed_balance(v_user_id);

  SELECT balance_usd_cents INTO v_balance
  FROM public.sim_usd_balances
  WHERE user_id = v_user_id
  FOR UPDATE;

  IF v_balance < p_usd_cents THEN
    RAISE EXCEPTION 'INSUFFICIENT_SIM_BALANCE';
  END IF;

  -- Deduct sim balance
  UPDATE public.sim_usd_balances
  SET balance_usd_cents       = balance_usd_cents - p_usd_cents,
      lifetime_invested_cents = lifetime_invested_cents + p_usd_cents,
      updated_at              = NOW()
  WHERE user_id = v_user_id;

  -- Log sim transaction
  INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, reference_id, description)
  VALUES (v_user_id, 'investment', -p_usd_cents, p_campaign_id,
          'Simulated investment: ' || v_campaign.title);

  -- Mint ownership ledger row
  INSERT INTO public.campaign_ownership_ledger (
    campaign_id, from_user_id, to_user_id, royalty_pct, usd_cents_paid,
    event_type, is_simulated
  )
  VALUES (
    p_campaign_id, NULL, v_user_id, p_royalty_pct, p_usd_cents,
    'purchase', TRUE
  )
  RETURNING id INTO v_ledger_id;

  -- Update campaign funding total
  UPDATE public.campaigns
  SET current_funding_usd_cents = current_funding_usd_cents + p_usd_cents
  WHERE id = p_campaign_id;

  RETURN v_ledger_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Status transition RPCs (SECURITY DEFINER — platform/admin use only)
-- ─────────────────────────────────────────────────────────────────────────────

-- Creator submits draft for review → pending
CREATE OR REPLACE FUNCTION public.campaign_submit_for_review(p_campaign_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.campaigns
  SET status = 'pending'
  WHERE id = p_campaign_id
    AND creator_id = auth.uid()
    AND status = 'draft';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign not found, not owned by you, or not in draft status';
  END IF;
END;
$$;

-- Platform approves + sets funding window → open
CREATE OR REPLACE FUNCTION public.campaign_approve(
  p_campaign_id UUID,
  p_opens_at    TIMESTAMPTZ,
  p_closes_at   TIMESTAMPTZ
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.campaigns
  SET status    = 'open',
      opens_at  = p_opens_at,
      closes_at = p_closes_at
  WHERE id = p_campaign_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign not found or not in pending status';
  END IF;
END;
$$;
