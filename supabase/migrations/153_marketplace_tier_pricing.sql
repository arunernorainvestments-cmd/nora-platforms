-- Migration 153: marketplace tier pricing config (Marketplace M1 — spec §3.1).
--
-- The public fixed-price marketplace for minted moment chits sells at CONFIG prices,
-- one row per tier F–S. Prices/fees are config, not code — tuning is an UPDATE here,
-- never a rebuild. Token peg is 100🪙 = $1 (display-only; tokens never cash out).
-- The USD column is recorded now so the M2 lane flip is a branch, not a data
-- migration; in M1 every sale is tokens (Hard Rule 33 stays intact — no crossing).
--
-- Fee: A/S sales only, expressed in basis points, and the fee is a BURN (tokens leave
-- supply — the deflationary sink), never platform income. No appreciation mechanics
-- anywhere (G-CARDVAL stays parked): fixed prices, no supply/demand, no accrual.
--
-- Spec: NORA_PLATFORMS_MARKETPLACE_SPEC.md §3.1 / PHASE M1.

CREATE TABLE public.marketplace_tier_pricing (
  tier        TEXT PRIMARY KEY CHECK (tier IN ('F','E','D','C','B','A','S')),
  usd_cents   INTEGER NOT NULL CHECK (usd_cents > 0),    -- integer cents, no floats (HR33)
  token_price INTEGER NOT NULL CHECK (token_price > 0),
  fee_bps     INTEGER NOT NULL DEFAULT 0 CHECK (fee_bps BETWEEN 0 AND 10000),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.marketplace_tier_pricing IS
  'Fixed-price scale for the moment-chit marketplace (spec §1). Token lane live in M1; '
  'usd_cents is USD-ready config for M2 (inert until the lane flips). fee_bps applies '
  'to A/S sales only and is BURNED, not collected.';

INSERT INTO public.marketplace_tier_pricing (tier, usd_cents, token_price, fee_bps) VALUES
  ('F',   100,   100,    0),
  ('E',   200,   200,    0),
  ('D',   500,   500,    0),
  ('C',  1000,  1000,    0),
  ('B',  2500,  2500,    0),
  ('A',  5000,  5000, 1000),   -- 10% burn
  ('S', 10000, 10000, 1500);   -- 15% burn

-- ── RLS: pricing is public-read config; writes only via migrations/service role ──
ALTER TABLE public.marketplace_tier_pricing ENABLE ROW LEVEL SECURITY;

CREATE POLICY "marketplace_tier_pricing_select_all" ON public.marketplace_tier_pricing
  FOR SELECT USING (TRUE);
-- No INSERT/UPDATE/DELETE policies: config changes are migrations (or service role).
