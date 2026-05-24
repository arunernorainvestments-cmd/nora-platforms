-- Migration 073: Simulated USD balances for campaign testing.
-- No real money involved. Seeded at $10,000 per user on first campaign interaction.
-- Only consumed when campaign.mode = 'simulated'.

CREATE TABLE public.sim_usd_balances (
  user_id                   UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  balance_usd_cents         BIGINT NOT NULL DEFAULT 1000000, -- $10,000
  lifetime_invested_cents   BIGINT NOT NULL DEFAULT 0,
  lifetime_returned_cents   BIGINT NOT NULL DEFAULT 0,
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.sim_usd_transactions (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type                TEXT NOT NULL CHECK (type IN (
    'seed','investment','refund','distribution','secondary_purchase',
    'secondary_sale','fee','governance_release'
  )),
  amount_usd_cents    BIGINT NOT NULL, -- negative = debit, positive = credit
  reference_id        UUID,            -- campaign_id, listing_id, etc.
  description         TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sim_usd_tx_user_idx ON public.sim_usd_transactions (user_id, created_at DESC);

-- RLS
ALTER TABLE public.sim_usd_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sim_usd_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sim_balance_select_own" ON public.sim_usd_balances
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "sim_tx_select_own" ON public.sim_usd_transactions
  FOR SELECT USING (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- sim_seed_balance(p_user_id)
-- Inserts a $10,000 simulated balance for the user if none exists.
-- Idempotent — safe to call on every campaign page load.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sim_seed_balance(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.sim_usd_balances (user_id, balance_usd_cents)
  VALUES (p_user_id, 1000000)
  ON CONFLICT (user_id) DO NOTHING;

  -- Log the seed only if balance was just created
  IF NOT FOUND THEN RETURN; END IF;

  INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, description)
  VALUES (p_user_id, 'seed', 1000000, 'Initial simulated balance — $10,000');
END;
$$;
