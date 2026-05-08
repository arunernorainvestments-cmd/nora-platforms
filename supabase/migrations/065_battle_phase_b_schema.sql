-- Migration 065: Battle Mode Phase B — Schema Additions
-- Adds last_seen_at to battle_participants, creates battle_participant_status_effects,
-- and adds status_effects_applied to battle_match_telemetry.
-- Does NOT modify any Phase A migration files.

-- ============================================================
-- 1. Heartbeat column on battle_participants
-- ============================================================
-- Client updates this every 30 seconds while in an active match.
-- pg_cron presence check flips is_automated=TRUE when this goes stale.
ALTER TABLE battle_participants
  ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ DEFAULT NOW();

-- ============================================================
-- 2. Status effects tracking for Phase B abilities
-- ============================================================
-- Tracks temporary per-turn buffs and debuffs applied by abilities.
-- A participant can have multiple active effects simultaneously.
-- Effects expire at expires_at_turn (inclusive — active during that turn,
-- deleted at start of expires_at_turn+1).
-- consumed=TRUE: effect was triggered this turn; cleaned at next turn start.
CREATE TABLE battle_participant_status_effects (
  id                        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id                  UUID        NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  participant_id            UUID        NOT NULL REFERENCES battle_participants(id) ON DELETE CASCADE,
  -- Who applied the effect (for display and audit).
  applied_by_participant_id UUID        REFERENCES battle_participants(id),
  effect_type               TEXT        NOT NULL CHECK (effect_type IN (
    'speed_debuff',     -- Comedian Crowd Control: speed reduced next turn
    'force_skip',       -- Politician Executive Order: skip next action
    'save_state',       -- Gamer Save State: block next hit below threshold
    'double_damage',    -- Actor Award Season: next damage ability deals 2x
    'type_reversed',    -- Scientist Paradigm Shift: type multipliers inverted
    'forced_ability',   -- Influencer #1 Trending: must use lowest-damage ability
    'encore',           -- Musician Encore: repeat last ability used
    'momentum_locked'   -- Future use
  )),
  -- Meaning varies by effect_type:
  -- speed_debuff: negative speed delta applied to effective_speed (e.g. -15)
  -- save_state: max damage threshold blocked (e.g. 30)
  -- double_damage: stored as integer multiplier (2 = 2x)
  -- force_skip, type_reversed, encore, forced_ability: effect_value unused (0)
  effect_value              INTEGER     DEFAULT 0,
  applied_at_turn           INTEGER     NOT NULL,
  -- Effect is active during turns up to and including expires_at_turn.
  -- Standard 1-turn effect: expires_at_turn = applied_at_turn + 1.
  -- Deleted at start of the turn AFTER expires_at_turn.
  expires_at_turn           INTEGER     NOT NULL,
  -- consumed=TRUE: effect was triggered; cleaned at next turn start.
  -- Distinguishes "used this turn" from "expired without being triggered".
  consumed                  BOOLEAN     DEFAULT FALSE,
  -- RIVE HOOK: Phase C displays active status effect badges using this key.
  rive_indicator_key        TEXT,
  created_at                TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE battle_participant_status_effects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public read battle status effects"
  ON battle_participant_status_effects FOR SELECT USING (true);

-- Add to Realtime so Phase C can show live effect badges.
ALTER PUBLICATION supabase_realtime ADD TABLE battle_participant_status_effects;

-- ============================================================
-- 3. Telemetry: status effects count column
-- ============================================================
ALTER TABLE battle_match_telemetry
  ADD COLUMN IF NOT EXISTS status_effects_applied INTEGER DEFAULT 0;
