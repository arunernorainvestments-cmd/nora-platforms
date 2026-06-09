-- ─────────────────────────────────────────────────────────────────────────────
-- 103 — Battle Chit framework: animation keys, targeting, caps, effect resolution
--
-- Builds out the chit collectible economy from the 086 scaffold so it is ready for
-- animation production and live use:
--   • per-chit animation_key (asset hook), requires_target, per_match_use_limit
--   • battle_chit_uses ledger (cap enforcement + telemetry + spectator animations)
--   • battle_use_chit() rewritten: integrity guard, caps, immediate + duration effects
--
-- Effect resolution strategy (see docs/battle-chits-and-arena-integrity.md §5):
--   immediate at use-time:  momentum_surge, stat_boost, aura, disruption, wild_card
--   mapped onto resolved types: damage_shield→save_state, speed_burst→speed_debuff(+)
--   deferred mechanical hook: counter, type_override (stored, animation plays, expires)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Chit definition columns ───────────────────────────────────────────────
ALTER TABLE public.battle_chit_definitions
  ADD COLUMN IF NOT EXISTS animation_key       TEXT,
  ADD COLUMN IF NOT EXISTS requires_target     BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS per_match_use_limit INTEGER;

-- Per-chit animation key (e.g. 'chit_bronze_shield') — what animation production
-- builds assets against and what the chit_used event carries.
UPDATE public.battle_chit_definitions
SET animation_key = 'chit_' || lower(regexp_replace(name, '[^a-zA-Z0-9]+', '_', 'g'))
WHERE animation_key IS NULL;

-- Targeted chits: opponent-facing effects + the wild_card swap.
UPDATE public.battle_chit_definitions
SET requires_target = TRUE
WHERE effect_target = 'opponent' OR effect_type = 'wild_card';

-- "Ultimate" tier chits — once per match.
UPDATE public.battle_chit_definitions
SET per_match_use_limit = 1
WHERE rarity IN ('legendary', 'mythic');

