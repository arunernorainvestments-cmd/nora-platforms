-- ─────────────────────────────────────────────────────────────────────────────
-- 009_market_resolution.sql — Schema additions for Phase 5 market resolution
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Add resolution columns to markets ────────────────────────────────────────

ALTER TABLE public.markets
  ADD COLUMN resolved_at              timestamptz,
  ADD COLUMN resolution_result        text,
  ADD COLUMN platform_fee_collected   integer DEFAULT 0,
  ADD COLUMN market_maker_fee_collected integer DEFAULT 0;

-- ── Add 'refund' to token_transactions type constraint ───────────────────────

ALTER TABLE public.token_transactions
  DROP CONSTRAINT token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (type IN (
    'signup_bonus',
    'bet_placed',
    'bet_won',
    'bet_lost',
    'refund',
    'promoted',
    'purchased',
    'verification_bonus',
    'referral_bonus'
  ));

-- ── Add 'bet_refunded' and 'market_resolved' to notifications type constraint ─

ALTER TABLE public.notifications
  DROP CONSTRAINT notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check CHECK (type IN (
    'market_opened',
    'bet_won',
    'bet_lost',
    'bet_refunded',
    'market_resolved',
    'market_closing_soon',
    'referral_bonus',
    'token_earned'
  ));
