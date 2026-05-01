-- Migration 032: Arena ability config table + Athlete archetype seed
-- Abilities are data, not code. The tick loop reads this table generically.
-- Adding a new archetype in Phase C = inserting rows here only.

CREATE TABLE public.arena_abilities (
  id               text        PRIMARY KEY,
  archetype        text        NOT NULL,
  ability_type     text        NOT NULL
                               CHECK (ability_type IN ('passive', 'core', 'signature', 'ultimate')),
  display_name     text        NOT NULL,
  description      text        NOT NULL,
  icon             text,
  cooldown_seconds integer     NOT NULL,
  duration_seconds integer     NOT NULL,
  token_cost       integer     NOT NULL,
  target           text        NOT NULL
                               CHECK (target IN ('self', 'opponent', 'both')),
  modifier         text        NOT NULL
                               CHECK (modifier IN (
                                 'flow_rate_multiplier',
                                 'heat_influence_multiplier',
                                 'ability_effectiveness',
                                 'opponent_efficiency',
                                 'momentum_window',
                                 'suppression_level'
                               )),
  modifier_value   numeric     NOT NULL,
  trigger_window   text,
  metadata         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.arena_abilities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_abilities: authenticated read"
  ON public.arena_abilities FOR SELECT TO authenticated USING (true);

-- ── Athlete archetype seed ────────────────────────────────────────────────────
-- Token costs (starting values — balance after Phase C testing):
--   Core:       25 T
--   Signature: 100 T
--   Ultimate:  500 T
--
-- Conditioning: passive — cannot be manually triggered. Tick loop injects it
--   into active_effects each tick based on elapsed match time.
--   modifier_value=1.0 is a placeholder; actual value is computed dynamically
--   as (1.0 + LEAST(elapsed_secs/10 * ramp_per_10s, cap)).
--
-- Stacking formula (all trigger effects): Base × (1 + ln(1 + N))
--   where Base = geometric mean of all active modifier values (same modifier, same target),
--   N = count of trigger instances (passives are multiplied in separately).
--
-- opponent_efficiency: debuff on target player; stacking is multiplicative
--   with a 0.4 floor (max 60% suppression). Separate from the log-stacking formula.

INSERT INTO public.arena_abilities
  (id, archetype, ability_type, display_name, description, icon,
   cooldown_seconds, duration_seconds, token_cost, target, modifier, modifier_value,
   trigger_window, metadata)
VALUES
  (
    'athlete:conditioning', 'athlete', 'passive', 'Conditioning',
    'Gradual ramp: +0.5% flow rate per 10 s active, capped at +15%',
    'fitness_center',
    0, 0, 0,
    'self', 'flow_rate_multiplier', 1.0,
    NULL,
    '{"ramp_per_10s": 0.005, "cap": 0.15}'::jsonb
  ),
  (
    'athlete:sprint', 'athlete', 'core', 'Sprint',
    '8 seconds of +35% flow rate base',
    'directions_run',
    45, 8, 25,
    'self', 'flow_rate_multiplier', 1.35,
    NULL,
    '{}'::jsonb
  ),
  (
    'athlete:defense', 'athlete', 'core', 'Defense',
    '10 seconds of -20% opponent efficiency',
    'shield',
    45, 10, 25,
    'opponent', 'opponent_efficiency', 0.8,
    NULL,
    '{}'::jsonb
  ),
  (
    'athlete:clutch_play', 'athlete', 'signature', 'Clutch Play',
    '+75% flow rate; only usable in the final 20 seconds',
    'sports_score',
    180, 20, 100,
    'self', 'flow_rate_multiplier', 1.75,
    'last_20_seconds',
    '{}'::jsonb
  ),
  (
    'athlete:game_winner', 'athlete', 'ultimate', 'Game Winner',
    '5 seconds of +150% flow rate and momentum window; once per match',
    'emoji_events',
    999999, 5, 500,
    'self', 'flow_rate_multiplier', 2.5,
    NULL,
    '{"also_sets": {"momentum_window": true}}'::jsonb
  );
