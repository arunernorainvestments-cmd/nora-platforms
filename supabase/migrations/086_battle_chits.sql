-- ─────────────────────────────────────────────────────────────────────────────
-- 086 — Battle Chits (Redesign Doc 1)
--
-- Chits are single-use battle items with various effect types. Acquired via
-- challenges (common+), match-win RNG drops (rare+), marketplace (uncommon+,
-- if can_buy_in_marketplace), or gifts (epic+).
--
-- Effects are applied by process_battle_turn (modified in doc 2) by writing
-- to arena_state.active_effects following the same pattern as arena_trigger.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE battle_chit_definitions (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                        TEXT NOT NULL UNIQUE,
  description                 TEXT NOT NULL,
  rarity                      TEXT NOT NULL CHECK (rarity IN (
    'common', 'uncommon', 'rare', 'epic', 'legendary', 'mythic'
  )),
  effect_type                 TEXT NOT NULL CHECK (effect_type IN (
    'stat_boost',
    'damage_shield',
    'momentum_surge',
    'counter',
    'type_override',
    'speed_burst',
    'aura',
    'disruption',
    'wild_card'
  )),
  effect_value                DECIMAL(10,4) NOT NULL DEFAULT 0,
  effect_target               TEXT NOT NULL DEFAULT 'self'
    CHECK (effect_target IN ('self', 'opponent', 'all')),
  effect_duration_turns       INTEGER,
  stat_target                 TEXT CHECK (stat_target IN (
    'power','charisma','resilience','agility','wit','influence','all'
  )),

  can_earn_from_challenges    BOOLEAN NOT NULL DEFAULT TRUE,
  can_buy_in_marketplace      BOOLEAN NOT NULL DEFAULT FALSE,
  can_earn_from_match_rng     BOOLEAN NOT NULL DEFAULT FALSE,
  can_receive_as_gift         BOOLEAN NOT NULL DEFAULT FALSE,

  rng_drop_rate               DECIMAL(6,5),

  marketplace_price_tokens    INTEGER,
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed initial chit catalog.
INSERT INTO battle_chit_definitions
  (name, description, rarity, effect_type, effect_value, effect_target,
   effect_duration_turns, stat_target, can_earn_from_challenges,
   can_buy_in_marketplace, can_earn_from_match_rng, can_receive_as_gift,
   rng_drop_rate, marketplace_price_tokens)
VALUES
  ('Bronze Shield',     'Block the next 20 damage received.',                 'common',    'damage_shield',  20,   'self',     NULL, NULL,        TRUE,  FALSE, FALSE, FALSE, NULL,    50),
  ('Silver Shield',     'Block the next 40 damage received.',                 'uncommon',  'damage_shield',  40,   'self',     NULL, NULL,        TRUE,  TRUE,  FALSE, FALSE, NULL,    120),
  ('Power Surge',       '+15 to Power stat for this match.',                  'common',    'stat_boost',     15,   'self',     0,    'power',     TRUE,  FALSE, FALSE, FALSE, NULL,    60),
  ('Momentum Crystal',  '+40 instant momentum.',                              'uncommon',  'momentum_surge', 40,   'self',     NULL, NULL,        TRUE,  TRUE,  FALSE, FALSE, NULL,    100),
  ('Counter Stance',    'Reflect the next ability back to attacker.',         'rare',      'counter',        1,    'self',     1,    NULL,        FALSE, FALSE, TRUE,  FALSE, 0.10000, 250),
  ('Speed Burst',       '+30 to speed for 2 turns.',                          'rare',      'speed_burst',    30,   'self',     2,    NULL,        FALSE, FALSE, TRUE,  FALSE, 0.08000, 200),
  ('Charisma Aura',     '+20% to all Charisma-based calculations for this match.', 'rare', 'aura',           1.20, 'self',     0,    'charisma',  FALSE, FALSE, TRUE,  FALSE, 0.07000, 220),
  ('Disruptor',         'Remove one random active effect from an opponent.',  'epic',      'disruption',     1,    'opponent', NULL, NULL,        FALSE, FALSE, TRUE,  FALSE, 0.03000, NULL),
  ('Type Breaker',      'Ignore type multiplier for your next attack.',       'epic',      'type_override',  1,    'self',     1,    NULL,        FALSE, FALSE, TRUE,  FALSE, 0.02500, NULL),
  ('Wild Card',         'Swap any team member mid-match, bypassing normal swap rules.', 'legendary', 'wild_card', 1, 'self', NULL, NULL,         FALSE, FALSE, TRUE,  FALSE, 0.00500, NULL),
  ('NORA Aura',         'All stats +25 for the entire match. Passive.',       'mythic',    'aura',           1.50, 'self',     0,    'all',       FALSE, FALSE, FALSE, TRUE,  NULL,    NULL);

-- ── user_battle_chits (inventory) ───────────────────────────────────────────
CREATE TABLE user_battle_chits (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chit_definition_id          UUID NOT NULL REFERENCES battle_chit_definitions(id),
  quantity                    INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  acquired_via                TEXT NOT NULL CHECK (acquired_via IN (
    'challenge_reward', 'match_rng', 'marketplace_purchase', 'gift', 'event'
  )),
  acquired_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, chit_definition_id)
);

-- ── chit_marketplace_listings ───────────────────────────────────────────────
CREATE TABLE chit_marketplace_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  chit_definition_id          UUID NOT NULL REFERENCES battle_chit_definitions(id),
  quantity_listed             INTEGER NOT NULL DEFAULT 1 CHECK (quantity_listed > 0),
  price_per_unit_tokens       INTEGER NOT NULL CHECK (price_per_unit_tokens > 0),
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'sold', 'cancelled')),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX chit_listings_active_idx ON chit_marketplace_listings (status, chit_definition_id);

-- ── Extend battle_events: chit_id column + event_type CHECK ─────────────────
ALTER TABLE battle_events
  ADD COLUMN chit_id UUID REFERENCES battle_chit_definitions(id);

ALTER TABLE battle_events DROP CONSTRAINT IF EXISTS battle_events_event_type_check;
ALTER TABLE battle_events ADD CONSTRAINT battle_events_event_type_check
  CHECK (event_type IN (
    'swap_voluntary','swap_forced','ability_used','ultimate_used',
    'ko','momentum_gained','ultimate_ready','auto_selected','match_end',
    'chit_used'
  ));

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE battle_chit_definitions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_battle_chits            ENABLE ROW LEVEL SECURITY;
ALTER TABLE chit_marketplace_listings    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "chit_definitions_public_read"
  ON battle_chit_definitions FOR SELECT USING (TRUE);

CREATE POLICY "user_chits_self_read"
  ON user_battle_chits FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "chit_listings_public_read"
  ON chit_marketplace_listings FOR SELECT
  USING (status = 'active' OR auth.uid() = seller_user_id);

CREATE POLICY "chit_listings_seller_update"
  ON chit_marketplace_listings FOR UPDATE
  USING (auth.uid() = seller_user_id);
