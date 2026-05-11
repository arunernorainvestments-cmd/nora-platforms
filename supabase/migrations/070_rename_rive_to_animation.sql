-- Migration 070: Rename legacy Rive columns to animation-agnostic names
--
-- The animation stack changed from Rive to Flame (characters) + Lottie (effects).
-- The rive package was never added to pubspec.yaml — no Flutter removal needed.
-- This migration renames all Rive-specific column and table names before Phase C
-- Flutter integration begins.
--
-- Affected schema:
--   battle_rive_animation_keys  → battle_animation_keys (table)
--   battle_abilities.rive_animation_key  → animation_key
--   battle_events.rive_animation_key     → animation_key
--   battle_participant_status_effects.rive_indicator_key → indicator_key
--   battle_maps.background_rive_key      → background_key
--
-- Affected functions (CREATE OR REPLACE to match renamed columns):
--   process_battle_turn   (migration 069 version)
--   battle_forfeit        (migration 066 version)

-- ============================================================
-- 1. TABLE RENAME
-- ============================================================
ALTER TABLE battle_rive_animation_keys
  RENAME TO battle_animation_keys;

ALTER POLICY "public read battle_rive_animation_keys"
  ON battle_animation_keys
  RENAME TO "public read battle_animation_keys";

-- ============================================================
-- 2. COLUMN RENAMES
-- ============================================================
ALTER TABLE battle_abilities
  RENAME COLUMN rive_animation_key TO animation_key;

ALTER TABLE battle_events
  RENAME COLUMN rive_animation_key TO animation_key;

ALTER TABLE battle_participant_status_effects
  RENAME COLUMN rive_indicator_key TO indicator_key;

ALTER TABLE battle_maps
  RENAME COLUMN background_rive_key TO background_key;

-- Also rename the reference column inside battle_animation_keys itself
ALTER TABLE battle_animation_keys
  RENAME COLUMN rive_animation_key TO animation_key;

-- ============================================================
-- 3. REPLACE process_battle_turn (migration 069 body, updated)
-- ============================================================
CREATE OR REPLACE FUNCTION process_battle_turn(p_match_id UUID)
RETURNS VOID AS $$
DECLARE
  v_match          battle_matches%ROWTYPE;
  v_turn           INTEGER;
  v_seq            INTEGER := 0;
  v_effects_applied INTEGER := 0;
  v_submission     RECORD;
  v_actor          battle_participants%ROWTYPE;
  v_target         battle_participants%ROWTYPE;
  v_ability        battle_abilities%ROWTYPE;
  v_participant    battle_participants%ROWTYPE;
  v_effect         battle_participant_status_effects%ROWTYPE;
  v_last_ability   battle_abilities%ROWTYPE;
  v_type_mult      DECIMAL(3,2);
  v_damage         INTEGER;
  v_momentum_gain  INTEGER;
  v_animation_key  TEXT;
  v_winner_team    INTEGER;
  v_team1_alive    INTEGER;
  v_team2_alive    INTEGER;
  v_total_effects  INTEGER := 0;
