-- Migration 067: Battle Mode Phase B — process_battle_turn v2
--
-- Complete replacement of Phase A process_battle_turn().
-- Adds: status effect system, all special ability logic, speed debuff ordering.
--
-- Algorithm:
--   1. Guard: load match, return if not active.
--   2. Expire old status effects (cleanup before any logic reads them).
--   3. Guard: all submitted OR deadline passed (force_skip participants exempt).
--   4. Handle force_skip participants: consume effect, log event, no submission.
--   5. Auto-select with overrides: forced_ability → encore → standard.
--      Marks is_automated participants with 'player_disconnected' rive key.
--   6. AP regeneration (+5 all non-fainted).
--   7. Phase 1: voluntary swaps (same as v1).
--   8. Phase 2: attacks in effective speed order (base speed + priority ± debuff).
--      Per action:
--        a. Skip if actor fainted.
--        b. Check force_skip (NOT consumed): skip action, consume, log event.
--        c. Deduct AP; reset momentum if ultimate.
--        d. Find opponent active target.
--        e. Type effectiveness lookup; apply type_reversed if active (consume).
--        f. Magnum Opus floor: GREATEST(type_mult, 1.00) for artist_ultimate.
--        g. Base damage = base_damage × type_mult.
--        h. Save State check on target (consume if damage < threshold → damage=0).
--        i. Double damage check on actor (consume → damage × 2).
--        j. Apply damage.
--        k. Momentum gain (+10, +25 bonus for super effective).
--        l. Non-damage effects: heal, drain_ap, momentum_boost, debuff→speed_debuff,
--           force_skip→status effect, special ability logic.
--        m. Reload actor/target, insert event.
--        n. Auto-selected event marker.
--        o. KO check → faint + forced swap.
--        p. Ultimate ready notification.
--   9. Win condition: settle bets, write telemetry, close match.
--  10. Advance turn counter and reset deadline.

CREATE OR REPLACE FUNCTION process_battle_turn(p_match_id UUID)
RETURNS VOID AS $$
DECLARE
  v_match          battle_matches%ROWTYPE;
  v_turn           INTEGER;
  v_seq            INTEGER := 0;
  v_effects_applied INTEGER := 0;  -- tracks status effects inserted this turn; reset per turn
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
  v_rive_key       TEXT;
  v_winner_team    INTEGER;
  v_team1_alive    INTEGER;
  v_team2_alive    INTEGER;
  v_total_effects  INTEGER := 0;  -- accumulates across all turns for telemetry
