-- Migration 007: Stripe token purchases
-- Creates token_purchases table for tracking Stripe Checkout sessions

CREATE TABLE IF NOT EXISTS public.token_purchases (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  stripe_session_id        TEXT NOT NULL UNIQUE,
  stripe_payment_intent_id TEXT,
  package_id               TEXT NOT NULL CHECK (package_id IN ('starter', 'popular', 'pro', 'elite')),
  tokens_granted           INTEGER NOT NULL CHECK (tokens_granted > 0),
  amount_paid_cents        INTEGER NOT NULL CHECK (amount_paid_cents > 0),
  currency                 TEXT NOT NULL DEFAULT 'usd',
  status                   TEXT NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at             TIMESTAMPTZ
);

-- Index for webhook lookups by stripe_session_id
CREATE INDEX IF NOT EXISTS idx_token_purchases_stripe_session
  ON public.token_purchases (stripe_session_id);

-- Index for user history lookups
CREATE INDEX IF NOT EXISTS idx_token_purchases_user_id
  ON public.token_purchases (user_id);

-- RLS
ALTER TABLE public.token_purchases ENABLE ROW LEVEL SECURITY;

-- Users can read their own purchases
CREATE POLICY "Users can view own purchases"
  ON public.token_purchases
  FOR SELECT
  USING (auth.uid() = user_id);

-- Only service role can insert / update (webhook does this)
-- No INSERT or UPDATE policies for authenticated role — service role bypasses RLS
