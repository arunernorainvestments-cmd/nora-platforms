-- Migration 060: Battle Mode Phase A — Core Schema
-- ============================================================
-- BATTLE MODE — entirely separate from Arena.
-- All tables, functions, and cron jobs prefixed battle_*.
-- Do NOT modify any existing tables.
-- ============================================================

-- Maps: auto-selected randomly at match start.
-- affinity_archetypes: which archetypes get a damage buff on this map.
-- Buff multiplier is 1.15 but NOT applied to damage calculation yet — wired in Phase D.
-- Store the data now so Phase D requires no schema changes.
CREATE TABLE battle_maps (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  TEXT        NOT NULL UNIQUE,
  description           TEXT,
  affinity_archetypes   TEXT[]      DEFAULT '{}',
  -- Phase D: apply 1.15x damage multiplier to abilities used by characters
  -- whose archetype appears in affinity_archetypes.
  -- RIVE HOOK: map_id will be used in Phase C to select the background animation asset.
  background_rive_key   TEXT,
  active                BOOLEAN     DEFAULT TRUE,
  created_at            TIMESTAMPTZ DEFAULT NOW()
);

-- Type effectiveness chart: fully data-driven.
-- Rebalancing = SQL UPDATE only, no code deploys required.
-- Adding new archetypes = INSERT new rows for all matchups.
-- attacker_type attacking defender_type deals damage * multiplier.
-- 1.5 = super effective, 1.0 = neutral, 0.5 = resisted.
CREATE TABLE battle_type_chart (
  attacker_type   TEXT        NOT NULL,
  defender_type   TEXT        NOT NULL,
  multiplier      DECIMAL(3,2) NOT NULL DEFAULT 1.00,
  PRIMARY KEY (attacker_type, defender_type)
);

-- Ability definitions: 5 per archetype (slots 1–4 standard, slot 5 = ultimate).
-- Balance values are placeholders — tuned in Phase D using telemetry.
CREATE TABLE battle_abilities (
  id                  UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  archetype           TEXT    NOT NULL,
  name                TEXT    NOT NULL,
  description         TEXT,
  ability_slot        INTEGER NOT NULL CHECK (ability_slot BETWEEN 1 AND 5),
  ap_cost             INTEGER NOT NULL,
  -- Ultimate (slot 5) also requires momentum = 100 to activate.
  requires_momentum   BOOLEAN DEFAULT FALSE,
  base_damage         INTEGER DEFAULT 0,
  -- speed_priority: 1 = moves before normal speed order, 0 = normal, -1 = moves last.
  speed_priority      INTEGER DEFAULT 0,
  effect_type         TEXT    CHECK (effect_type IN (
    'damage', 'heal', 'buff', 'debuff', 'drain_ap',
    'momentum_boost', 'force_skip', 'copy_last', 'special'
  )),
  -- effect_value: meaning depends on effect_type.
  -- heal: HP restored; buff/debuff: stat delta; drain_ap: AP removed from target;
  -- momentum_boost: momentum added to self or ally.
  effect_value        INTEGER DEFAULT 0,
  effect_target       TEXT    CHECK (effect_target IN (
    'self', 'ally', 'opponent', 'all_opponents', 'all_allies'
  )),
  is_ultimate         BOOLEAN DEFAULT FALSE,
  -- RIVE HOOK: key used to trigger this ability's animation in the Rive state machine.
  rive_animation_key  TEXT,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (archetype, ability_slot)
);

-- Reference table: maps ability_id → rive_animation_key for Flutter controller lookup.
-- RIVE HOOK: Phase C ConsumerWidget reads this table to get animation keys at match load.
CREATE TABLE battle_rive_animation_keys (
  ability_id              UUID    PRIMARY KEY REFERENCES battle_abilities(id) ON DELETE CASCADE,
  rive_animation_key      TEXT    NOT NULL,
  -- Additional context for the Rive state machine.
  animation_duration_ms   INTEGER DEFAULT 1000,
  requires_target         BOOLEAN DEFAULT TRUE
);