BEGIN

  -- ──────────────────────────────────────────────────────────────
  -- 1. GUARD: load match
  -- ──────────────────────────────────────────────────────────────
  SELECT * INTO v_match
  FROM battle_matches
  WHERE id = p_match_id AND status = 'active';

  IF v_match.id IS NULL THEN RETURN; END IF;

  v_turn := v_match.current_turn;

  -- ──────────────────────────────────────────────────────────────
  -- 2. GUARD: require participants on both teams.
  -- Protects against pg_cron firing between match creation and participant insertion.
  -- In production, battle_start_match enforces 3-per-team before activating.
  -- All-fainted participants still exist in the table (is_fainted=TRUE), so this
  -- guard only fires for truly empty teams — not for the normal win condition path.
  -- ──────────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM battle_participants WHERE match_id = p_match_id AND team_number = 1)
  OR NOT EXISTS (SELECT 1 FROM battle_participants WHERE match_id = p_match_id AND team_number = 2) THEN
    RETURN;
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- 3. EXPIRE status effects
  -- Delete effects whose last active turn has passed (expires_at_turn < v_turn),
  -- and consumed effects from previous turns.
  -- This runs BEFORE the wait check so force_skip reads are accurate.
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM battle_participant_status_effects
  WHERE match_id = p_match_id
    AND (expires_at_turn < v_turn OR consumed = TRUE);

  -- ──────────────────────────────────────────────────────────────
  -- 3. GUARD: wait unless all active players submitted OR deadline passed.
  -- Force_skip participants count as "handled" (no submission needed).
  -- ──────────────────────────────────────────────────────────────
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
          -- Participants with active force_skip need no submission this turn.
          SELECT 1 FROM battle_participant_status_effects bpse
          WHERE bpse.participant_id = bp.id
            AND bpse.effect_type   = 'force_skip'
            AND bpse.consumed      = FALSE
        )
    )
  ) THEN
    RETURN;
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- 4. HANDLE FORCE_SKIP non-submitters: consume effect, log event.
  -- These participants will simply have no submission in the attack loop.
  -- ──────────────────────────────────────────────────────────────
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
    -- Consume the force_skip effect (cleaned at start of next turn).
    UPDATE battle_participant_status_effects
    SET consumed = TRUE
    WHERE participant_id = v_participant.id
      AND effect_type    = 'force_skip'
      AND consumed       = FALSE;

    v_seq := v_seq + 1;
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'auto_selected',
      v_participant.id, 'force_skip_applied'
    );
  END LOOP;

  -- ──────────────────────────────────────────────────────────────
  -- 5. AUTO-SELECT with status effect overrides
  -- Iterates remaining non-submitters (force_skip participants already handled).
  -- Priority: forced_ability → encore → standard (highest damage).
  -- ──────────────────────────────────────────────────────────────
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
        -- Exclude force_skip participants (already handled above).
        SELECT 1 FROM battle_participant_status_effects bpse
        WHERE bpse.participant_id = bp.id
          AND bpse.effect_type   = 'force_skip'
      )
  LOOP
    -- ── a. Forced ability (Influencer #1 Trending): lowest damage move ──
    SELECT * INTO v_effect
    FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id
      AND effect_type    = 'forced_ability'
      AND consumed       = FALSE
    LIMIT 1;

    IF v_effect.id IS NOT NULL THEN
      INSERT INTO battle_turn_submissions
        (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
      SELECT
        p_match_id, v_turn, v_participant.id, v_participant.user_id,
        (SELECT ba.id FROM battle_abilities ba
         WHERE ba.archetype = v_participant.archetype
           AND v_participant.current_ap >= ba.ap_cost
           AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
         ORDER BY ba.base_damage ASC LIMIT 1),
        TRUE
      ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;

      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      CONTINUE;
    END IF;

    -- ── b. Encore (Musician): repeat last ability used ──
    SELECT * INTO v_effect
    FROM battle_participant_status_effects
    WHERE participant_id = v_participant.id
      AND effect_type    = 'encore'
      AND consumed       = FALSE
    LIMIT 1;

    IF v_effect.id IS NOT NULL THEN
      -- Find last ability this participant used.
      SELECT ba.* INTO v_last_ability
      FROM battle_events be
      JOIN battle_abilities ba ON ba.id = be.ability_id
      WHERE be.match_id             = p_match_id
        AND be.actor_participant_id = v_participant.id
        AND be.event_type           IN ('ability_used', 'ultimate_used')
        AND be.ability_id           IS NOT NULL
      ORDER BY be.created_at DESC
      LIMIT 1;

      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;

      -- Use encore ability if participant can still afford it.
      IF v_last_ability.id IS NOT NULL AND v_participant.current_ap >= v_last_ability.ap_cost THEN
        INSERT INTO battle_turn_submissions
          (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
        VALUES
          (p_match_id, v_turn, v_participant.id, v_participant.user_id, v_last_ability.id, TRUE)
        ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
        CONTINUE;
        -- Falls through to standard auto-select if encore ability not found or unaffordable.
      END IF;
    END IF;

    -- ── c. Standard auto-select: highest base_damage affordable ability ──
    INSERT INTO battle_turn_submissions
      (match_id, turn_number, participant_id, user_id, ability_id, was_auto_selected)
    SELECT
      p_match_id, v_turn, v_participant.id, v_participant.user_id,
      (SELECT ba.id FROM battle_abilities ba
       WHERE ba.archetype = v_participant.archetype
         AND v_participant.current_ap >= ba.ap_cost
         AND (NOT ba.requires_momentum OR v_participant.momentum >= 100)
       ORDER BY ba.base_damage DESC LIMIT 1),
      TRUE
    ON CONFLICT (match_id, turn_number, participant_id) DO NOTHING;
  END LOOP;

  -- ──────────────────────────────────────────────────────────────
  -- 6. AP REGENERATION: all non-fainted participants gain 5 AP.
  -- ──────────────────────────────────────────────────────────────
  UPDATE battle_participants
  SET current_ap = LEAST(max_ap, current_ap + 5)
  WHERE match_id = p_match_id AND is_fainted = FALSE;

  -- ============================================================
  -- 7. PHASE 1: Voluntary swaps (same as v1, before attacks)
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

    UPDATE battle_participants SET is_active = FALSE WHERE id = v_actor.id;
    UPDATE battle_participants SET is_active = TRUE  WHERE id = v_target.id;

    -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
    --            the matching Rive state machine input for this event.
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type,
      actor_participant_id, target_participant_id, rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'swap_voluntary',
      v_actor.id, v_target.id, 'swap_voluntary'
    );
  END LOOP;

  -- ============================================================
  -- 8. PHASE 2: Attacks in effective speed order
  -- Speed debuffs are subtracted via LEFT JOIN on status effects
  -- before ordering, so the ORDER BY is stable and correct.
  -- ============================================================
  FOR v_submission IN
    WITH speed_debuffs AS (
      SELECT participant_id, COALESCE(SUM(effect_value), 0) AS speed_delta
      FROM battle_participant_status_effects
      WHERE match_id    = p_match_id
        AND effect_type = 'speed_debuff'
        AND consumed    = FALSE
      GROUP BY participant_id
    )
    SELECT
      bts.*,
      bp.speed + (ba.speed_priority * 1000) + COALESCE(sd.speed_delta, 0) AS effective_speed,
      bp.archetype   AS actor_archetype,
      bp.team_number AS actor_team
    FROM battle_turn_submissions bts
    JOIN battle_participants bp ON bp.id = bts.participant_id
    JOIN battle_abilities    ba ON ba.id = bts.ability_id
    LEFT JOIN speed_debuffs  sd ON sd.participant_id = bts.participant_id
    WHERE bts.match_id    = p_match_id
      AND bts.turn_number = v_turn
      AND bts.ability_id  IS NOT NULL
    ORDER BY (bp.speed + (ba.speed_priority * 1000) + COALESCE(sd.speed_delta, 0)) DESC, RANDOM()
  LOOP
    v_seq := v_seq + 1;

    SELECT * INTO v_actor FROM battle_participants WHERE id = v_submission.participant_id;

    -- ── a. Skip if actor fainted this turn ──
    IF v_actor.is_fainted THEN CONTINUE; END IF;

    SELECT * INTO v_ability FROM battle_abilities WHERE id = v_submission.ability_id;

    -- ── b. FORCE_SKIP check (manual submitters not caught in Step 4) ──
    -- Check for NOT consumed force_skip; consumed ones were handled in Step 4.
    SELECT * INTO v_effect
    FROM battle_participant_status_effects
    WHERE participant_id = v_actor.id
      AND effect_type    = 'force_skip'
      AND consumed       = FALSE
    LIMIT 1;

    IF v_effect.id IS NOT NULL THEN
      UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      v_seq := v_seq + 1;
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'auto_selected',
        v_actor.id, 'force_skip_applied'
      );
      CONTINUE;
    END IF;

    -- ── c. Deduct AP; reset momentum if ultimate ──
    UPDATE battle_participants
    SET current_ap = current_ap - v_ability.ap_cost
    WHERE id = v_actor.id;

    IF v_ability.is_ultimate THEN
      UPDATE battle_participants SET momentum = 0 WHERE id = v_actor.id;
    END IF;

    -- ── d. Find opponent active target ──
    SELECT * INTO v_target
    FROM battle_participants
    WHERE match_id    = p_match_id
      AND team_number != v_actor.team_number
      AND is_active   = TRUE
      AND is_fainted  = FALSE
    LIMIT 1;

    IF v_target.id IS NULL THEN
      v_type_mult := 1.00;
      v_damage    := 0;
    ELSE
      -- ── e. Type effectiveness; apply type_reversed if active ──
      -- RIVE HOOK: type_multiplier value drives 'super_effective' or
      --            'resisted' visual overlay in Phase C.
      SELECT multiplier INTO v_type_mult
      FROM battle_type_chart
      WHERE attacker_type = v_actor.archetype
        AND defender_type = v_target.archetype;
      v_type_mult := COALESCE(v_type_mult, 1.00);

      -- Scientist Paradigm Shift: invert type multiplier (0.5↔1.5, 1.0 stays 1.0).
      -- RIVE HOOK: type_reversed active → 'type_reversed_overlay' indicator in Phase C.
      SELECT * INTO v_effect
      FROM battle_participant_status_effects
      WHERE participant_id = v_actor.id
        AND effect_type    = 'type_reversed'
        AND consumed       = FALSE
      LIMIT 1;

      IF v_effect.id IS NOT NULL THEN
        v_type_mult := CASE
          WHEN v_type_mult = 1.50 THEN 0.50
          WHEN v_type_mult = 0.50 THEN 1.50
          ELSE 1.00
        END;
        UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      END IF;

      -- ── f. Magnum Opus: artist ultimate — resistance floor at 1.00 ──
      -- Super effective (1.5) still applies; resisted (0.5) becomes 1.0.
      IF v_ability.rive_animation_key = 'artist_ultimate' THEN
        v_type_mult := GREATEST(v_type_mult, 1.00);
      END IF;

      -- ── g. Base damage ──
      -- Phase D: add map affinity multiplier here (map_multiplier = 1.00 stub).
      v_damage := ROUND(v_ability.base_damage * v_type_mult);

      -- ── h. Save State check on target ──
      -- Gamer Save State: block next incoming hit below effect_value threshold.
      -- RIVE HOOK: blocked hit → 'save_state_blocked' animation in Phase C.
      SELECT * INTO v_effect
      FROM battle_participant_status_effects
      WHERE participant_id = v_target.id
        AND effect_type    = 'save_state'
        AND consumed       = FALSE
      LIMIT 1;

      IF v_effect.id IS NOT NULL AND v_damage > 0 AND v_damage < v_effect.effect_value THEN
        v_damage   := 0;
        v_rive_key := 'save_state_blocked';
        UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
      ELSE
        v_rive_key := v_ability.rive_animation_key;
      END IF;

      -- ── i. Double damage check on actor ──
      -- Actor Award Season: next damage ability deals 2x.
      -- RIVE HOOK: double damage → append '_powered' to rive_animation_key.
      IF v_damage > 0 THEN
        SELECT * INTO v_effect
        FROM battle_participant_status_effects
        WHERE participant_id = v_actor.id
          AND effect_type    = 'double_damage'
          AND consumed       = FALSE
        LIMIT 1;

        IF v_effect.id IS NOT NULL THEN
          v_damage   := v_damage * v_effect.effect_value;
          v_rive_key := v_rive_key || '_powered';
          UPDATE battle_participant_status_effects SET consumed = TRUE WHERE id = v_effect.id;
        END IF;
      END IF;

      -- ── j. Apply damage ──
      IF v_damage > 0 THEN
        UPDATE battle_participants
        SET current_hp = GREATEST(0, current_hp - v_damage)
        WHERE id = v_target.id;
      END IF;
    END IF;

    -- ── k. Momentum gain ──
    -- +10 base, +25 bonus for super effective hit (type_mult >= 1.5, after reversal).
    v_momentum_gain := 10;
    IF v_type_mult >= 1.50 THEN
      v_momentum_gain := v_momentum_gain + 25;
    END IF;

    UPDATE battle_participants
    SET momentum = LEAST(100, momentum + v_momentum_gain)
    WHERE id = v_actor.id;

    -- ── l. Non-damage effects and special ability logic ──

    IF v_ability.effect_type = 'heal' THEN
      IF v_ability.effect_target = 'all_allies' THEN
        UPDATE battle_participants
        SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;
      ELSE
        UPDATE battle_participants
        SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE id = v_actor.id;
      END IF;

    ELSIF v_ability.effect_type = 'drain_ap' THEN
      IF v_target.id IS NOT NULL AND v_ability.effect_target IN ('opponent', 'all_opponents') THEN
        UPDATE battle_participants
        SET current_ap = GREATEST(0, current_ap - v_ability.effect_value)
        WHERE match_id    = p_match_id
          AND team_number != v_actor.team_number
          AND is_fainted  = FALSE;
      END IF;

    ELSIF v_ability.effect_type = 'momentum_boost' THEN
      IF v_ability.effect_target IN ('self', 'ally', 'all_allies') THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;
      ELSIF v_ability.effect_target IN ('opponent', 'all_opponents') THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number != v_actor.team_number
          AND is_fainted  = FALSE;
      END IF;

    ELSIF v_ability.effect_type = 'debuff' THEN
      -- Comedian Crowd Control: applies speed debuff to opponent.
      IF v_target.id IS NOT NULL THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_target.id, v_actor.id,
          'speed_debuff', v_ability.effect_value, v_turn, v_turn + 1, 'status_speed_debuff'
        );
        v_effects_applied := v_effects_applied + 1;
      END IF;

    ELSIF v_ability.effect_type = 'force_skip' THEN
      -- Politician Executive Order: force opponent to skip their next action.
      IF v_target.id IS NOT NULL THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_target.id, v_actor.id,
          'force_skip', 0, v_turn, v_turn + 1, 'status_force_skip'
        );
        v_effects_applied := v_effects_applied + 1;
      END IF;

    ELSIF v_ability.effect_type = 'special' THEN

      -- ── Scientist Hypothesis: reveal opponent's move type ──
      IF v_ability.rive_animation_key = 'scientist_hypothesis' THEN
        DECLARE
          v_opp_sub RECORD;
        BEGIN
          SELECT bts.ability_id, ba.effect_type AS move_category
          INTO v_opp_sub
          FROM battle_turn_submissions bts
          JOIN battle_abilities ba ON ba.id = bts.ability_id
          WHERE bts.match_id      = p_match_id
            AND bts.turn_number   = v_turn
            AND bts.participant_id != v_actor.id
            AND bts.participant_id IN (
              SELECT id FROM battle_participants
              WHERE match_id    = p_match_id
                AND team_number != v_actor.team_number
                AND is_active   = TRUE
            )
          LIMIT 1;

          IF v_opp_sub.ability_id IS NOT NULL THEN
            v_seq := v_seq + 1;
            -- RIVE HOOK: 'hypothesis_reveal' shows opponent move type indicator in Phase C.
            -- Only reveals effect_type category, not the specific ability.
            INSERT INTO battle_events (
              match_id, turn_number, sequence_in_turn, event_type,
              actor_participant_id, target_participant_id, rive_animation_key
            ) VALUES (
              p_match_id, v_turn, v_seq, 'ability_used',
              v_actor.id, v_target.id,
              'hypothesis_reveal_' || COALESCE(v_opp_sub.move_category, 'unknown')
            );
          END IF;
        END;

      -- ── Scientist Paradigm Shift: apply type_reversed to self next turn ──
      ELSIF v_ability.rive_animation_key = 'scientist_ultimate' THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_actor.id, v_actor.id,
          'type_reversed', 0, v_turn, v_turn + 1, 'status_type_reversed'
        );
        v_effects_applied := v_effects_applied + 1;

      -- ── Influencer #1 Trending: force opponent to use lowest-damage ability ──
      ELSIF v_ability.rive_animation_key = 'influencer_ultimate' THEN
        IF v_target.id IS NOT NULL THEN
          INSERT INTO battle_participant_status_effects (
            match_id, participant_id, applied_by_participant_id,
            effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
          ) VALUES (
            p_match_id, v_target.id, v_actor.id,
            'forced_ability', 0, v_turn, v_turn + 1, 'status_forced_ability'
          );
          v_effects_applied := v_effects_applied + 1;
        END IF;

      -- ── Gamer Save State: block next incoming hit below threshold ──
      ELSIF v_ability.rive_animation_key = 'gamer_save_state' THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_actor.id, v_actor.id,
          'save_state', v_ability.effect_value, v_turn, v_turn + 1, 'status_save_state'
        );
        v_effects_applied := v_effects_applied + 1;

      -- ── Actor Director's Cut: copy and execute opponent's last ability ──
      ELSIF v_ability.rive_animation_key = 'actor_directors_cut' THEN
        IF v_target.id IS NOT NULL THEN
          -- Find the last ability the opponent's active character used.
          SELECT ba.* INTO v_last_ability
          FROM battle_events be
          JOIN battle_abilities ba ON ba.id = be.ability_id
          WHERE be.match_id             = p_match_id
            AND be.actor_participant_id = v_target.id
            AND be.event_type           IN ('ability_used', 'ultimate_used')
            AND be.ability_id           IS NOT NULL
          ORDER BY be.created_at DESC
          LIMIT 1;

          IF v_last_ability.id IS NOT NULL AND v_actor.current_ap >= 0 THEN
            DECLARE
              v_copy_type_mult  DECIMAL(3,2);
              v_copy_damage     INTEGER;
              v_copy_target     battle_participants%ROWTYPE;
            BEGIN
              -- Director's Cut fires as actor's archetype for type chart purposes.
              SELECT multiplier INTO v_copy_type_mult
              FROM battle_type_chart
              WHERE attacker_type = v_actor.archetype
                AND defender_type = v_target.archetype;
              v_copy_type_mult := COALESCE(v_copy_type_mult, 1.00);

              v_copy_damage := ROUND(v_last_ability.base_damage * v_copy_type_mult);

              -- Apply copy damage to original target.
              IF v_copy_damage > 0 THEN
                UPDATE battle_participants
                SET current_hp = GREATEST(0, current_hp - v_copy_damage)
                WHERE id = v_target.id;
              END IF;

              v_seq := v_seq + 1;
              -- RIVE HOOK: 'directors_cut_[copied_key]' — shows copied ability animation.
              INSERT INTO battle_events (
                match_id, turn_number, sequence_in_turn, event_type,
                actor_participant_id, target_participant_id,
                ability_id, damage_dealt, hp_after, type_multiplier, map_multiplier,
                rive_animation_key
              ) VALUES (
                p_match_id, v_turn, v_seq, 'ability_used',
                v_actor.id, v_target.id,
                v_last_ability.id, v_copy_damage,
                GREATEST(0, v_target.current_hp - v_copy_damage),
                v_copy_type_mult, 1.00,
                'directors_cut_' || COALESCE(v_last_ability.rive_animation_key, 'unknown')
              );

              -- Re-check KO after copy damage.
              SELECT * INTO v_copy_target FROM battle_participants WHERE id = v_target.id;
              IF v_copy_target.current_hp <= 0 THEN
                UPDATE battle_participants
                SET is_fainted = TRUE, is_active = FALSE
                WHERE id = v_target.id;

                v_seq := v_seq + 1;
                INSERT INTO battle_events (
                  match_id, turn_number, sequence_in_turn, event_type,
                  actor_participant_id, target_participant_id, rive_animation_key
                ) VALUES (
                  p_match_id, v_turn, v_seq, 'ko',
                  v_actor.id, v_target.id, 'ko_faint'
                );

                DECLARE v_next_bench battle_participants%ROWTYPE;
                BEGIN
                  SELECT * INTO v_next_bench
                  FROM battle_participants
                  WHERE match_id    = p_match_id
                    AND team_number = v_target.team_number
                    AND is_fainted  = FALSE
                    AND is_active   = FALSE
                  ORDER BY slot_position ASC LIMIT 1;

                  IF v_next_bench.id IS NOT NULL THEN
                    UPDATE battle_participants SET is_active = TRUE WHERE id = v_next_bench.id;
                    v_seq := v_seq + 1;
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
            END;
          END IF;
        END IF;

      -- ── Actor Award Season: next ability deals double damage ──
      ELSIF v_ability.rive_animation_key = 'actor_ultimate' THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_actor.id, v_actor.id,
          'double_damage', 2, v_turn, v_turn + 2, 'status_double_damage'
        );
        v_effects_applied := v_effects_applied + 1;

      -- ── Musician Encore: repeat last ability next turn (via auto-select override) ──
      ELSIF v_ability.rive_animation_key = 'musician_ultimate' THEN
        INSERT INTO battle_participant_status_effects (
          match_id, participant_id, applied_by_participant_id,
          effect_type, effect_value, applied_at_turn, expires_at_turn, rive_indicator_key
        ) VALUES (
          p_match_id, v_actor.id, v_actor.id,
          'encore', 0, v_turn, v_turn + 1, 'status_encore'
        );
        v_effects_applied := v_effects_applied + 1;

      -- ── Gamer GG EZ ultimate: drain_ap special case (base damage + AP drain) ──
      ELSIF v_ability.rive_animation_key = 'gamer_ultimate' THEN
        IF v_target.id IS NOT NULL THEN
          UPDATE battle_participants
          SET current_ap = GREATEST(0, current_ap - v_ability.effect_value)
          WHERE id = v_target.id;
        END IF;

      -- ── Business Corporate Raid ultimate: same drain_ap handling ──
      ELSIF v_ability.rive_animation_key = 'business_ultimate' THEN
        IF v_target.id IS NOT NULL THEN
          UPDATE battle_participants
          SET current_ap = GREATEST(0, current_ap - v_ability.effect_value)
          WHERE match_id    = p_match_id
            AND team_number != v_actor.team_number
            AND is_fainted  = FALSE;
        END IF;

      -- ── Politician Campaign Promise ultimate: heal all allies ──
      ELSIF v_ability.rive_animation_key = 'politician_ultimate' THEN
        UPDATE battle_participants
        SET current_hp = LEAST(max_hp, current_hp + v_ability.effect_value)
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;

      -- ── Athlete Gold Medal Moment ultimate: momentum boost all allies ──
      ELSIF v_ability.rive_animation_key = 'athlete_ultimate' THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number = v_actor.team_number
          AND is_fainted  = FALSE;

      -- ── Comedian Standing Ovation ultimate: drain opponent momentum ──
      ELSIF v_ability.rive_animation_key = 'comedian_ultimate' THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE match_id    = p_match_id
          AND team_number != v_actor.team_number
          AND is_fainted  = FALSE;

      -- ── Influencer Going Live: self momentum boost ──
      ELSIF v_ability.rive_animation_key = 'influencer_going_live' THEN
        UPDATE battle_participants
        SET momentum = LEAST(100, GREATEST(0, momentum + v_ability.effect_value))
        WHERE id = v_actor.id;

      -- ── Scientist Hypothesis (non-ultimate slot 3): handled above in scientist_hypothesis ──
      -- ── All other 'special' abilities: no additional effect beyond base damage ──
      ELSE
        NULL;
      END IF;

    END IF; -- end effect_type dispatch

    -- ── m. Reload actor and target; build and insert event ──
    SELECT * INTO v_actor FROM battle_participants WHERE id = v_actor.id;
    IF v_target.id IS NOT NULL THEN
      SELECT * INTO v_target FROM battle_participants WHERE id = v_target.id;
    END IF;

    -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
    --            the matching Rive state machine input for this event.
    -- v_rive_key was set above; falls back to ability key if not overridden.
    IF v_rive_key IS NULL THEN
      v_rive_key := v_ability.rive_animation_key;
    END IF;

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

    -- Reset v_rive_key for next iteration.
    v_rive_key := NULL;

    -- ── n. Auto-selected event marker; player_disconnected for automated ──
    IF v_submission.was_auto_selected THEN
      v_seq := v_seq + 1;
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'auto_selected',
        v_actor.id,
        -- RIVE HOOK: 'player_disconnected' shows disconnect overlay in Phase C.
        CASE WHEN v_actor.is_automated THEN 'player_disconnected' ELSE 'auto_selected' END
      );
    END IF;

    -- ── o. KO check → faint + forced swap ──
    IF v_target.id IS NOT NULL AND v_target.current_hp <= 0 THEN
      UPDATE battle_participants
      SET is_fainted = TRUE, is_active = FALSE
      WHERE id = v_target.id;

      v_seq := v_seq + 1;
      -- RIVE HOOK: 'ko_faint' triggers KO animation for the downed character.
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, target_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'ko',
        v_actor.id, v_target.id, 'ko_faint'
      );

      DECLARE v_next_bench battle_participants%ROWTYPE;
      BEGIN
        SELECT * INTO v_next_bench
        FROM battle_participants
        WHERE match_id    = p_match_id
          AND team_number = v_target.team_number
          AND is_fainted  = FALSE
          AND is_active   = FALSE
        ORDER BY slot_position ASC LIMIT 1;

        IF v_next_bench.id IS NOT NULL THEN
          UPDATE battle_participants SET is_active = TRUE WHERE id = v_next_bench.id;
          v_seq := v_seq + 1;
          -- RIVE HOOK: 'swap_forced' triggers forced swap-in animation.
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

    -- ── p. Ultimate ready notification ──
    IF v_actor.momentum = 100 AND NOT v_ability.is_ultimate THEN
      v_seq := v_seq + 1;
      -- RIVE HOOK: 'ultimate_ready' triggers momentum-full glow animation.
      INSERT INTO battle_events (
        match_id, turn_number, sequence_in_turn, event_type,
        actor_participant_id, rive_animation_key
      ) VALUES (
        p_match_id, v_turn, v_seq, 'ultimate_ready',
        v_actor.id, 'ultimate_ready'
      );
    END IF;

    -- Accumulate effects count for telemetry.
    v_total_effects := v_total_effects + v_effects_applied;
    v_effects_applied := 0;

  END LOOP; -- end attack loop

  -- ============================================================
  -- 9. WIN CONDITION CHECK
  -- ============================================================
  SELECT COUNT(*) INTO v_team1_alive
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 1 AND is_fainted = FALSE;

  SELECT COUNT(*) INTO v_team2_alive
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 2 AND is_fainted = FALSE;

  IF v_team1_alive = 0 OR v_team2_alive = 0 THEN
    v_winner_team := CASE WHEN v_team1_alive > 0 THEN 1 ELSE 2 END;

    -- ── Spectator bet settlement ──
    -- token_balances uses available_tokens column (NOT balance).
    DECLARE
      v_bet            RECORD;
      v_winner_count   INTEGER;
      v_total_pool     INTEGER;
      v_winner_payout  INTEGER;
    BEGIN
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
          SELECT * FROM battle_spectator_bets
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
        SELECT * FROM battle_spectator_bets
        WHERE match_id    = p_match_id
          AND team_number != v_winner_team
          AND status      = 'lost'
          AND payout      = 0
      LOOP
        INSERT INTO token_transactions (user_id, type, amount, reference_id)
        VALUES (v_bet.user_id, 'bet_lost', 0, v_bet.id);
      END LOOP;
    END;

    -- ── Telemetry ──
    INSERT INTO battle_match_telemetry (
      match_id, turn_count, winning_archetypes, losing_archetypes,
      map_id, ultimates_used, auto_selections, match_duration_seconds,
      status_effects_applied
    )
    SELECT
      p_match_id,
      v_turn,
      ARRAY(SELECT archetype FROM battle_participants WHERE match_id = p_match_id AND team_number = v_winner_team),
      ARRAY(SELECT archetype FROM battle_participants WHERE match_id = p_match_id AND team_number != v_winner_team),
      v_match.map_id,
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'ultimate_used'),
      (SELECT COUNT(*)::INTEGER FROM battle_events WHERE match_id = p_match_id AND event_type = 'auto_selected'),
      EXTRACT(EPOCH FROM (NOW() - v_match.started_at))::INTEGER,
      v_total_effects;

    -- ── Close match ──
    UPDATE battle_matches
    SET status             = 'resolved',
        winner_team_number = v_winner_team,
        resolved_at        = NOW()
    WHERE id = p_match_id;

    v_seq := v_seq + 1;
    -- RIVE HOOK: 'match_end_victory' triggers victory/defeat screen animations.
    INSERT INTO battle_events (
      match_id, turn_number, sequence_in_turn, event_type, rive_animation_key
    ) VALUES (
      p_match_id, v_turn, v_seq, 'match_end', 'match_end_victory'
    );

    RETURN;
  END IF;

  -- ── 10. Advance to next turn ──
  UPDATE battle_matches
  SET current_turn  = current_turn + 1,
      turn_deadline = NOW() + (turn_duration_seconds * INTERVAL '1 second')
  WHERE id = p_match_id;

END;
$$ LANGUAGE plpgsql;
