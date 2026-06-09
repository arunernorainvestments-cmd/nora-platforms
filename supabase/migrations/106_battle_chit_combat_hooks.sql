-- ─────────────────────────────────────────────────────────────────────────────
-- 106 — Battle Chit combat hooks: counter, type_override, damage_shield absorb
--
-- Closes spec §6: process_battle_turn now consumes the three chit effects that were
-- stored-but-inert. Source pulled verbatim from the live functions (pg_get_functiondef)
-- and edited surgically — no hand-reproduction:
--   • type_override : actor ignores type disadvantage on the attack (mult floored at 1.0)
--   • damage_shield : target absorbs up to effect_value of incoming damage (carry remainder)
--   • counter       : target reflects the dealt damage back to the attacker (+ attacker faint)
-- battle_use_chit now stores damage_shield under its own type (was approximated as
-- save_state). speed_burst stays mapped to a positive speed_debuff (turn-order CTE sums it).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_battle_turn(p_match_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
  -- Stat modifier variables (doc2)
  v_power_mod      DECIMAL(8,6);
  v_wit_mod        DECIMAL(8,6);
  v_resilience_red DECIMAL(8,6);
  -- Market settlement and chit drops
  v_linked_market_id UUID;
  v_winner         RECORD;
  v_chit_def       RECORD;
BEGIN

  -- 1. GUARD: load match
  SELECT * INTO v_match FROM battle_matches WHERE id = p_match_id AND status = 'active';
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
        WHERE bts.match_id      = p_match_id AND bts.turn_number = v_turn AND bts.participant_id = bp.id
      )
      AND EXISTS (
        SELECT 1 FROM battle_participant_status_effects bpse
        WHERE bpse.participant_id = bp.id AND bpse.effect_type = 'force_skip' AND bpse.consumed = FALSE
      )
  LOOP
    UPDATE battle_participant_status_effects
    SET consumed = TRUE
    WHERE participant_id = v_participant.id AND effect_type = 'force_skip' AND consumed = FALSE;

    v_seq := v_seq + 1;
    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, animation_key)
    VALUES (p_match_id, v_turn, v_seq, 'auto_selected', v_participant.id, 'force_skip_applied');
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
        WHERE bts.match_id = p_match_id AND bts.turn_number = v_turn AND bts.participant_id = bp.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM battle_participant_status_effects bpse
        WHERE bpse.participant_id = bp.id AND bpse.effect_type = 'force_skip'
      )
  LOOP
    -- a. Forced ability
    SELECT * INTO v_effect FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id AND effect_type = 'forced_ability' AND consumed = FALSE LIMIT 1;
    IF v_effect.id IS NOT NULL THEN
      INSERT INTO battle_turn_submissions (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
      SELECT p_match_id, v_turn, v_participant.id, v_participant.user_id,
        (SELECT ba.id FROM battle_abilities ba
         WHERE ba.archetype = v_participant.archetype AND v_participant.current_ap >= ba.ap_cost
           AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
         ORDER BY ba.base_damage ASC LIMIT 1), TRUE
      ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      CONTINUE;
    END IF;

    -- b. Encore
    SELECT * INTO v_effect FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id AND effect_type = 'encore' AND consumed = FALSE LIMIT 1;
    IF v_effect.id IS NOT NULL THEN
      SELECT ba.* INTO v_last_ability
      FROM battle_events be JOIN battle_abilities ba ON ba.id = be.ability_id
      WHERE be.match_id = p_match_id AND be.actor_participant_id = v_participant.id
        AND be.event_type IN ('ability_used', 'ultimate_used') AND be.ability_id IS NOT NULL
      ORDER BY be.created_at DESC LIMIT 1;
      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      IF v_last_ability.id IS NOT NULL AND v_participant.current_ap >= v_last_ability.ap_cost THEN
        INSERT INTO battle_turn_submissions (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
        VALUES (p_match_id, v_turn, v_participant.id, v_participant.user_id, v_last_ability.id, TRUE)
        ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
        CONTINUE;
      END IF;
    END IF;

    -- c. Standard auto-select
    INSERT INTO battle_turn_submissions (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
    SELECT p_match_id, v_turn, v_participant.id, v_participant.user_id,
      (SELECT ba.id FROM battle_abilities ba
       WHERE ba.archetype = v_participant.archetype AND v_participant.current_ap >= ba.ap_cost
         AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
       ORDER BY ba.base_damage DESC LIMIT 1), TRUE
    ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
  END LOOP;

  -- 7. AP REGENERATION
  UPDATE battle_participants SET current_ap = LEAST(max_ap, current_ap + 5)
  WHERE match_id = p_match_id AND is_fainted = FALSE;

  -- 8. PHASE 1: Voluntary swaps
  FOR v_submission IN
    SELECT bts.*, bp.team_number AS actor_team
    FROM battle_turn_submissions bts JOIN battle_participants bp ON bp.id = bts.participant_id
    WHERE bts.match_id = p_match_id AND bts.turn_number = v_turn AND bts.swap_to_participant_id IS NOT NULL
    ORDER BY bp.speed DESC
  LOOP
    v_seq := v_seq + 1;
    SELECT * INTO v_actor  FROM battle_participants WHERE id = v_submission.participant_id;
    SELECT * INTO v_target FROM battle_participants WHERE id = v_submission.swap_to_participant_id;
    UPDATE battle_participants SET is_active = FALSE WHERE id = v_actor.id;
    UPDATE battle_participants SET is_active = TRUE  WHERE id = v_target.id;
    INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, target_participant_id, animation_key)
    VALUES (p_match_id, v_turn, v_seq, 'swap_voluntary', v_actor.id, v_target.id, 'swap_voluntary');
  END LOOP;

  -- 9. PHASE 2: Attacks with stat modifiers and speed debuff adjustments
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
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type, actor_participant_id, animation_key)
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

      -- Chit: type_override — ignore type disadvantage for this attack
      SELECT * INTO v_effect FROM battle_participant_status_effects
      WHERE participant_id = v_actor.id AND effect_type = 'type_override' AND consumed = FALSE LIMIT 1;
      IF v_effect.id IS NOT NULL THEN
        v_type_mult := GREATEST(v_type_mult, 1.00);
        UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      END IF;

      -- Magnum Opus: resistance floor
      IF v_ability.animation_key = 'artist_ultimate' THEN v_type_mult := GREATEST(v_type_mult, 1.00); END IF;

      -- Stat modifiers (doc2): power_mod ±20%, wit_mod ±10%, resilience_reduction up to 30%
      v_power_mod      := GREATEST(0.5, LEAST(2.0,
        1.0 + (v_actor.snap_power::float - 50.0) / 250.0));
      v_wit_mod        := GREATEST(0.8, LEAST(1.2,
        1.0 + (v_actor.snap_wit::float - 50.0) / 500.0));
      v_resilience_red := GREATEST(0.0, LEAST(0.30,
        v_target.snap_resilience::float / 500.0));

      v_damage        := ROUND(
        v_ability.base_damage
        * v_type_mult
        * v_power_mod
        * v_wit_mod
        * (1.0 - v_resilience_red)
      );
      v_animation_key := v_ability.animation_key;

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

      -- Chit: damage_shield — absorb up to effect_value of incoming damage
      IF v_damage > 0 THEN
        SELECT * INTO v_effect FROM battle_participant_status_effects
        WHERE participant_id = v_target.id AND effect_type = 'damage_shield' AND consumed = FALSE
        ORDER BY created_at ASC LIMIT 1;
        IF v_effect.id IS NOT NULL THEN
          IF v_effect.effect_value > v_damage THEN
            UPDATE battle_participant_status_effects SET effect_value = effect_value - v_damage WHERE id = v_effect.id;
            v_damage := 0;
          ELSE
            v_damage := v_damage - v_effect.effect_value;
            UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
          END IF;
          v_animation_key := 'damage_shield_block';
        END IF;
      END IF;

      IF v_damage > 0 THEN
        UPDATE battle_participants SET current_hp = GREATEST(0, current_hp - v_damage) WHERE id = v_target.id;

        -- Chit: counter — reflect the dealt damage back to the attacker
        SELECT * INTO v_effect FROM battle_participant_status_effects
        WHERE participant_id = v_target.id AND effect_type = 'counter' AND consumed = FALSE LIMIT 1;
        IF v_effect.id IS NOT NULL THEN
          UPDATE battle_participants SET current_hp = GREATEST(0, current_hp - v_damage) WHERE id = v_actor.id;
          UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
          v_seq := v_seq + 1;
          INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
            actor_participant_id, target_participant_id, damage_dealt, animation_key)
          VALUES (p_match_id, v_turn, v_seq, 'ability_used', v_target.id, v_actor.id, v_damage, 'counter_reflect');
        END IF;
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
        UPDATE battle_participants SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value) WHERE id = v_actor.id;
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

    -- A counter chit may have KO'd the attacker — handle their faint + forced swap.
    IF v_actor.current_hp <= 0 AND NOT v_actor.is_fainted THEN
      UPDATE battle_participants SET is_fainted = TRUE, is_active = FALSE WHERE id = v_actor.id;
      v_seq := v_seq + 1;
      INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, target_participant_id, animation_key)
      VALUES (p_match_id, v_turn, v_seq, 'ko', COALESCE(v_target.id, v_actor.id), v_actor.id, 'ko_faint');
      DECLARE v_next_bench battle_participants%ROWTYPE;
      BEGIN
        SELECT * INTO v_next_bench FROM battle_participants
        WHERE match_id = p_match_id AND team_number = v_actor.team_number AND is_fainted = FALSE AND is_active = FALSE
        ORDER BY slot_position ASC LIMIT 1;
        IF v_next_bench.id IS NOT NULL THEN
          UPDATE battle_participants SET is_active = TRUE WHERE id = v_next_bench.id;
          v_seq := v_seq + 1;
          INSERT INTO battle_events (match_id, turn_number, sequence_in_turn, event_type,
            actor_participant_id, target_participant_id, animation_key)
          VALUES (p_match_id, v_turn, v_seq, 'swap_forced', v_actor.id, v_next_bench.id, 'swap_forced');
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

    -- Existing spectator bet settlement
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

    -- Settle linked prediction market (swallow errors so match resolution is never aborted)
    SELECT id INTO v_linked_market_id FROM markets
    WHERE battle_match_id = p_match_id AND status = 'open' AND resolution_type = 'battle_outcome'
    LIMIT 1;
    IF v_linked_market_id IS NOT NULL THEN
      BEGIN
        PERFORM distribute_match_revenue(
          v_linked_market_id,
          p_match_id,
          'team_' || v_winner_team::text,
          'team_' || CASE WHEN v_winner_team = 1 THEN 2 ELSE 1 END::text
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[process_battle_turn] distribute_match_revenue failed for market %: %', v_linked_market_id, SQLERRM;
      END;
    END IF;

    -- RNG chit drop for winning team (post-launch collectible economy)
    FOR v_winner IN
      SELECT DISTINCT COALESCE(bts.user_id, bp.user_id) AS winner_user_id
      FROM battle_participants bp
      LEFT JOIN battle_turn_submissions bts ON bts.participant_id = bp.id AND bts.match_id = p_match_id
      WHERE bp.match_id = p_match_id AND bp.team_number = v_winner_team
    LOOP
      FOR v_chit_def IN
        SELECT * FROM battle_chit_definitions
        WHERE can_earn_from_match_rng = TRUE AND rng_drop_rate IS NOT NULL AND is_active = TRUE
        ORDER BY rarity DESC
      LOOP
        IF random() < v_chit_def.rng_drop_rate THEN
          INSERT INTO user_battle_chits (user_id, chit_definition_id, quantity, acquired_via)
          VALUES (v_winner.winner_user_id, v_chit_def.id, 1, 'match_rng')
          ON CONFLICT (user_id, chit_definition_id) DO UPDATE SET quantity = user_battle_chits.quantity + 1;
          EXIT;
        END IF;
      END LOOP;
    END LOOP;

    RETURN;
  END IF;

  -- 11. Advance turn
  UPDATE battle_matches SET current_turn = current_turn + 1, turn_deadline = NOW() + (turn_duration_seconds * INTERVAL '1 second') WHERE id = p_match_id;

END;
$function$
;

CREATE OR REPLACE FUNCTION public.battle_use_chit(p_match_id uuid, p_participant_id uuid, p_chit_def_id uuid, p_target_participant_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- Absorbs up to effect_value of incoming damage; consumed by process_battle_turn.
    INSERT INTO battle_participant_status_effects (
      match_id, participant_id, applied_by_participant_id,
      effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key)
    VALUES (p_match_id, p_participant_id, p_participant_id,
      'damage_shield', v_val_int, v_turn, v_expires, 'chit_damage_shield');

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
$function$
;