-- Lobbies and matches.
CREATE TABLE battle_matches (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 6-character uppercase lobby code for sharing (e.g. 'XK4P2R').
  lobby_code              TEXT        NOT NULL UNIQUE,
  status                  TEXT        NOT NULL DEFAULT 'lobby'
      CHECK (status IN ('lobby', 'active', 'resolved', 'abandoned')),
  map_id                  UUID        REFERENCES battle_maps(id),
  host_user_id            UUID        NOT NULL REFERENCES auth.users(id),
  current_turn            INTEGER     DEFAULT 0,
  -- Deadline for all active players to submit current turn.
  -- pg_cron checks this and auto-selects for non-submitters.
  turn_deadline           TIMESTAMPTZ,
  -- Seconds allowed per turn (default 30).
  turn_duration_seconds   INTEGER     DEFAULT 30,
  winner_team_number      INTEGER     CHECK (winner_team_number IN (1, 2)),
  -- Total token pool from spectator bets — split at resolution.
  spectator_pool          INTEGER     DEFAULT 0,
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  started_at              TIMESTAMPTZ,
  resolved_at             TIMESTAMPTZ
);

-- One row per participant (6 per match, 3 per team).
-- Tracks live in-match character state.
CREATE TABLE battle_participants (
  id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id        UUID    NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  user_id         UUID    NOT NULL REFERENCES auth.users(id),
  team_number     INTEGER NOT NULL CHECK (team_number IN (1, 2)),
  -- slot_position determines lineup order (1 = starts on field, 2 and 3 = bench).
  slot_position   INTEGER NOT NULL CHECK (slot_position BETWEEN 1 AND 3),
  archetype       TEXT    NOT NULL,
  character_name  TEXT    NOT NULL,
  -- Base stats (set at match start from archetype defaults, never change).
  max_hp          INTEGER NOT NULL DEFAULT 150,
  max_ap          INTEGER NOT NULL DEFAULT 50,
  speed           INTEGER NOT NULL,
  -- Live stats (updated each turn by resolution function).
  current_hp      INTEGER NOT NULL DEFAULT 150,
  current_ap      INTEGER NOT NULL DEFAULT 50,
  -- Momentum 0–100: fills via damage dealt and type advantage hits.
  -- Ultimate (slot 5) requires momentum = 100 to activate; resets to 0 after use.
  momentum        INTEGER NOT NULL DEFAULT 0 CHECK (momentum BETWEEN 0 AND 100),
  -- is_active: currently on the field (one per team at a time).
  is_active       BOOLEAN DEFAULT FALSE,
  is_fainted      BOOLEAN DEFAULT FALSE,
  -- is_automated: player disconnected; resolution function auto-selects moves.
  -- RIVE HOOK: automated characters use idle_automated animation variant.
  is_automated    BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (match_id, user_id, slot_position),
  UNIQUE (match_id, team_number, slot_position)
);

-- Private turn submissions — NOT in Realtime publication.
-- Each active player submits one row per turn; hidden from others until resolution.
CREATE TABLE battle_turn_submissions (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id                UUID        NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  turn_number             INTEGER     NOT NULL,
  participant_id          UUID        NOT NULL REFERENCES battle_participants(id) ON DELETE CASCADE,
  user_id                 UUID        NOT NULL REFERENCES auth.users(id),
  -- Either ability_id OR swap_to_participant_id must be set, not both.
  ability_id              UUID        REFERENCES battle_abilities(id),
  swap_to_participant_id  UUID        REFERENCES battle_participants(id),
  submitted_at            TIMESTAMPTZ DEFAULT NOW(),
  was_auto_selected       BOOLEAN     DEFAULT FALSE,
  UNIQUE (match_id, turn_number, participant_id),
  CONSTRAINT must_have_action CHECK (
    (ability_id IS NOT NULL AND swap_to_participant_id IS NULL) OR
    (ability_id IS NULL AND swap_to_participant_id IS NOT NULL)
  )
);