BEGIN

  -- 1. GUARD: load match
  SELECT * INTO v_match
  FROM battle_matches
  WHERE id = p_match_id AND status = 'active';

  IF v_match.id IS NULL THEN RETURN; END IF;

  v_turn := v_match.current_turn;

  -- 2. GUARD: require participants on both teams.
  IF NOT EXISTS (SELECT 1 FROM battle_participants WHERE match_id = p_match_id AND team_number = 1)
  OR NOT EXISTS (SELECT 1 FROM battle_participants WHERE match_id = p_match_id AND team_number = 2) THEN
    RETURN;
  END IF;

  -- 3. EXPIRE status effects
  DELETE FROM battle_participant_status_effects
  WHERE match_id = p_match_id
    AND (expires_at_turn < v_turn OR consumed = TRUE);

  -- 4. GUARD: wait unless all active players submitted OR deadline passed.
  IF NOT (
    NOW() > v_match.turn_deadline
    OR NOT EXISTS (
      SELECT 1
      FROM battle_participants bp
      WHERE bp.match_id   = p_match_id
        AND bp.is_active  = TRUE
        AND bp.is_fainted = FALSE
        AND NOT EXISTS (
          SELECT 1 FROM battle_turn_submissions bts
          WHERE bts.match_id      = p_match_id
            AND bts.turn_number   = v_turn
            AND bts.participant_id = bp.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM battle_participant_status_effects bpse
          WHERE bpse.participant_id = bp.id
            AND bpse.effect_type   = 'force_skip'
            AND bpse.consumed      = FALSE
        )
    )
  ) THEN
    RETURN;
  END IF;

  -- 5. HANDLE FORCE_SKIP non-submitters
  FOR v_participant IN
    SELECT bp.*
    FROM battle_participants bp
    WHERE bp.match_id   = p_match_id
      AND bp.is_active  = TRUE
      AND bp.is_fainted = FALSE
      AND NOT EXISTS (
        SELECT 1 FROM battle_turn_submissions bts
        WHERE bts.match_id      = p_match_id
          AND bts.turn_number   = v_turn
          AND bts.participant_id = bp.id
      )
      AND EXISTS (
        SELECT 1 FROM battle_participant_status_effects bpse
        WHERE bpse.participant_id = bp.id
          AND bpse.effect_type   = 'force_skip'
          AND bpse.consumed      = FALSE
      )
  LOOP
    UPDATE battle_participant_status_effects
    SET consumed = TRUE
    WHERE participant_id = v_participant.id
      AND effect_type    = 'force_skip'
      AND consumed       = FALSE;

    v_seq := v_seq + 1;
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'auto_selected',
      v_participant.id, 'force_skip_applied'
    );
  END LOOP;

  -- 6. AUTO-SELECT with status effect overrides
  FOR v_participant IN
    SELECT bp.*
    FROM battle_participants bp
    WHERE bp.match_id   = p_match_id
      AND bp.is_active  = TRUE
      AND bp.is_fainted = FALSE
      AND NOT EXISTS (
        SELECT 1 FROM battle_turn_submissions bts
        WHERE bts.match_id       = p_match_id
          AND bts.turn_number    = v_turn
          AND bts.participant_id = bp.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM battle_participant_status_effects bpse
        WHERE bpse.participant_id = bp.id
          AND bpse.effect_type   = 'force_skip'
      )
  LOOP
    -- a. Forced ability
    SELECT * INTO v_effect
    FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id AND effect_type = 'forced_ability' AND consumed = FALSE
    LIMIT 1;

    IF v_effect.id IS NOT NULL THEN
      INSERT INTO battle_turn_submissions
        (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
      SELECT p_match_id, v_turn, v_participant.id, v_participant.user_id,
        (SELECT ba.id FROM battle_abilities ba
         WHERE ba.archetype = v_participant.archetype
           AND v_participant.current_ap >= ba.ap_cost
           AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
         ORDER BY ba.base_damage ASC LIMIT 1), TRUE
      ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      CONTINUE;
    END IF;

    -- b. Encore
    SELECT * INTO v_effect
    FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id AND effect_type = 'encore' AND consumed = FALSE
    LIMIT 1;

    IF v_effect.id IS NOT NULL THEN
      SELECT ba.* INTO v_last_ability
      FROM battle_events be
      JOIN battle_abilities ba ON ba.id = be.ability_id
      WHERE be.match_id = p_match_id AND be.actor_participant_id = v_participant.id
        AND be.event_type IN ('ability_used', 'ultimate_used') AND be.ability_id IS NOT NULL
      ORDER BY be.created_at DESC LIMIT 1;

      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;

      IF v_last_ability.id IS NOT NULL AND v_participant.current_ap >= v_last_ability.ap_cost THEN
        INSERT INTO battle_turn_submissions
          (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
        VALUES (p_match_id, v_turn, v_participant.id, v_participant.user_id, v_last_ability.id, TRUE)
        ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
        CONTINUE;
      END IF;
    END IF;

    -- c. Standard auto-select
    INSERT INTO battle_turn_submissions
      (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
    SELECT p_match_id, v_turn, v_participant.id, v_participant.user_id,
      (SELECT ba.id FROM battle_abilities ba
       WHERE ba.archetype = v_participant.archetype
         AND v_participant.current_ap >= ba.ap_cost
         AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
       ORDER BY ba.base_damage DESC LIMIT 1), TRUE
    ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
  END LOOP;

  -- 7. AP REGENERATION
  UPDATE battle_participants
  SET current_ap = LEAST(max_ap, current_ap + 5)
  WHERE match_id = p_match_id AND is_fainted = FALSE;

  -- 8. PHASE 1: Voluntary swaps
  FOR v_submission IN
    SELECT bts.*, bp.team_number AS actor_team
    FROM battle_turn_submissions bts
    JOIN battle_participants bp ON bp.id = bts.participant_id
    WHERE bts.match_id = p_match_id AND bts.turn_number = v_turn AND bts.swap_to_participant_id IS NOT NULL
    ORDER BY bp.speed DESC
  LOOP
    v_seq := v_seq + 1;
    SELECT * INTO v_actor  FROM battle_participants WHERE id = v_submission.participant_id;
    SELECT * INTO v_target FROM battle_participants WHERE id = v_submission.swap_to_participant_id;
    UPDATE battle_participants SET is_active = FALSE WHERE id = v_actor.id;
    UPDATE battle_participants SET is_active = TRUE  WHERE id = v_target.id;
    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, target_participant_id, animation_key)
    VALUES (p_match_id, v_turn, v_seq, 'swap_voluntary', v_actor.id, v_target.id, 'swap_voluntary');
  END LOOP;

  -- 9. PHASE 2: Attacks with speed debuff adjustments
  FOR v_submission IN
    WITH speed_debuffs AS (
      SELECT participant_id, COALESCE(SUM(effect_value), 0) AS speed_delta
      FROM battle_participant_status_effects
      WHERE match_id = p_match_id AND effect_type = 'speed_debuff' AND consumed = FALSE
      GROUP BY participant_id
    )
    SELECT bts.*,
      bp.speed + (ba.speed_priority * 1000) + COALESCE(sd.speed_delta, 0) AS effective_speed,
      bp.archetype AS actor_archetype, bp.team_number AS actor_team
    FROM battle_turn_submissions bts
    JOIN battle_participants bp ON bp.id = bts.participant_id
    JOIN battle_abilities    ba ON ba.id = bts.ability_id
    LEFT JOIN speed_debuffs  sd ON sd.participant_id = bts.participant_id
    WHERE bts.match_id = p_match_id AND bts.turn_number = v_turn AND bts.ability_id IS NOT NULL
    ORDER BY (bp.speed + (ba.speed_priority * 1000) + COALESCE(sd.speed_delta, 0)) DESC, RANDOM()
  LOOP
    v_seq := v_seq + 1;
    SELECT * INTO v_actor FROM battle_participants WHERE id = v_submission.participant_id;
    IF v_actor.is_fainted THEN CONTINUE; END IF;
    SELECT * INTO v_ability FROM battle_abilities WHERE id = v_submission.ability_id;

    -- Force_skip check for manual submitters
    SELECT * INTO v_effect FROM battle_participant_status_effects
    WHERE participant_id = v_actor.id AND effect_type = 'force_skip' AND consumed = FALSE LIMIT 1;
    IF v_effect.id IS NOT NULL THEN
      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      v_seq := v_seq + 1;
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, animation_key)
      VALUES (p_match_id, v_turn, v_seq, 'auto_selected', v_actor.id, 'force_skip_applied');
      CONTINUE;
    END IF;

    UPDATE battle_participants SET current_ap = current_ap - v_ability.ap_cost WHERE id = v_actor.id;
    IF v_ability.is_ultimate THEN UPDATE battle_participants SET momentum = 0 WHERE id = v_actor.id; END IF;

    SELECT * INTO v_target FROM battle_participants
    WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_active = TRUE AND is_fainted = FALSE
    LIMIT 1;

    IF v_target.id IS NULL THEN
      v_type_mult := 1.00; v_damage := 0;
    ELSE
      SELECT multiplier INTO v_type_mult FROM battle_type_chart
      WHERE attacker_type = v_actor.archetype AND defender_type = v_target.archetype;
      v_type_mult := COALESCE(v_type_mult, 1.00);

      -- Type reversed
      SELECT * INTO v_effect FROM battle_participant_status_effects
      WHERE participant_id = v_actor.id AND effect_type = 'type_reversed' AND consumed = FALSE LIMIT 1;
      IF v_effect.id IS NOT NULL THEN
        v_type_mult := CASE WHEN v_type_mult = 1.50 THEN 0.50 WHEN v_type_mult = 0.50 THEN 1.50 ELSE 1.00 END;
        UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      END IF;

      -- Magnum Opus: resistance floor
      IF v_ability.animation_key = 'artist_ultimate' THEN v_type_mult := GREATEST(v_type_mult, 1.00); END IF;

      v_damage         := ROUND(v_ability.base_damage * v_type_mult);
      v_animation_key  := v_ability.animation_key;

      -- Save State
      SELECT * INTO v_effect FROM battle_participant_status_effects
      WHERE participant_id = v_target.id AND effect_type = 'save_state' AND consumed = FALSE LIMIT 1;
      IF v_effect.id IS NOT NULL AND v_damage > 0 AND v_damage < v_effect.effect_value THEN
        v_damage        := 0;
        v_animation_key := 'save_state_blocked';
        UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      END IF;

      -- Double damage
      IF v_damage > 0 THEN
        SELECT * INTO v_effect FROM battle_participant_status_effects
        WHERE participant_id = v_actor.id AND effect_type = 'double_damage' AND consumed = FALSE LIMIT 1;
        IF v_effect.id IS NOT NULL THEN
          v_damage        := v_damage * v_effect.effect_value;
          v_animation_key := v_animation_key || '_powered';
          UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
        END IF;
      END IF;

      IF v_damage > 0 THEN
        UPDATE battle_participants SET current_hp = GREATEST(0, current_hp - v_damage) WHERE id = v_target.id;
      END IF;
    END IF;

    v_momentum_gain := 10;
    IF v_type_mult >= 1.50 THEN v_momentum_gain := v_momentum_gain + 25; END IF;
    UPDATE battle_participants SET momentum = LEAST(100, momentum + v_momentum_gain) WHERE id = v_actor.id;

    -- Non-damage effects
    IF v_ability.effect_type = 'heal' THEN
      IF v_ability.effect_target = 'all_allies' THEN
        UPDATE battle_participants SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_fainted = FALSE;
      ELSE
        UPDATE battle_participants SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE id = v_actor.id;
      END IF;
    ELSIF v_ability.effect_type = 'drain_ap' THEN
      IF v_target.id IS NOT NULL AND v_ability.effect_target IN ('opponent', 'all_opponents') THEN
        UPDATE battle_participants SET current_ap = GREATEST(0, current_ap - v_ability.effect_value)
        WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_fainted = FALSE;
      END IF;
    ELSIF v_ability.effect_type = 'momentum_boost' THEN
      IF v_ability.effect_target IN ('self', 'ally', 'all_allies') THEN
        UPDATE battle_participants SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_fainted = FALSE;
      ELSIF v_ability.effect_target IN ('opponent', 'all_opponents') THEN
        UPDATE battle_participants SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_fainted = FALSE;
      END IF;
    ELSIF v_ability.effect_type = 'debuff' THEN
      IF v_target.id IS NOT NULL THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_target.id, v_actor.id, 'speed_debuff', v_ability.effect_value, v_turn, v_turn + 1, 'status_speed_debuff');
        v_effects_applied := v_effects_applied + 1;
      END IF;
    ELSIF v_ability.effect_type = 'force_skip' THEN
      IF v_target.id IS NOT NULL THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_target.id, v_actor.id, 'force_skip', 0, v_turn, v_turn + 1, 'status_force_skip');
        v_effects_applied := v_effects_applied + 1;
      END IF;
    ELSIF v_ability.effect_type = 'special' THEN
      IF v_ability.animation_key = 'scientist_hypothesis' THEN
        DECLARE v_opp_sub RECORD;
        BEGIN
          SELECT bts.ability_id, ba.effect_type AS move_category INTO v_opp_sub
          FROM battle_turn_submissions bts JOIN battle_abilities ba ON ba.id = bts.ability_id
          WHERE bts.match_id = p_match_id AND bts.turn_number = v_turn AND bts.participant_id != v_actor.id
            AND bts.participant_id IN (SELECT id FROM battle_participants WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_active = TRUE)
          LIMIT 1;
          IF v_opp_sub.ability_id IS NOT NULL THEN
            v_seq := v_seq + 1;
            INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, target_participant_id, animation_key)
            VALUES (p_match_id, v_turn, v_seq, 'ability_used', v_actor.id, v_target.id, 'hypothesis_reveal_' || COALESCE(v_opp_sub.move_category, 'unknown'));
          END IF;
        END;
      ELSIF v_ability.animation_key = 'scientist_ultimate' THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id, effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_actor.id, v_actor.id, 'type_reversed', 0, v_turn, v_turn + 1, 'status_type_reversed');
        v_effects_applied := v_effects_applied + 1;
      ELSIF v_ability.animation_key = 'influencer_ultimate' THEN
        IF v_target.id IS NOT NULL THEN
          INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id, effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
          VALUES (p_match_id, v_target.id, v_actor.id, 'forced_ability', 0, v_turn, v_turn + 1, 'status_forced_ability');
          v_effects_applied := v_effects_applied + 1;
        END IF;
      ELSIF v_ability.animation_key = 'gamer_save_state' THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id, effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_actor.id, v_actor.id, 'save_state', v_ability.effect_value, v_turn, v_turn + 1, 'status_save_state');
        v_effects_applied := v_effects_applied + 1;
      ELSIF v_ability.animation_key = 'actor_directors_cut' THEN
        IF v_target.id IS NOT NULL THEN
          SELECT ba.* INTO v_last_ability FROM battle_events be JOIN battle_abilities ba ON ba.id = be.ability_id
          WHERE be.match_id = p_match_id AND be.actor_participant_id = v_target.id
            AND be.event_type IN ('ability_used', 'ultimate_used') AND be.ability_id IS NOT NULL
          ORDER BY be.created_at DESC LIMIT 1;
          IF v_last_ability.id IS NOT NULL THEN
            DECLARE v_copy_type_mult DECIMAL(3,2); v_copy_damage INTEGER; v_copy_target battle_participants%ROWTYPE;
            BEGIN
              SELECT multiplier INTO v_copy_type_mult FROM battle_type_chart WHERE attacker_type = v_actor.archetype AND defender_type = v_target.archetype;
              v_copy_type_mult := COALESCE(v_copy_type_mult, 1.00);
              v_copy_damage := ROUND(v_last_ability.base_damage * v_copy_type_mult);
              IF v_copy_damage > 0 THEN UPDATE battle_participants SET current_hp = GREATEST(0, current_hp - v_copy_damage) WHERE id = v_target.id; END IF;
              v_seq := v_seq + 1;
              INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, target_participant_id, ability_id, damage_dealt, type_multiplier, map_multiplier, animation_key)
              VALUES (p_match_id, v_turn, v_seq, 'ability_used', v_actor.id, v_target.id, v_last_ability.id, v_copy_damage, v_copy_type_mult, 1.00, 'directors_cut_' || COALESCE(v_last_ability.animation_key, 'unknown'));
              SELECT * INTO v_copy_target FROM battle_participants WHERE id = v_target.id;
              IF v_copy_target.current_hp <= 0 THEN
                UPDATE battle_participants SET is_fainted = TRUE, is_active = FALSE WHERE id = v_target.id;
                v_seq := v_seq + 1;
                INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, target_participant_id, animation_key)
                VALUES (p_match_id, v_turn, v_seq, 'ko', v_actor.id, v_target.id, 'ko_faint');
                DECLARE v_next_bench battle_participants%ROWTYPE;
                BEGIN
                  SELECT * INTO v_next_bench FROM battle_participants WHERE match_id = p_match_id AND team_number = v_target.team_number AND is_fainted = FALSE AND is_active = FALSE ORDER BY slot_position ASC LIMIT 1;
                  IF v_next_bench.id IS NOT NULL THEN
                    UPDATE battle_participants SET is_active = TRUE WHERE id = v_next_bench.id;
                    v_seq := v_seq + 1;
                    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, target_participant_id, animation_key)
                    VALUES (p_match_id, v_turn, v_seq, 'swap_forced', v_target.id, v_next_bench.id, 'swap_forced');
                  END IF;
                END;
              END IF;
            END;
          END IF;
        END IF;
      ELSIF v_ability.animation_key = 'actor_ultimate' THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id, effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_actor.id, v_actor.id, 'double_damage', 2, v_turn, v_turn + 2, 'status_double_damage');
        v_effects_applied := v_effects_applied + 1;
      ELSIF v_ability.animation_key = 'musician_ultimate' THEN
        INSERT INTO battle_participant_status_effects (match_id, participant_id, applied_by_participant_id, effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
        VALUES (p_match_id, v_actor.id, v_actor.id, 'encore', 0, v_turn, v_turn + 1, 'status_encore');
        v_effects_applied := v_effects_applied + 1;
      ELSIF v_ability.animation_key = 'gamer_ultimate' THEN
        IF v_target.id IS NOT NULL THEN UPDATE battle_participants SET current_ap = GREATEST(0, current_ap - v_ability.effect_value) WHERE id = v_target.id; END IF;
      ELSIF v_ability.animation_key = 'business_ultimate' THEN
        IF v_target.id IS NOT NULL THEN UPDATE battle_participants SET current_ap = GREATEST(0, current_ap - v_ability.effect_value) WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_fainted = FALSE; END IF;
      ELSIF v_ability.animation_key = 'politician_ultimate' THEN
        UPDATE battle_participants SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value) WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_fainted = FALSE;
      ELSIF v_ability.animation_key = 'athlete_ultimate' THEN
        UPDATE battle_participants SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value)) WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_fainted = FALSE;
      ELSIF v_ability.animation_key = 'comedian_ultimate' THEN
        UPDATE battle_participants SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value)) WHERE match_id = p_match_id AND team_number != v_actor.team_number AND is_fainted = FALSE;
      ELSIF v_ability.animation_key = 'influencer_going_live' THEN
        UPDATE battle_participants SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value)) WHERE id = v_actor.id;
      ELSE NULL;
      END IF;
    END IF;

    SELECT * INTO v_actor FROM battle_participants WHERE id = v_actor.id;
    IF v_target.id IS NOT NULL THEN SELECT * INTO v_target FROM battle_participants WHERE id = v_target.id; END IF;
    IF v_animation_key IS NULL THEN v_animation_key := v_ability.animation_key; END IF;

    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, target_participant_id, ability_id, damage_dealt, hp_after, ap_after, momentum_after,
      type_multiplier, map_multiplier, animation_key)
    VALUES (p_match_id, v_turn, v_seq,
      CASE WHEN v_ability.is_ultimate THEN 'ultimate_used' ELSE 'ability_used' END,
      v_actor.id, v_target.id, v_ability.id, v_damage,
      CASE WHEN v_target.id IS NOT NULL THEN v_target.current_hp ELSE NULL END,
      v_actor.current_ap, v_actor.momentum, v_type_mult, 1.00, v_animation_key);

    v_animation_key := NULL;

    IF v_submission.was_auto_selected THEN
      v_seq := v_seq + 1;
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, animation_key)
      VALUES (p_match_id, v_turn, v_seq, 'auto_selected', v_actor.id,
        CASE WHEN v_actor.is_automated THEN 'player_disconnected' ELSE 'auto_selected' END);
    END IF;

    IF v_target.id IS NOT NULL AND v_target.current_hp <= 0 THEN
      UPDATE battle_participants SET is_fainted = TRUE, is_active = FALSE WHERE id = v_target.id;
      v_seq := v_seq + 1;
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, target_participant_id, animation_key)
      VALUES (p_match_id, v_turn, v_seq, 'ko', v_actor.id, v_target.id, 'ko_faint');
      DECLARE v_next_bench battle_participants%ROWTYPE;
      BEGIN
        SELECT * INTO v_next_bench FROM battle_participants
        WHERE match_id = p_match_id AND team_number = v_target.team_number AND is_fainted = FALSE AND is_active = FALSE
        ORDER BY slot_position ASC LIMIT 1;
        IF v_next_bench.id IS NOT NULL THEN
          UPDATE battle_participants SET is_active = TRUE WHERE id = v_next_bench.id;
          v_seq := v_seq + 1;
          INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
            actor_participant_id, target_participant_id, animation_key)
          VALUES (p_match_id, v_turn, v_seq, 'swap_forced', v_target.id, v_next_bench.id, 'swap_forced');
        END IF;
      END;
    END IF;

    IF v_actor.momentum = 100 AND NOT v_ability.is_ultimate THEN
      v_seq := v_seq + 1;
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, animation_key)
      VALUES (p_match_id, v_turn, v_seq, 'ultimate_ready', v_actor.id, 'ultimate_ready');
    END IF;

    v_total_effects := v_total_effects + v_effects_applied;
    v_effects_applied := 0;

  END LOOP;

  -- 10. WIN CONDITION
  SELECT COUNT(*) INTO v_team1_alive FROM battle_participants WHERE match_id = p_match_id AND team_number = 1 AND is_fainted = FALSE;
  SELECT COUNT(*) INTO v_team2_alive FROM battle_participants WHERE match_id = p_match_id AND team_number = 2 AND is_fainted = FALSE;

  IF v_team1_alive = 0 OR v_team2_alive = 0 THEN
    v_winner_team := CASE WHEN v_team1_alive > 0 THEN 1 ELSE 2 END;

    DECLARE v_bet RECORD; v_winner_count INTEGER; v_total_pool INTEGER; v_winner_payout INTEGER;
    BEGIN
      SELECT COUNT(*) INTO v_winner_count FROM battle_spectator_bets WHERE match_id = p_match_id AND team_number = v_winner_team AND status = 'pending';
      SELECT spectator_pool INTO v_total_pool FROM battle_matches WHERE id = p_match_id;
      IF v_winner_count > 0 AND COALESCE(v_total_pool, 0) > 0 THEN
        v_winner_payout := FLOOR((v_total_pool * 0.90) / v_winner_count)::INTEGER;
        FOR v_bet IN SELECT * FROM battle_spectator_bets WHERE match_id = p_match_id AND team_number = v_winner_team AND status = 'pending' LOOP
          UPDATE token_balances SET available_tokens = available_tokens + v_winner_payout WHERE user_id = v_bet.user_id;
          INSERT INTO token_transactions (user_id, type, amount, reference_id) VALUES (v_bet.user_id, 'bet_won', v_winner_payout, v_bet.id);
          UPDATE battle_spectator_bets SET status = 'won', payout = v_winner_payout WHERE id = v_bet.id;
        END LOOP;
      END IF;
      UPDATE battle_spectator_bets SET status = 'lost', payout = 0 WHERE match_id = p_match_id AND team_number != v_winner_team AND status = 'pending';
      FOR v_bet IN SELECT * FROM battle_spectator_bets WHERE match_id = p_match_id AND team_number != v_winner_team AND status = 'lost' AND payout = 0 LOOP
        INSERT INTO token_transactions (user_id, type, amount, reference_id) VALUES (v_bet.user_id, 'bet_lost', 0, v_bet.id);
      END LOOP;
    END;

    INSERT INTO battle_match_telemetry (match_id, turn_count, winning_archetypes, losing_archetypes, map_id, ultimates_used, auto_selections, match_duration_seconds, status_effects_applied)
    SELECT p_match_id, v_turn,
      ARRAY(SELECT archetype FROM battle_participants WHERE match_id = p_match_id AND team_number = v_winner_team),
      ARRAY(SELECT archetype FROM battle_participants WHERE match_id = p_match_id AND team_number != v_winner_team),
      v_match.map_id,
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'ultimate_used'),
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'auto_selected'),
      EXTRACT(EPOCH FROM (NOW() - v_match.started_at))::INTEGER,
      v_total_effects;

    UPDATE battle_matches SET status = 'resolved', winner_team_number = v_winner_team, resolved_at = NOW() WHERE id = p_match_id;
    v_seq := v_seq + 1;
    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, animation_key)
    VALUES (p_match_id, v_turn, v_seq, 'match_end', 'match_end_victory');
    RETURN;
  END IF;

  -- 11. Advance turn
  UPDATE battle_matches SET current_turn = current_turn + 1, turn_deadline = NOW() + (turn_duration_seconds * INTERVAL '1 second') WHERE id = p_match_id;

