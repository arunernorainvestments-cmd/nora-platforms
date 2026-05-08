-- Migration 063: Battle Mode Phase A — Turn Resolution Engine
-- process_battle_turn(p_match_id UUID)
--
-- Called every 3 seconds by process_all_battle_turns() via pg_cron.
-- Resolves a full turn for one match:
--   1. Check if all submissions received OR deadline passed; return early if neither.
--   2. Auto-select moves for any player who has not submitted.
--   3. AP regeneration (5 per non-fainted participant).
--   4. Phase 1: voluntary swaps (resolve before attacks, in speed order).
--   5. Phase 2: attacks (speed order, ties broken randomly).
--      - Deduct AP, reset momentum if ultimate.
--      - Type effectiveness lookup from battle_type_chart.
--      - Damage = base_damage × type_multiplier (map_multiplier = 1.0 until Phase D).
--      - Momentum gain: +10 per attack, +25 bonus for super effective (1.5×).
--      - Non-damage effects: heal, drain_ap, momentum_boost.
--      - Event row with RIVE HOOK key.
--      - Auto-selected event marker.
--      - KO check → faint + forced swap if bench available.
--      - Ultimate ready notification at momentum = 100.
--   6. Win condition: one team has zero living characters.
--      - Spectator bet resolution (90% pool to winners, equal split).
--      - Telemetry insert.
--      - Match closed: status = 'resolved'.
--   7. Advance turn counter and reset deadline.

CREATE OR REPLACE FUNCTION process_battle_turn(p_match_id UUID)
RETURNS VOID AS $$
DECLARE
  v_match          battle_matches%ROWTYPE;
  v_turn           INTEGER;
  v_seq            INTEGER := 0;
  v_submission     RECORD;
  v_actor          battle_participants%ROWTYPE;
  v_target         battle_participants%ROWTYPE;
  v_ability        battle_abilities%ROWTYPE;
  v_type_mult      DECIMAL(3,2);
  v_damage         INTEGER;
  v_momentum_gain  INTEGER;
  v_rive_key       TEXT;
  v_winner_team    INTEGER;
  v_team1_alive    INTEGER;
  v_team2_alive    INTEGER;
