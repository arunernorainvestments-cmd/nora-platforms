-- Migration 016: Challenges & Badges system
-- Tables: badge_definitions, challenge_definitions, user_badges,
--         user_challenge_progress, user_streaks
-- Also updates token_transactions type constraint to include 'challenge_reward'.
--
-- Launch date: 2026-07-04 (July 4th). OG badge cutoff = 2026-07-04, Early Adopter = 2026-08-03.
-- Dates in challenge_definitions were updated via SQL Editor (migration already applied).
--
-- Main Character badge requires a separate pg_cron hourly check (not in this
-- migration) — see evaluate-challenges/index.ts notes.

-- ── 1. Extend token_transactions type constraint ───────────────────────────────

ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (type IN (
    'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
    'promoted', 'purchased', 'verification_bonus',
    'referral_bonus', 'refund', 'challenge_reward'
  ));

-- ── 2. badge_definitions ──────────────────────────────────────────────────────

CREATE TABLE public.badge_definitions (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug           TEXT        UNIQUE NOT NULL,
  name           TEXT        NOT NULL,
  description    TEXT        NOT NULL,
  tier           TEXT        NOT NULL CHECK (tier IN ('bronze', 'silver', 'gold')),
  condition_type TEXT        NOT NULL CHECK (condition_type IN (
                               'snapshot', 'count_threshold', 'streak', 'composite', 'manual'
                             )),
  passive_effect JSONB,
  icon_key       TEXT,
  pool           TEXT        NOT NULL DEFAULT 'all' CHECK (pool IN ('all', 'mm')),
  is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 3. challenge_definitions ──────────────────────────────────────────────────

CREATE TABLE public.challenge_definitions (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug         TEXT        UNIQUE NOT NULL,
  badge_id     UUID        REFERENCES public.badge_definitions(id),
  track        TEXT        NOT NULL CHECK (track IN ('daily', 'weekly', 'monthly', 'once')),
  condition    JSONB       NOT NULL,
  token_reward INTEGER     NOT NULL DEFAULT 0,
  pool         TEXT        NOT NULL DEFAULT 'all' CHECK (pool IN ('all', 'mm')),
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  starts_at    TIMESTAMPTZ,
  ends_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 4. user_badges ────────────────────────────────────────────────────────────

CREATE TABLE public.user_badges (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  badge_id     UUID        NOT NULL REFERENCES public.badge_definitions(id),
  challenge_id UUID        REFERENCES public.challenge_definitions(id),
  awarded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, badge_id)
);

CREATE INDEX user_badges_user_idx ON public.user_badges (user_id);

-- ── 5. user_challenge_progress ────────────────────────────────────────────────

CREATE TABLE public.user_challenge_progress (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  challenge_id   UUID        NOT NULL REFERENCES public.challenge_definitions(id),
  period_key     TEXT        NOT NULL,
  current_count  INTEGER     NOT NULL DEFAULT 0,
  completed_at   TIMESTAMPTZ,
  tokens_awarded BOOLEAN     NOT NULL DEFAULT FALSE,
  UNIQUE (user_id, challenge_id, period_key)
);

CREATE INDEX user_challenge_progress_user_idx
  ON public.user_challenge_progress (user_id, challenge_id);

-- ── 6. user_streaks ───────────────────────────────────────────────────────────

CREATE TABLE public.user_streaks (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  streak_type   TEXT        NOT NULL,
  current_count INTEGER     NOT NULL DEFAULT 0,
  last_event_at TIMESTAMPTZ,
  UNIQUE (user_id, streak_type)
);

CREATE INDEX user_streaks_user_idx ON public.user_streaks (user_id);

-- ── 7. RLS ────────────────────────────────────────────────────────────────────

-- badge_definitions & challenge_definitions: public read, no user writes
ALTER TABLE public.badge_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.challenge_definitions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public_read_badge_definitions"
  ON public.badge_definitions FOR SELECT USING (TRUE);

CREATE POLICY "public_read_challenge_definitions"
  ON public.challenge_definitions FOR SELECT USING (TRUE);

-- user_badges: public read (badges are achievements, not sensitive), service role writes only
ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public_read_user_badges"
  ON public.user_badges FOR SELECT USING (TRUE);

-- user_challenge_progress: own rows only, service role writes only
ALTER TABLE public.user_challenge_progress ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_read_own_progress"
  ON public.user_challenge_progress FOR SELECT
  USING (auth.uid() = user_id);

-- user_streaks: own rows only, service role writes only
ALTER TABLE public.user_streaks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_read_own_streaks"
  ON public.user_streaks FOR SELECT
  USING (auth.uid() = user_id);

-- ── 8. Seed: badge_definitions ────────────────────────────────────────────────

INSERT INTO public.badge_definitions
  (slug, name, description, tier, condition_type, passive_effect, pool)
VALUES
  -- One-time / snapshot badges
  ('og',            'O.G.',           'Joined before public launch',                      'gold',   'snapshot',        '{"type":"token_earn_rate","value":0.05}',                           'all'),
  ('early_adopter', 'Early Adopter',  'Joined within 30 days of launch',                  'silver', 'snapshot',        '{"type":"token_earn_rate","value":0.02}',                           'all'),
  ('first_bet',     'First Bet',      'Placed your first ever bet',                        'bronze', 'snapshot',        NULL,                                                                'all'),
  ('spotlight',     'Spotlight',      'Appeared in the Spotlight',                         'bronze', 'snapshot',        NULL,                                                                'mm'),
  ('main_character','Main Character', 'Held the #1 Heat Score for 24 hours',              'gold',   'snapshot',        NULL,                                                                'mm'),
  ('promoted',      'Promoted',       'Used a self-boost for the first time',              'bronze', 'snapshot',        NULL,                                                                'mm'),
  ('power_tripped', 'Power Tripped',  'Had a Power-Up used against you',                  'bronze', 'manual',          NULL,                                                                'mm'),

  -- Count threshold badges
  ('referral_machine','Referral Machine','Referred 5 friends',                            'bronze', 'count_threshold', '{"type":"referral_bonus","after_n":5,"bonus_tokens":25}',           'all'),
  ('connector',     'Connector',      'Referred 10 friends',                               'silver', 'count_threshold', '{"type":"referral_bonus","after_n":10,"bonus_tokens":50}',          'all'),
  ('kingmaker',     'Kingmaker',      'Referred 25 friends',                               'gold',   'count_threshold', '{"type":"referral_bonus","after_n":25,"bonus_tokens":100}',         'all'),
  ('big_spender',   'Big Spender',    'Top stake at resolution in 3 different markets',    'silver', 'count_threshold', NULL,                                                                'all'),
  ('whale',         'Whale',          'Top stake at resolution in 5 different markets',    'gold',   'count_threshold', '{"type":"visibility_multiplier","value":0.02}',                     'all'),
  ('power_user',    'Power User',     'Used 5 different promotion types',                  'silver', 'count_threshold', '{"type":"promotion_discount","value":0.10}',                        'mm'),
  ('baller',        'Baller',         'Spent 500+ tokens in a single day',                 'bronze', 'count_threshold', NULL,                                                                'all'),

  -- Streak badges
  ('hot_streak',    'Hot Streak',     'Won 3 bets in a row',                               'bronze', 'streak',          NULL,                                                                'all'),
  ('on_fire',       'On Fire',        'Won 5 bets in a row',                               'silver', 'streak',          NULL,                                                                'all'),
  ('unstoppable',   'Unstoppable',    'Won 10 bets in a row',                              'gold',   'streak',          '{"type":"visibility_multiplier","value":0.03}',                     'all'),
  ('ice_cold',      'Ice Cold',       'Lost 5 bets in a row',                              'bronze', 'streak',          NULL,                                                                'all'),

  -- Composite badges
  ('market_oracle', 'Market Oracle',  '75%+ win rate across 20+ bets',                    'gold',   'composite',       '{"type":"visibility_multiplier","value":0.05}',                     'all'),
  ('contrarian',    'Contrarian',     'Won 3 bets on the minority side (<30% of pool)',    'silver', 'composite',       NULL,                                                                'all'),
  ('untouchable',   'Untouchable',    'Had Black Hole used on you and stayed in Spotlight same period', 'gold', 'composite', NULL,                                                           'mm');

-- ── 9. Seed: challenge_definitions ───────────────────────────────────────────
--
-- Daily challenges (token_reward: 50)

INSERT INTO public.challenge_definitions (slug, badge_id, track, condition, token_reward, pool)
VALUES
  ('daily_place_bet',    NULL, 'daily', '{"type":"count_threshold","event":"bet_placed","count":1}',                     50, 'all'),
  ('daily_spend_tokens', NULL, 'daily', '{"type":"count_threshold","event":"tokens_spent","count":1}',                    50, 'all'),
  ('daily_check_in',     NULL, 'daily', '{"type":"snapshot","field":"last_seen","within_period":true}',                   50, 'all');

-- Weekly challenges (token_reward: 100)

INSERT INTO public.challenge_definitions (slug, badge_id, track, condition, token_reward, pool)
VALUES
  ('weekly_win_3_bets',
   (SELECT id FROM public.badge_definitions WHERE slug = 'hot_streak'),
   'weekly',
   '{"type":"count_threshold","event":"bet_won","count":3}',
   100, 'all'),

  ('weekly_bet_3_makers', NULL, 'weekly',
   '{"type":"count_threshold","event":"bet_placed_unique_mm","count":3}',
   100, 'all'),

  ('weekly_use_promotion',
   (SELECT id FROM public.badge_definitions WHERE slug = 'promoted'),
   'weekly',
   '{"type":"count_threshold","event":"promotion_used","count":1}',
   100, 'mm');

-- Monthly challenges (token_reward: 150)

INSERT INTO public.challenge_definitions (slug, badge_id, track, condition, token_reward, pool)
VALUES
  ('monthly_referral',
   (SELECT id FROM public.badge_definitions WHERE slug = 'referral_machine'),
   'monthly',
   '{"type":"count_threshold","event":"referral_signup","count":1}',
   150, 'all'),

  ('monthly_5_markets',
   (SELECT id FROM public.badge_definitions WHERE slug = 'big_spender'),
   'monthly',
   '{"type":"count_threshold","event":"bet_resolved_win","count":5}',
   150, 'all'),

  ('monthly_earn_500',
   (SELECT id FROM public.badge_definitions WHERE slug = 'baller'),
   'monthly',
   '{"type":"count_threshold","event":"tokens_earned","count":500}',
   150, 'all');

-- One-time challenges (token_reward: 0 — badge is the reward)
-- OG badge cutoff: 2026-07-04 | Early Adopter cutoff: 2026-08-03
-- (updated in DB via SQL Editor; values below are historical seed only)

INSERT INTO public.challenge_definitions (slug, badge_id, track, condition, token_reward, pool)
VALUES
  ('earn_og',
   (SELECT id FROM public.badge_definitions WHERE slug = 'og'),
   'once',
   '{"type":"snapshot","field":"created_at","before":"2026-07-04"}',
   0, 'all'),

  ('earn_early_adopter',
   (SELECT id FROM public.badge_definitions WHERE slug = 'early_adopter'),
   'once',
   '{"type":"snapshot","field":"created_at","before":"2026-08-03"}',
   0, 'all'),

  ('earn_first_bet',
   (SELECT id FROM public.badge_definitions WHERE slug = 'first_bet'),
   'once',
   '{"type":"count_threshold","event":"bet_placed","count":1}',
   0, 'all'),

  ('earn_spotlight',
   (SELECT id FROM public.badge_definitions WHERE slug = 'spotlight'),
   'once',
   '{"type":"snapshot","field":"spotlight_pinned_until","ever_set":true}',
   0, 'mm'),

  ('earn_connector',
   (SELECT id FROM public.badge_definitions WHERE slug = 'connector'),
   'once',
   '{"type":"count_threshold","event":"referral_signup","count":10}',
   0, 'all'),

  ('earn_kingmaker',
   (SELECT id FROM public.badge_definitions WHERE slug = 'kingmaker'),
   'once',
   '{"type":"count_threshold","event":"referral_signup","count":25}',
   0, 'all'),

  ('earn_whale',
   (SELECT id FROM public.badge_definitions WHERE slug = 'whale'),
   'once',
   '{"type":"count_threshold","event":"market_resolution_top_stake","count":5}',
   0, 'all'),

  ('earn_power_user',
   (SELECT id FROM public.badge_definitions WHERE slug = 'power_user'),
   'once',
   '{"type":"composite","all_events":["quick_boost","major_boost","spotlight_entry","universe","galaxy"]}',
   0, 'mm'),

  ('earn_on_fire',
   (SELECT id FROM public.badge_definitions WHERE slug = 'on_fire'),
   'once',
   '{"type":"streak","event":"bet_won","count":5,"reset_on":"bet_lost"}',
   0, 'all'),

  ('earn_unstoppable',
   (SELECT id FROM public.badge_definitions WHERE slug = 'unstoppable'),
   'once',
   '{"type":"streak","event":"bet_won","count":10,"reset_on":"bet_lost"}',
   0, 'all'),

  ('earn_ice_cold',
   (SELECT id FROM public.badge_definitions WHERE slug = 'ice_cold'),
   'once',
   '{"type":"streak","event":"bet_lost","count":5,"reset_on":"bet_won"}',
   0, 'all'),

  ('earn_market_oracle',
   (SELECT id FROM public.badge_definitions WHERE slug = 'market_oracle'),
   'once',
   '{"type":"composite","win_rate_min":0.75,"min_bets":20}',
   0, 'all'),

  ('earn_contrarian',
   (SELECT id FROM public.badge_definitions WHERE slug = 'contrarian'),
   'once',
   '{"type":"composite","event":"bet_won_minority","minority_threshold":0.3,"count":3}',
   0, 'all');
