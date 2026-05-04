-- Hot Topic: celebrity buzz leaderboard core tables + seed
-- Celebrities in this feature are public figures with no NORA platform_metrics/heat_score.
-- All Hot Topic data lives exclusively in these new tables.

CREATE TABLE celebs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  aliases    TEXT[] DEFAULT '{}',
  category   TEXT,
  image_url  TEXT,
  active     BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE celeb_weekly_scores (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_id      TEXT NOT NULL,
  celeb_id     UUID NOT NULL REFERENCES celebs(id) ON DELETE CASCADE,
  points       INTEGER NOT NULL DEFAULT 1000,
  rank         INTEGER,
  story_volume INTEGER DEFAULT 0,
  last_delta   INTEGER DEFAULT 0,
  last_tier    TEXT,
  reason_text  TEXT,
  updated_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(week_id, celeb_id)
);

CREATE TABLE celeb_score_history (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_id        TEXT NOT NULL,
  celeb_id       UUID NOT NULL REFERENCES celebs(id) ON DELETE CASCADE,
  tier           TEXT NOT NULL,
  delta          INTEGER NOT NULL,
  story_volume   INTEGER DEFAULT 0,
  reason_text    TEXT,
  scoring_window TEXT,
  scored_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE weekly_bets (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  week_id          TEXT NOT NULL,
  bet_category     TEXT NOT NULL CHECK (bet_category IN ('simple', 'weekly')),
  weekly_bet_type  TEXT CHECK (weekly_bet_type IN ('person_of_week', 'top_riser', 'big_boo', 'top_5')),
  simple_direction TEXT CHECK (simple_direction IN ('up', 'down')),
  celeb_id         UUID REFERENCES celebs(id),
  scoring_window   TEXT,
  tokens_wagered   INTEGER NOT NULL CHECK (tokens_wagered > 0),
  status           TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'won', 'lost')),
  payout           INTEGER,
  placed_at        TIMESTAMPTZ DEFAULT NOW()
);

-- One weekly bet per user per week per bet type (person_of_week, top_riser, etc.)
CREATE UNIQUE INDEX unique_weekly_bet_idx
  ON weekly_bets(user_id, week_id, weekly_bet_type)
  WHERE bet_category = 'weekly';

-- One simple bet per user per celeb per window per direction
CREATE UNIQUE INDEX unique_simple_bet_idx
  ON weekly_bets(user_id, celeb_id, scoring_window, simple_direction)
  WHERE bet_category = 'simple';

-- RLS
ALTER TABLE celebs ENABLE ROW LEVEL SECURITY;
ALTER TABLE celeb_weekly_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE celeb_score_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_bets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public read celebs" ON celebs FOR SELECT USING (true);
CREATE POLICY "public read scores" ON celeb_weekly_scores FOR SELECT USING (true);
CREATE POLICY "public read history" ON celeb_score_history FOR SELECT USING (true);
CREATE POLICY "users read own bets" ON weekly_bets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "users insert own bets" ON weekly_bets FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Seed 25 celebrities
-- NOTE: Prince Harry & Meghan Markle are treated as one entry for MVP.
-- Tracking them separately in the future requires a separate migration + data migration.
INSERT INTO celebs (name, aliases, category) VALUES
  ('Taylor Swift',                ARRAY['Taylor Swift'],                                                       'entertainment'),
  ('Zendaya',                     ARRAY['Zendaya'],                                                            'entertainment'),
  ('Timothée Chalamet',           ARRAY['Timothee Chalamet', 'Timothée Chalamet'],                            'entertainment'),
  ('Sabrina Carpenter',           ARRAY['Sabrina Carpenter'],                                                  'entertainment'),
  ('Alix Earle',                  ARRAY['Alix Earle'],                                                         'entertainment'),
  ('Kanye West',                  ARRAY['Kanye West', 'Ye'],                                                   'entertainment'),
  ('Drake',                       ARRAY['Drake', 'Aubrey Graham'],                                             'entertainment'),
  ('Paris Hilton',                ARRAY['Paris Hilton'],                                                       'entertainment'),
  ('Cristiano Ronaldo',           ARRAY['Cristiano Ronaldo', 'CR7'],                                           'sports'),
  ('LeBron James',                ARRAY['LeBron James', 'LBJ'],                                                'sports'),
  ('Caitlin Clark',               ARRAY['Caitlin Clark'],                                                      'sports'),
  ('Lionel Messi',                ARRAY['Lionel Messi', 'Leo Messi'],                                         'sports'),
  ('Donald Trump',                ARRAY['Donald Trump', 'Trump'],                                              'politics'),
  ('Narendra Modi',               ARRAY['Narendra Modi', 'Modi'],                                              'politics'),
  ('Volodymyr Zelenskyy',         ARRAY['Volodymyr Zelenskyy', 'Zelensky'],                                   'politics'),
  ('Michelle Obama',              ARRAY['Michelle Obama'],                                                      'politics'),
  ('Elon Musk',                   ARRAY['Elon Musk'],                                                          'business'),
  ('Jeff Bezos',                  ARRAY['Jeff Bezos'],                                                         'business'),
  ('Mark Zuckerberg',             ARRAY['Mark Zuckerberg', 'Zuckerberg'],                                     'business'),
  ('Justin Bieber',               ARRAY['Justin Bieber'],                                                      'music'),
  ('MrBeast',                     ARRAY['MrBeast', 'Jimmy Donaldson'],                                        'influencer'),
  ('Kylie Jenner',                ARRAY['Kylie Jenner'],                                                       'entertainment'),
  ('Prince Harry & Meghan Markle',ARRAY['Prince Harry', 'Meghan Markle', 'Duke of Sussex', 'Duchess of Sussex'],'royalty'),
  ('Tom Cruise',                  ARRAY['Tom Cruise'],                                                         'entertainment'),
  ('Pope Leo XIV',                ARRAY['Pope Leo XIV', 'Robert Prevost', 'Robert Francis Prevost', 'Pope Leo'],'other')
ON CONFLICT (name) DO NOTHING;
