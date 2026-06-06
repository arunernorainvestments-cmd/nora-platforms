-- ─────────────────────────────────────────────────────────────────────────────
-- 088 — Match Revenue Token Types & Config (Redesign Doc 1)
--
-- Extends token_transactions.type CHECK with new match reward types so that
-- distribute_match_revenue (doc 2) can write its ledger rows without
-- check-violation errors.
--
-- Existing types preserved verbatim from migration 034. Added:
--   card_purchase, card_sale,
--   match_active_reward, match_creator_reward, match_passive_reward,
--   chit_earn, chit_purchase, chit_sale,
--   poll_boost_applied,
--   platform_fee  ← added beyond doc spec; distribute_match_revenue (doc 2)
--                  inserts platform pool ledger rows with this type.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (type IN (
    -- Existing (must not remove any):
    'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
    'refund', 'promoted', 'referral_bonus', 'purchase', 'purchased',
    'challenge_reward', 'passive_bonus',
    'arena_back', 'arena_win', 'arena_trigger',
    'verification_bonus',
    -- New types added by this migration:
    'card_purchase',
    'card_sale',
    'match_active_reward',
    'match_creator_reward',
    'match_passive_reward',
    'chit_earn',
    'chit_purchase',
    'chit_sale',
    'poll_boost_applied',
    'platform_fee'
  ));

-- ── match_revenue_config ────────────────────────────────────────────────────
-- Platform-level constants for distribute_match_revenue (doc 2).
-- Stored in a table for auditability and possible runtime tuning.
CREATE TABLE match_revenue_config (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key                  TEXT NOT NULL UNIQUE,
  config_value                DECIMAL(6,4) NOT NULL,
  description                 TEXT,
  effective_from              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO match_revenue_config (config_key, config_value, description) VALUES
  ('winner_betters_pct',     0.7500, 'Winning betters share of Arena pool'),
  ('active_participants_pct',0.1000, 'Winning team owners/creators who played'),
  ('creator_pct',            0.0500, 'Original market makers of all chars in match, split equally'),
  ('passive_owners_pct',     0.0500, 'All card holders for chars in match, proportional to stake'),
  ('platform_pct',           0.0500, 'Platform fee (burned)');

-- Read-only to clients; modifications via service role only.
ALTER TABLE match_revenue_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "revenue_config_public_read"
  ON match_revenue_config FOR SELECT USING (TRUE);