-- Turn resolution event log — in Realtime publication.
-- Flutter UI reads this to drive animations and UI updates.
-- RIVE HOOK: Phase C reads rive_animation_key from each event row
--            and calls riveController.setInput(rive_animation_key, true).
CREATE TABLE battle_events (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id                UUID        NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  turn_number             INTEGER     NOT NULL,
  -- sequence_in_turn: order of resolution within a turn (1 = first, 2 = second, etc.).
  -- Swaps resolve before attacks; attacks resolve in speed order.
  sequence_in_turn        INTEGER     NOT NULL,
  event_type              TEXT        NOT NULL CHECK (event_type IN (
    'swap_voluntary',   -- player chose to swap
    'swap_forced',      -- character fainted, forced swap
    'ability_used',     -- standard attack or effect
    'ultimate_used',    -- slot 5 ability activated
    'ko',               -- character HP reached 0
    'momentum_gained',  -- momentum milestone reached
    'ultimate_ready',   -- momentum hit 100
    'auto_selected',    -- move was auto-selected (timeout or automated)
    'match_end'         -- game over event
  )),
  -- Who performed the action.
  actor_participant_id    UUID        REFERENCES battle_participants(id),
  -- Who was targeted.
  target_participant_id   UUID        REFERENCES battle_participants(id),
  ability_id              UUID        REFERENCES battle_abilities(id),
  -- Damage after type chart multiplier applied.
  damage_dealt            INTEGER     DEFAULT 0,
  hp_after                INTEGER,    -- target HP after this event
  ap_after                INTEGER,    -- actor AP after this event
  momentum_after          INTEGER,    -- actor momentum after this event
  type_multiplier         DECIMAL(3,2) DEFAULT 1.00,
  -- Map buff applied (always 1.0 until Phase D wires it).
  map_multiplier          DECIMAL(3,2) DEFAULT 1.00,
  -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
  --            the matching Rive state machine input for this event.
  rive_animation_key      TEXT,
  created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- Spectator bets: one bet per spectator per match.
-- Settled at match resolution (same pattern as resolve-markets).
CREATE TABLE battle_spectator_bets (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id        UUID        NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  user_id         UUID        NOT NULL REFERENCES auth.users(id),
  team_number     INTEGER     NOT NULL CHECK (team_number IN (1, 2)),
  tokens_wagered  INTEGER     NOT NULL CHECK (tokens_wagered > 0),
  status          TEXT        NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending', 'won', 'lost')),
  payout          INTEGER,
  placed_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (match_id, user_id)
);

-- Match telemetry for Phase D balance tuning.
CREATE TABLE battle_match_telemetry (
  id                      UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id                UUID    NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  turn_count              INTEGER,
  winning_archetypes      TEXT[],
  losing_archetypes       TEXT[],
  map_id                  UUID    REFERENCES battle_maps(id),
  total_damage_dealt      INTEGER,
  ultimates_used          INTEGER,
  auto_selections         INTEGER,
  match_duration_seconds  INTEGER,
  created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE battle_maps               ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_type_chart         ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_abilities          ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_rive_animation_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_matches            ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_participants       ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_turn_submissions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_events             ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_spectator_bets     ENABLE ROW LEVEL SECURITY;
ALTER TABLE battle_match_telemetry    ENABLE ROW LEVEL SECURITY;

-- Public read: maps, type chart, abilities, animation keys.
CREATE POLICY "public read battle_maps"
  ON battle_maps FOR SELECT USING (true);
CREATE POLICY "public read battle_type_chart"
  ON battle_type_chart FOR SELECT USING (true);
CREATE POLICY "public read battle_abilities"
  ON battle_abilities FOR SELECT USING (true);
CREATE POLICY "public read battle_rive_animation_keys"
  ON battle_rive_animation_keys FOR SELECT USING (true);

-- Matches: public read (spectators need to see matches).
CREATE POLICY "public read battle_matches"
  ON battle_matches FOR SELECT USING (true);

-- Participants: public read (spectators see teams).
CREATE POLICY "public read battle_participants"
  ON battle_participants FOR SELECT USING (true);

-- Turn submissions: users can only read/write their OWN submission.
-- (prevents seeing opponent moves before resolution)
CREATE POLICY "users read own battle submissions"
  ON battle_turn_submissions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "users insert own battle submissions"
  ON battle_turn_submissions FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Events: public read (spectators watch the feed).
CREATE POLICY "public read battle_events"
  ON battle_events FOR SELECT USING (true);

-- Spectator bets: users read/write their own.
CREATE POLICY "users read own battle bets"
  ON battle_spectator_bets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "users insert own battle bets"
  ON battle_spectator_bets FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Telemetry: public read for balance transparency.
CREATE POLICY "public read battle_telemetry"
  ON battle_match_telemetry FOR SELECT USING (true);

-- ============================================================
-- Realtime publication
-- battle_events and battle_matches published.
-- battle_turn_submissions deliberately excluded (private until resolution).
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE battle_events;
ALTER PUBLICATION supabase_realtime ADD TABLE battle_matches;
ALTER PUBLICATION supabase_realtime ADD TABLE battle_participants;
