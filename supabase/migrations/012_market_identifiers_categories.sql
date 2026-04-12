-- Migration 012: Market identifiers + category system
-- Apply directly in Supabase SQL Editor. Do not run supabase db push.

-- ── Market identifier columns ────────────────────────────────────────────────
ALTER TABLE public.markets
  ADD COLUMN IF NOT EXISTS market_series     TEXT,
  ADD COLUMN IF NOT EXISTS market_event      TEXT,
  ADD COLUMN IF NOT EXISTS market_identifier TEXT;

-- ── Category columns on markets (snapshotted from Market Maker at creation) ──
ALTER TABLE public.markets
  ADD COLUMN IF NOT EXISTS category_1 TEXT,
  ADD COLUMN IF NOT EXISTS category_2 TEXT;

-- ── Category columns on profiles ────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS category_1 TEXT CHECK (category_1 IN (
    'Athlete','Influencer','Musician','Healthcare','Doctor','Comedian',
    'Politician','Gamer','Educator','Fitness','Business','Religion',
    'Researcher','Sports'
  )),
  ADD COLUMN IF NOT EXISTS category_2 TEXT CHECK (category_2 IN (
    'Athlete','Influencer','Musician','Healthcare','Doctor','Comedian',
    'Politician','Gamer','Educator','Fitness','Business','Religion',
    'Researcher','Sports'
  ));

-- ── Indexes for category filtering ──────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_markets_category_1 ON public.markets (category_1);
CREATE INDEX IF NOT EXISTS idx_markets_category_2 ON public.markets (category_2);
