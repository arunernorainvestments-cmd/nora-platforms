-- Migration 044: Subcategory modifier layer
-- Each subcategory gets a single ±5–10% modifier to one stat.
-- Applied at match start as a permanent passive effect (source='subcategory').
-- Cannot be dispelled (source='subcategory' check in tick loop skips decay).

-- ── Table ─────────────────────────────────────────────────────────────────────

CREATE TABLE public.arena_subcategory_modifiers (
  subcategory    text    NOT NULL PRIMARY KEY,
  archetype      text    NOT NULL,
  modifier       text    NOT NULL CHECK (modifier IN (
                   'flow_rate_multiplier', 'heat_influence_multiplier',
                   'ability_effectiveness', 'opponent_efficiency',
                   'momentum_window', 'suppression_level', 'flow_rate_ceiling'
                 )),
  modifier_value numeric NOT NULL,
  description    text
);

ALTER TABLE public.arena_subcategory_modifiers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_subcategory_modifiers: authenticated read"
  ON public.arena_subcategory_modifiers FOR SELECT TO authenticated USING (true);

-- Add subcategory columns to arena_matches for tick loop lookup without extra query.
ALTER TABLE public.arena_matches
  ADD COLUMN IF NOT EXISTS subcategory_p1 text,
  ADD COLUMN IF NOT EXISTS subcategory_p2 text;

-- ── Seed subcategory modifiers ─────────────────────────────────────────────────
-- 6 Athlete, 6 Musician, 6 Healthcare, 4 Performer, 6 Gamer,
-- 7 Influencer, 4 Educator, 5 Politician, 8 Religion, 7 Business = 59 rows
-- Where spec doesn't specify, default +5% on archetype's primary modifier.

INSERT INTO public.arena_subcategory_modifiers
  (subcategory, archetype, modifier, modifier_value, description)
