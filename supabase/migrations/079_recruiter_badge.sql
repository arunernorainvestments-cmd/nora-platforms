-- ─────────────────────────────────────────────────────────────────────────────
-- 079 — Recruiter badge, challenge definitions, invite_link_sends tracking
-- ─────────────────────────────────────────────────────────────────────────────

-- Recruiter badges (bronze / silver / gold tiers)
INSERT INTO badge_definitions (slug, name, description, tier, condition_type, pool)
VALUES
  ('recruiter_bronze', 'Recruiter',       'Invited your first friend to N.O.R.A.',         'bronze', 'referral_signup', 'all'),
  ('recruiter_silver', 'Super Recruiter', 'Invited 5 friends who joined N.O.R.A.',         'silver', 'referral_signup', 'all'),
  ('recruiter_gold',   'Elite Recruiter', 'Invited 10 friends who joined N.O.R.A.',        'gold',   'referral_signup', 'all')
ON CONFLICT (slug) DO NOTHING;

-- Challenge: first referral signup → bronze Recruiter badge + 25 token bonus
INSERT INTO challenge_definitions (slug, badge_id, track, condition, token_reward, pool, is_active)
VALUES (
  'once_first_referral',
  (SELECT id FROM badge_definitions WHERE slug = 'recruiter_bronze'),
  'once',
  '{"type": "count_threshold", "event": "referral_signup", "count": 1}',
  25,
  'all',
  true
)
ON CONFLICT (slug) DO NOTHING;

-- Challenge: 5 referral signups → silver badge + 50 token bonus
INSERT INTO challenge_definitions (slug, badge_id, track, condition, token_reward, pool, is_active)
VALUES (
  'once_five_referrals',
  (SELECT id FROM badge_definitions WHERE slug = 'recruiter_silver'),
  'once',
  '{"type": "count_threshold", "event": "referral_signup", "count": 5}',
  50,
  'all',
  true
)
ON CONFLICT (slug) DO NOTHING;

-- Challenge: 10 referral signups → gold badge + 100 token bonus
INSERT INTO challenge_definitions (slug, badge_id, track, condition, token_reward, pool, is_active)
VALUES (
  'once_ten_referrals',
  (SELECT id FROM badge_definitions WHERE slug = 'recruiter_gold'),
  'once',
  '{"type": "count_threshold", "event": "referral_signup", "count": 10}',
  100,
  'all',
  true
)
ON CONFLICT (slug) DO NOTHING;

-- Table for tracking invite link shares (daily send reward enforcement)
CREATE TABLE IF NOT EXISTS invite_link_sends (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sent_at     timestamptz NOT NULL DEFAULT now(),
  tokens_awarded int      NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS invite_link_sends_user_date
  ON invite_link_sends (user_id, sent_at);

-- RLS: users can only read their own rows; inserts go through the edge function (service role)
ALTER TABLE invite_link_sends ENABLE ROW LEVEL SECURITY;

CREATE POLICY "invite_link_sends_select_own"
  ON invite_link_sends FOR SELECT
  USING (auth.uid() = user_id);