-- ── 2. Chit usage ledger ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.battle_chit_uses (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id              UUID NOT NULL REFERENCES battle_matches(id) ON DELETE CASCADE,
  user_id               UUID NOT NULL REFERENCES auth.users(id),
  participant_id        UUID NOT NULL REFERENCES battle_participants(id),
  chit_definition_id    UUID NOT NULL REFERENCES battle_chit_definitions(id),
  target_participant_id UUID REFERENCES battle_participants(id),
  applied_at_turn       INTEGER NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS battle_chit_uses_match_user_idx
  ON public.battle_chit_uses (match_id, user_id, chit_definition_id);

ALTER TABLE public.battle_chit_uses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "battle_chit_uses_read" ON public.battle_chit_uses;
CREATE POLICY "battle_chit_uses_read"
  ON public.battle_chit_uses FOR SELECT TO authenticated USING (TRUE);

-- ── 3. battle_use_chit() — full implementation ───────────────────────────────
-- Drop the 091 three-arg version: the new signature adds a defaulted target arg,
-- which would make a three-arg call ambiguous if both overloads existed.
DROP FUNCTION IF EXISTS public.battle_use_chit(UUID, UUID, UUID);

CREATE OR REPLACE FUNCTION public.battle_use_chit(
  p_match_id            UUID,
  p_participant_id      UUID,
  p_chit_def_id         UUID,
  p_target_participant_id UUID DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_chit        battle_chit_definitions%ROWTYPE;
  v_actor       battle_participants%ROWTYPE;
  v_target      battle_participants%ROWTYPE;
  v_user_id     UUID;
  v_turn        INTEGER;
  v_expires     INTEGER;
  v_val_int     INTEGER;
  v_used_count  INTEGER;
BEGIN
  -- 1. Caller owns this participant.
  SELECT * INTO v_actor FROM battle_participants
  WHERE id = p_participant_id AND match_id = p_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Participant not found'; END IF;
  v_user_id := v_actor.user_id;
  IF v_user_id != auth.uid() THEN RAISE EXCEPTION 'Not your participant'; END IF;

  -- 2. Integrity (defense in depth): a player holding a stake on the linked market
  --    cannot influence the match. The bets trigger (102) blocks the reverse.
  IF EXISTS (
    SELECT 1 FROM bets b
    JOIN markets m ON m.id = b.market_id
    WHERE m.battle_match_id = p_match_id
      AND m.resolution_type = 'battle_outcome'
      AND b.status = 'active'
      AND b.user_id IN (SELECT user_id FROM identity_linked_users(v_user_id))
  ) THEN
    RAISE EXCEPTION 'You hold a prediction-market stake on this match — players with a bet cannot use chits';
  END IF;

  -- 3. Load chit + match turn.
  SELECT * INTO v_chit FROM battle_chit_definitions WHERE id = p_chit_def_id AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found or inactive'; END IF;

  SELECT current_turn INTO v_turn FROM battle_matches WHERE id = p_match_id AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Match is not active'; END IF;

  -- 4. Caps: one chit per participant per turn.
  IF EXISTS (
    SELECT 1 FROM battle_chit_uses
    WHERE match_id = p_match_id AND user_id = v_user_id AND applied_at_turn = v_turn
  ) THEN
    RAISE EXCEPTION 'Only one chit may be used per turn';
  END IF;

  -- Per-chit per-match limit (e.g. legendary/mythic once per match).
  IF v_chit.per_match_use_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_used_count FROM battle_chit_uses
    WHERE match_id = p_match_id AND user_id = v_user_id AND chit_definition_id = p_chit_def_id;
    IF v_used_count >= v_chit.per_match_use_limit THEN
      RAISE EXCEPTION '% can only be used % time(s) per match', v_chit.name, v_chit.per_match_use_limit;
    END IF;
  END IF;

  -- 5. Target validation.
  IF v_chit.requires_target THEN
    IF p_target_participant_id IS NULL THEN RAISE EXCEPTION '% requires a target', v_chit.name; END IF;
    SELECT * INTO v_target FROM battle_participants
    WHERE id = p_target_participant_id AND match_id = p_match_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Target not in this match'; END IF;
    IF v_chit.effect_type = 'wild_card' THEN
      IF v_target.team_number != v_actor.team_number THEN RAISE EXCEPTION 'Wild Card targets your own bench'; END IF;
      IF v_target.is_fainted THEN RAISE EXCEPTION 'Cannot swap to a fainted character'; END IF;
    ELSIF v_target.team_number = v_actor.team_number THEN
      RAISE EXCEPTION 'This chit targets an opponent';
    END IF;
  END IF;

  -- 6. Decrement inventory.
  UPDATE user_battle_chits SET quantity = quantity - 1
  WHERE user_id = v_user_id AND chit_definition_id = p_chit_def_id AND quantity > 0;
  IF NOT FOUND THEN RAISE EXCEPTION 'No chits of this type in inventory'; END IF;

  v_val_int := COALESCE(v_chit.effect_value::INTEGER, 0);
  v_expires := GREATEST(v_turn, v_turn + COALESCE(v_chit.effect_duration_turns, 1));

  -- 7. Apply effect.
  IF v_chit.effect_type = 'momentum_surge' THEN
    UPDATE battle_participants SET momentum = LEAST(100, momentum + v_val_int)
    WHERE id = p_participant_id;

  ELSIF v_chit.effect_type = 'stat_boost' THEN
    IF v_chit.stat_target IS NULL OR v_chit.stat_target = 'all' THEN
      UPDATE battle_participants SET
        snap_power = snap_power + v_val_int, snap_charisma = snap_charisma + v_val_int,
        snap_resilience = snap_resilience + v_val_int, snap_agility = snap_agility + v_val_int,
        snap_wit = snap_wit + v_val_int, snap_influence = snap_influence + v_val_int
      WHERE id = p_participant_id;
    ELSE
      EXECUTE format('UPDATE battle_participants SET snap_%I = snap_%I + $1 WHERE id = $2',
                     v_chit.stat_target, v_chit.stat_target)
      USING v_val_int, p_participant_id;
    END IF;

  ELSIF v_chit.effect_type = 'aura' THEN
    IF v_chit.stat_target IS NULL OR v_chit.stat_target = 'all' THEN
      UPDATE battle_participants SET
        snap_power = ROUND(snap_power * v_chit.effect_value),
        snap_charisma = ROUND(snap_charisma * v_chit.effect_value),
        snap_resilience = ROUND(snap_resilience * v_chit.effect_value),
        snap_agility = ROUND(snap_agility * v_chit.effect_value),
        snap_wit = ROUND(snap_wit * v_chit.effect_value),
        snap_influence = ROUND(snap_influence * v_chit.effect_value)
      WHERE id = p_participant_id;
    ELSE
      EXECUTE format('UPDATE battle_participants SET snap_%I = ROUND(snap_%I * $1) WHERE id = $2',
                     v_chit.stat_target, v_chit.stat_target)
      USING v_chit.effect_value, p_participant_id;
    END IF;

  ELSIF v_chit.effect_type = 'disruption' THEN
    -- Remove one random active effect from the target opponent.
    DELETE FROM battle_participant_status_effects
    WHERE id = (
      SELECT id FROM battle_participant_status_effects
      WHERE match_id = p_match_id AND participant_id = p_target_participant_id
        AND consumed = FALSE AND expires_at_turn >= v_turn
      ORDER BY random() LIMIT 1
    );

  ELSIF v_chit.effect_type = 'wild_card' THEN
    -- Immediate swap to the chosen bench ally, bypassing normal swap rules.
    UPDATE battle_participants SET is_active = FALSE
    WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_active = TRUE;
    UPDATE battle_participants SET is_active = TRUE WHERE id = p_target_participant_id;

  ELSIF v_chit.effect_type = 'damage_shield' THEN
    -- v1: mapped onto save_state (blocks an incoming hit <= shield value).
    INSERT INTO battle_participant_status_effects (
      match_id, participant_id, applied_by_participant_id,
      effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
    VALUES (p_match_id, p_participant_id, p_participant_id,
      'save_state', v_val_int, v_turn, v_expires, 'chit_damage_shield');

  ELSIF v_chit.effect_type = 'speed_burst' THEN
    -- Stored as a positive speed_debuff so the turn-order CTE sums it as a boost.
    INSERT INTO battle_participant_status_effects (
      match_id, participant_id, applied_by_participant_id,
      effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
    VALUES (p_match_id, p_participant_id, p_participant_id,
      'speed_debuff', v_val_int, v_turn, v_expires, 'chit_speed_burst');

  ELSE
    -- counter, type_override: stored under their own type. process_battle_turn does
    -- not yet consume these (deferred hook, §6); the chit_used animation still plays.
    INSERT INTO battle_participant_status_effects (
      match_id, participant_id, applied_by_participant_id,
      effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
    VALUES (p_match_id, p_participant_id, p_participant_id,
      v_chit.effect_type, v_val_int, v_turn, v_expires, 'chit_' || v_chit.effect_type);
  END IF;

  -- 8. Ledger + event (animation hook).
  INSERT INTO battle_chit_uses (
    match_id, user_id, participant_id, chit_definition_id, target_participant_id, applied_at_turn)
  VALUES (p_match_id, v_user_id, p_participant_id, p_chit_def_id, p_target_participant_id, v_turn);

  INSERT INTO battle_events (
    match_id, turn_number, sequence_in_turn,
    event_type, actor_participant_id, target_participant_id, chit_id, animation_key)
  VALUES (p_match_id, v_turn, 999, 'chit_used', p_participant_id, p_target_participant_id,
          p_chit_def_id, COALESCE(v_chit.animation_key, 'chit_' || v_chit.effect_type));
END;
$$;