VALUES
  -- ── ATHLETE ──
  ('basketball', 'athlete', 'momentum_window',      1.05, 'Slightly more frequent momentum spikes'),
  ('football',   'athlete', 'flow_rate_multiplier', 1.05, 'High-burst playstyle'),
  ('golf',       'athlete', 'suppression_level',    0.95, 'Calm under pressure — slightly less incoming suppression'),
  ('tennis',     'athlete', 'ability_effectiveness',1.05, 'Precision timing on abilities'),
  ('baseball',   'athlete', 'flow_rate_multiplier', 1.03, 'Steady sustained output'),
  ('lacrosse',   'athlete', 'momentum_window',      1.03, 'Slightly elevated momentum windows'),

  -- ── MUSICIAN ──
  ('dj',        'musician', 'ability_effectiveness', 1.10, 'Effects last 10% longer (complements Replay Value)'),
  ('guitarist', 'musician', 'flow_rate_multiplier',  1.05, 'Riff-driven flow boost'),
  ('singer',    'musician', 'heat_influence_multiplier', 1.05, 'Vocal presence amplifies Heat Score'),
  ('drummer',   'musician', 'momentum_window',       1.05, 'Rhythmic momentum spikes'),
  ('violinist', 'musician', 'ability_effectiveness', 1.05, 'Precision classical technique'),
  ('pianist',   'musician', 'suppression_level',     0.95, 'Composed — reduced incoming suppression'),

  -- ── HEALTHCARE ──
  ('surgeon',         'healthcare', 'suppression_level',     0.90, 'Extra stability — strong suppression resistance'),
  ('nurse',           'healthcare', 'ability_effectiveness', 1.05, 'Efficient care delivery'),
  ('geneticist',      'healthcare', 'flow_rate_multiplier',  1.03, 'Systematic sustained output'),
  ('hospitalist',     'healthcare', 'suppression_level',     0.95, 'Steady under pressure'),
  ('doctor_general',  'healthcare', 'flow_rate_multiplier',  1.03, 'Well-rounded flow boost'),
  ('researcher',      'healthcare', 'ability_effectiveness', 1.05, 'Methodical ability use'),

  -- ── PERFORMER ──
  ('comedian', 'performer', 'momentum_window',      1.10, 'High volatility — frequent momentum swings'),
  ('dancer',   'performer', 'flow_rate_multiplier', 1.05, 'Kinetic energy translates to flow'),
  ('magician', 'performer', 'ability_effectiveness',1.05, 'Sleight of hand — abilities hit harder'),
  ('podcaster','performer', 'heat_influence_multiplier', 1.05, 'Built audience presence amplifies heat'),

  -- ── GAMER ──
  ('competitive', 'gamer', 'ability_effectiveness', 1.08, 'High-skill ceiling on ability execution'),
  ('developer',   'gamer', 'flow_rate_multiplier',  1.05, 'Systematic — sustained output'),
  ('streamer',    'gamer', 'heat_influence_multiplier', 1.05, 'Live audience presence amplifies heat'),
  ('tabletop',    'gamer', 'ability_effectiveness', 1.05, 'Strategic ability timing'),
  ('pc',          'gamer', 'momentum_window',        1.05, 'Fast execution opens momentum windows'),
  ('console',     'gamer', 'flow_rate_multiplier',  1.03, 'Consistent mainstream appeal'),

  -- ── INFLUENCER ──
  ('fitness',      'influencer', 'flow_rate_multiplier',      1.05, 'Active engaged following'),
  ('travel',       'influencer', 'heat_influence_multiplier', 1.05, 'Aspirational content amplifies heat'),
  ('vlog',         'influencer', 'flow_rate_multiplier',      1.03, 'Daily content keeps flow steady'),
  ('food',         'influencer', 'heat_influence_multiplier', 1.03, 'Highly shareable content'),
  ('prankster',    'influencer', 'momentum_window',           1.10, 'Viral chaos — extra momentum swings'),
  ('journalist',   'influencer', 'ability_effectiveness',     1.05, 'Precision messaging'),
  ('commentator',  'influencer', 'heat_influence_multiplier', 1.03, 'Real-time commentary amplifies heat'),

  -- ── EDUCATOR ──
  ('author',     'educator', 'ability_effectiveness', 1.05, 'Persuasive written communication'),
  ('teacher',    'educator', 'flow_rate_multiplier',  1.05, 'Consistent delivery of value'),
  ('professor',  'educator', 'ability_effectiveness', 1.08, 'Deep expertise amplifies ability impact'),
  ('expert',     'educator', 'suppression_level',     0.95, 'Unflappable authority'),

  -- ── POLITICIAN ──
  ('city_council',  'politician', 'flow_rate_multiplier',  1.03, 'Local grassroots momentum'),
  ('state_senate',  'politician', 'ability_effectiveness', 1.05, 'Experienced legislative precision'),
  ('congress',      'politician', 'heat_influence_multiplier', 1.05, 'National profile amplifies heat'),
  ('governor',      'politician', 'ability_effectiveness', 1.08, 'Executive authority on abilities'),
  ('other',         'politician', 'flow_rate_multiplier',  1.03, 'General political appeal'),

  -- ── RELIGION ──
  ('bishop',    'religion', 'heat_influence_multiplier', 1.08, 'Senior authority amplifies heat'),
  ('deacon',    'religion', 'flow_rate_multiplier',      1.03, 'Steady service-oriented output'),
  ('minister',  'religion', 'ability_effectiveness',     1.05, 'Compelling delivery'),
  ('priest',    'religion', 'suppression_level',         0.95, 'Calm presence — suppression resistance'),
  ('pastor',    'religion', 'flow_rate_multiplier',      1.05, 'Strong congregation engagement'),
  ('rabbi',     'religion', 'ability_effectiveness',     1.05, 'Scholarly precision'),
  ('guru',      'religion', 'momentum_window',           1.08, 'Elevated state — frequent momentum'),
  ('yogi',      'religion', 'suppression_level',         0.90, 'Inner peace — strong suppression resistance'),

  -- ── BUSINESS ──
  ('startup',       'business', 'momentum_window',           1.08, 'High-growth volatility — momentum spikes'),
  ('retail',        'business', 'flow_rate_multiplier',      1.03, 'Steady consumer-facing output'),
  ('non_profit',    'business', 'heat_influence_multiplier', 1.05, 'Mission-driven audience amplifies heat'),
  ('small_business','business', 'flow_rate_multiplier',      1.05, 'Community engagement'),
  ('niche',         'business', 'ability_effectiveness',     1.08, 'Deep domain expertise'),
  ('handmade',      'business', 'heat_influence_multiplier', 1.05, 'Authentic craft appeal'),
  ('corporation',   'business', 'opponent_efficiency',       0.95, 'Market dominance — slight opponent efficiency reduction');