END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. REPLACE battle_forfeit (migration 066 body, updated)
-- ============================================================
CREATE OR REPLACE FUNCTION battle_forfeit(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_participant    battle_participants%ROWTYPE;
  v_current_turn   INTEGER;
  v_winner_team    INTEGER;
  v_bet            RECORD;
  v_winner_count   INTEGER;
  v_total_pool     INTEGER;
  v_winner_payout  INTEGER;
BEGIN
  SELECT * INTO v_participant
  FROM battle_participants
  WHERE match_id = p_match_id AND user_id = auth.uid();

  IF v_participant.id IS NULL THEN
    RAISE EXCEPTION 'You are not a participant in this match';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM battle_matches WHERE id = p_match_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Match is not active';
  END IF;

  SELECT current_turn INTO v_current_turn
  FROM battle_matches WHERE id = p_match_id;

  v_winner_team := CASE WHEN v_participant.team_number = 1 THEN 2 ELSE 1 END;

  SELECT COUNT(*) INTO v_winner_count
  FROM battle_spectator_bets
  WHERE match_id    = p_match_id
    AND team_number = v_winner_team
    AND status      = 'pending';

  SELECT spectator_pool INTO v_total_pool
  FROM battle_matches WHERE id = p_match_id;

  IF v_winner_count > 0 AND COALESCE(v_total_pool, 0) > 0 THEN
    v_winner_payout := FLOOR((v_total_pool * 0.90) / v_winner_count)::INTEGER;

    FOR v_bet IN
      SELECT *
      FROM battle_spectator_bets
      WHERE match_id    = p_match_id
        AND team_number = v_winner_team
        AND status      = 'pending'
    LOOP
      UPDATE token_balances
      SET available_tokens = available_tokens + v_winner_payout
      WHERE user_id = v_bet.user_id;

      INSERT INTO token_transactions (user_id, type, amount, reference_id)
      VALUES (v_bet.user_id, 'bet_won', v_winner_payout, v_bet.id);

      UPDATE battle_spectator_bets
      SET status = 'won', payout = v_winner_payout
      WHERE id = v_bet.id;
    END LOOP;
  END IF;

  UPDATE battle_spectator_bets
  SET status = 'lost', payout = 0
  WHERE match_id    = p_match_id
    AND team_number != v_winner_team
    AND status      = 'pending';

  FOR v_bet IN
    SELECT *
    FROM battle_spectator_bets
    WHERE match_id    = p_match_id
      AND team_number != v_winner_team
      AND status      = 'lost'
      AND payout      = 0
  LOOP
    INSERT INTO token_transactions (user_id, type, amount, reference_id)
    VALUES (v_bet.user_id, 'bet_lost', 0, v_bet.id);
  END LOOP;

  UPDATE battle_matches
  SET status             = 'resolved',
      winner_team_number = v_winner_team,
      resolved_at        = NOW()
  WHERE id = p_match_id;

  INSERT INTO battle_events (
    match_id, turn_number, sequence_in_turn, event_type,
    actor_participant_id, animation_key
  ) VALUES (
    p_match_id, v_current_turn, 999, 'match_end',
    v_participant.id, 'match_end_forfeit'
  );

  RETURN jsonb_build_object(
    'forfeited_by_team', v_participant.team_number,
    'winner_team',       v_winner_team
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 5. VERIFY (informational — will error if any rename failed)
-- ============================================================
DO $$
BEGIN
  -- Verify table rename
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'battle_animation_keys') THEN
    RAISE EXCEPTION 'battle_animation_keys table not found — rename failed';
  END IF;
  -- Verify column renames
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'battle_abilities' AND column_name = 'animation_key') THEN
    RAISE EXCEPTION 'battle_abilities.animation_key not found — rename failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'battle_events' AND column_name = 'animation_key') THEN
    RAISE EXCEPTION 'battle_events.animation_key not found — rename failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'battle_participant_status_effects' AND column_name = 'indicator_key') THEN
    RAISE EXCEPTION 'battle_participant_status_effects.indicator_key not found — rename failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'battle_maps' AND column_name = 'background_key') THEN
    RAISE EXCEPTION 'battle_maps.background_key not found — rename failed';
  END IF;
  RAISE NOTICE 'Migration 070 verified: all renames succeeded';
END $$;