BEGIN
  SELECT * INTO v_match
  FROM battle_matches
  WHERE id = p_match_id AND status = 'active';

  IF v_match.id IS NULL THEN
    RETURN;
  END IF;

  v_turn := v_match.current_turn;

  -- Wait unless: deadline has passed OR all active players have submitted.
  IF NOT (
    NOW() > v_match.turn_deadline
    OR NOT EXISTS (
      SELECT 1
      FROM battle_participants bp
      WHERE bp.match_id  = p_match_id
        AND bp.is_active = TRUE
        AND bp.is_fainted = FALSE
        AND NOT EXISTS (
          SELECT 1
          FROM battle_turn_submissions bts
          WHERE bts.match_id      = p_match_id
            AND bts.turn_number   = v_turn
            AND bts.participant_id = bp.id
        )
    )
  ) THEN
    RETURN;
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- Auto-select for any active player who has not submitted.
  -- Picks the highest base_damage affordable ability the character
  -- can legally use (AP sufficient, momentum sufficient if ultimate).
  -- ──────────────────────────────────────────────────────────────
  INSERT INTO battle_turn_submissions
    (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
  SELECT
    p_match_id,
    v_turn,
    bp.id,
    bp.user_id,
    (
      SELECT ba.id
      FROM battle_abilities ba
      WHERE ba.archetype = bp.archetype
        AND bp.current_ap >= ba.ap_cost
        AND (NOT ba.requires_momentum OR bp.momentum >= 100)
      ORDER BY ba.base_damage DESC
      LIMIT 1
    ),
    TRUE
  FROM battle_participants bp
  WHERE bp.match_id   = p_match_id
    AND bp.is_active  = TRUE
    AND bp.is_fainted = FALSE
    AND NOT EXISTS (
      SELECT 1
      FROM battle_turn_submissions bts
      WHERE bts.match_id      = p_match_id
        AND bts.turn_number   = v_turn
        AND bts.participant_id = bp.id
    )
  ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;

  -- ──────────────────────────────────────────────────────────────
  -- AP regeneration: all non-fainted participants gain 5 AP.
  -- ──────────────────────────────────────────────────────────────
  UPDATE battle_participants
  SET current_ap = LEAST(max_ap, current_ap + 5)
  WHERE match_id = p_match_id AND is_fainted = FALSE;

  -- ============================================================
  -- PHASE 1: Voluntary swaps (resolve before any attacks)
  -- ============================================================
  FOR v_submission IN
    SELECT
      bts.*,
      bp.team_number AS actor_team
    FROM battle_turn_submissions bts
    JOIN battle_participants bp ON bp.id = bts.participant_id
    WHERE bts.match_id    = p_match_id
      AND bts.turn_number = v_turn
      AND bts.swap_to_participant_id IS NOT NULL
    ORDER BY bp.speed DESC
  LOOP
    v_seq := v_seq + 1;

    SELECT * INTO v_actor  FROM battle_participants WHERE id = v_submission.participant_id;
    SELECT * INTO v_target FROM battle_participants WHERE id = v_submission.swap_to_participant_id;

    -- Deactivate current active character, activate swap target.
    UPDATE battle_participants SET is_active = FALSE WHERE id = v_actor.id;
    UPDATE battle_participants SET is_active = TRUE  WHERE id = v_target.id;

    -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
    --            the matching Rive state machine input for this event.
    -- 'swap_voluntary' triggers swap-out for v_actor and swap-in for v_target.
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, target_participant_id,
      rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'swap_voluntary',
      v_actor.id, v_target.id,
      'swap_voluntary'
    );
  END LOOP;

  -- ============================================================
  -- PHASE 2: Attacks in speed order (highest speed first)
  -- speed_priority * 1000 ensures priority moves always go first/last.
  -- Ties broken randomly via ORDER BY RANDOM().
  -- ============================================================
  FOR v_submission IN
    SELECT
      bts.*,
      bp.speed + (ba.speed_priority * 1000) AS effective_speed,
      bp.archetype                            AS actor_archetype,
      bp.team_number                          AS actor_team
    FROM battle_turn_submissions bts
    JOIN battle_participants bp ON bp.id   = bts.participant_id
    JOIN battle_abilities    ba ON ba.id   = bts.ability_id
    WHERE bts.match_id    = p_match_id
      AND bts.turn_number = v_turn
      AND bts.ability_id IS NOT NULL
    ORDER BY (bp.speed + (ba.speed_priority * 1000)) DESC, RANDOM()
  LOOP
    v_seq := v_seq + 1;

    SELECT * INTO v_actor FROM battle_participants WHERE id = v_submission.participant_id;

    -- Skip if actor fainted earlier this turn (e.g., was attacked before their move).
    IF v_actor.is_fainted THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_ability FROM battle_abilities WHERE id = v_submission.ability_id;

    -- Deduct AP cost.
    UPDATE battle_participants
    SET current_ap = current_ap - v_ability.ap_cost
    WHERE id = v_actor.id;

    -- Reset momentum to 0 if ultimate was used.
    IF v_ability.is_ultimate THEN
      UPDATE battle_participants SET momentum = 0 WHERE id = v_actor.id;
    END IF;

    -- Find the opponent's active, non-fainted character.
    SELECT * INTO v_target
    FROM battle_participants
    WHERE match_id    = p_match_id
      AND team_number != v_actor.team_number
      AND is_active   = TRUE
      AND is_fainted  = FALSE
    LIMIT 1;

    IF v_target.id IS NULL THEN
      -- Opponent has no active character; skip damage but still apply effects.
      v_type_mult := 1.00;
      v_damage    := 0;
    ELSE
      -- Type effectiveness lookup from battle_type_chart.
      -- RIVE HOOK: type_multiplier value drives the 'super_effective' or
      --            'resisted' visual overlay in Phase C.
      SELECT multiplier INTO v_type_mult
      FROM battle_type_chart
      WHERE attacker_type = v_actor.archetype
        AND defender_type = v_target.archetype;
      v_type_mult := COALESCE(v_type_mult, 1.00);

      -- Damage calculation.
      -- Phase D: add map affinity multiplier here using battle_maps.affinity_archetypes.
      -- map_multiplier stub: 1.00 until Phase D wires affinity system.
      v_damage := ROUND(v_ability.base_damage * v_type_mult);

      -- Apply damage.
      IF v_damage > 0 THEN
        UPDATE battle_participants
        SET current_hp = GREATEST(0, current_hp - v_damage)
        WHERE id = v_target.id;
      END IF;
    END IF;

    -- Momentum gain from dealing damage.
    -- Super effective hit (+25 bonus): type_multiplier >= 1.5.
    v_momentum_gain := 10;
    IF v_type_mult >= 1.5 THEN
      v_momentum_gain := v_momentum_gain + 25;
    END IF;

    UPDATE battle_participants
    SET momentum = LEAST(100, momentum + v_momentum_gain)
    WHERE id = v_actor.id;

    -- ── Non-damage effects ─────────────────────────────────────
    IF v_ability.effect_type = 'heal' THEN
      IF v_ability.effect_target = 'all_allies' THEN
        -- Heals all non-fainted allies (e.g. politician Campaign Promise).
        UPDATE battle_participants
        SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;
      ELSE
        -- Heals actor only: 'self' or unrecognised target (e.g. athlete Second Wind).
        UPDATE battle_participants
        SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE id = v_actor.id;
      END IF;
    ELSIF v_ability.effect_type = 'drain_ap' THEN
      IF v_target.id IS NOT NULL THEN
        IF v_ability.effect_target IN ('opponent', 'all_opponents') THEN
          UPDATE battle_participants
          SET current_ap = GREATEST(0, current_ap - v_ability.effect_value)
          WHERE match_id    = p_match_id
            AND team_number != v_actor.team_number
            AND is_fainted  = FALSE;
        END IF;
      END IF;
    ELSIF v_ability.effect_type = 'momentum_boost' THEN
      IF v_ability.effect_target IN ('self', 'ally', 'all_allies') THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;
      ELSIF v_ability.effect_target IN ('opponent', 'all_opponents') THEN
        -- Negative effect_value drains opponent momentum (e.g. comedian Standing Ovation).
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number != v_actor.team_number
          AND is_fainted  = FALSE;
      END IF;
    END IF;

    -- Reload actor and target for accurate post-action values in event row.
    SELECT * INTO v_actor FROM battle_participants WHERE id = v_actor.id;
    IF v_target.id IS NOT NULL THEN
      SELECT * INTO v_target FROM battle_participants WHERE id = v_target.id;
    END IF;

    -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
    --            the matching Rive state machine input for this event.
    --            Animation key format: archetype_abilityname (e.g. athlete_power_slam).
    v_rive_key := v_ability.rive_animation_key;

    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, target_participant_id,
      ability_id, damage_dealt, hp_after, ap_after, momentum_after,
      type_multiplier, map_multiplier, rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq,
      CASE WHEN v_ability.is_ultimate THEN 'ultimate_used' ELSE 'ability_used' END,
      v_actor.id,
      v_target.id,
      v_ability.id,
      v_damage,
      CASE WHEN v_target.id IS NOT NULL THEN v_target.current_hp ELSE NULL END,
      v_actor.current_ap,
      v_actor.momentum,
      v_type_mult,
      1.00,
      v_rive_key
    );

    -- Log auto-selection event if move was auto-picked due to timeout.
    IF v_submission.was_auto_selected THEN
      v_seq := v_seq + 1;
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'auto_selected',
        v_actor.id, 'auto_selected'
      );
    END IF;

    -- ── KO check ────────────────────────────────────────────────
    IF v_target.id IS NOT NULL AND v_target.current_hp <= 0 THEN
      UPDATE battle_participants
      SET is_fainted = TRUE, is_active = FALSE
      WHERE id = v_target.id;

      v_seq := v_seq + 1;
      -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
      --            the matching Rive state machine input for this event.
      -- 'ko_faint' triggers the KO faint animation for the downed character.
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, target_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'ko',
        v_actor.id, v_target.id, 'ko_faint'
      );

      -- Auto-swap: bring in next non-fainted bench character on the losing team.
      DECLARE
        v_next_bench battle_participants%ROWTYPE;
      BEGIN
        SELECT * INTO v_next_bench
        FROM battle_participants
        WHERE match_id    = p_match_id
          AND team_number = v_target.team_number
          AND is_fainted  = FALSE
          AND is_active   = FALSE
        ORDER BY slot_position ASC
        LIMIT 1;

        IF v_next_bench.id IS NOT NULL THEN
          UPDATE battle_participants
          SET is_active = TRUE
          WHERE id = v_next_bench.id;

          v_seq := v_seq + 1;
          -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
          --            the matching Rive state machine input for this event.
          -- 'swap_forced' triggers forced swap-in animation for incoming character.
          INSERT INTO battle_events (
            match_id, turn_number, sequence_in_turn, event_type,
            actor_participant_id, target_participant_id, rive_animation_key
          ) VALUES (
            p_match_id, v_turn, v_seq, 'swap_forced',
            v_target.id, v_next_bench.id, 'swap_forced'
          );
        END IF;
      END;
    END IF;

    -- ── Ultimate ready notification ──────────────────────────────
    -- Fire once when momentum hits 100 (and this wasn't the ultimate itself).
    IF v_actor.momentum = 100 AND NOT v_ability.is_ultimate THEN
      v_seq := v_seq + 1;
      -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
      --            the matching Rive state machine input for this event.
      -- 'ultimate_ready' triggers momentum-full glow animation on actor.
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'ultimate_ready',
        v_actor.id, 'ultimate_ready'
      );
    END IF;

  END LOOP;

  -- ============================================================
  -- WIN CONDITION CHECK
  -- ============================================================
  SELECT COUNT(*) INTO v_team1_alive
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 1 AND is_fainted = FALSE;

  SELECT COUNT(*) INTO v_team2_alive
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 2 AND is_fainted = FALSE;

  IF v_team1_alive = 0 OR v_team2_alive = 0 THEN
    v_winner_team := CASE WHEN v_team1_alive > 0 THEN 1 ELSE 2 END;

    -- ── Spectator bet resolution ──────────────────────────────────
    -- 90% of spectator_pool to winners (equal split), 10% retained as platform fee.
    -- token_balances uses available_tokens column (NOT balance).
    DECLARE
      v_bet            RECORD;
      v_winner_count   INTEGER;
      v_total_pool     INTEGER;
      v_winner_payout  INTEGER;
    BEGIN
      SELECT COUNT(*) INTO v_winner_count
      FROM battle_spectator_bets
      WHERE match_id = p_match_id
        AND team_number = v_winner_team
        AND status = 'pending';

      SELECT spectator_pool INTO v_total_pool
      FROM battle_matches
      WHERE id = p_match_id;

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

      -- Mark losing bets.
      UPDATE battle_spectator_bets
      SET status = 'lost', payout = 0
      WHERE match_id    = p_match_id
        AND team_number != v_winner_team
        AND status      = 'pending';

      -- Log bet_lost transactions for all losing bettors.
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
    END;

    -- ── Telemetry ─────────────────────────────────────────────────
    INSERT INTO battle_match_telemetry (
      match_id, turn_count, winning_archetypes, losing_archetypes,
      map_id, ultimates_used, auto_selections, match_duration_seconds
    )
    SELECT
      p_match_id,
      v_turn,
      ARRAY(
        SELECT archetype
        FROM battle_participants
        WHERE match_id = p_match_id AND team_number = v_winner_team
      ),
      ARRAY(
        SELECT archetype
        FROM battle_participants
        WHERE match_id = p_match_id AND team_number != v_winner_team
      ),
      v_match.map_id,
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'ultimate_used'),
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'auto_selected'),
      EXTRACT(EPOCH FROM (NOW() - v_match.started_at))::INTEGER;

    -- ── Close match ───────────────────────────────────────────────
    UPDATE battle_matches
    SET
      status              = 'resolved',
      winner_team_number  = v_winner_team,
      resolved_at         = NOW()
    WHERE id = p_match_id;

    v_seq := v_seq + 1;
    -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
    --            the matching Rive state machine input for this event.
    -- 'match_end_victory' triggers victory/defeat screen animations.
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type, rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'match_end', 'match_end_victory'
    );

    RETURN;
  END IF;

  -- ── Advance to next turn ─────────────────────────────────────────
  UPDATE battle_matches
  SET
    current_turn  = current_turn + 1,
    turn_deadline = NOW() + (turn_duration_seconds * INTERVAL '1 second')
  WHERE id = p_match_id;

END;
$$ LANGUAGE plpgsql;
