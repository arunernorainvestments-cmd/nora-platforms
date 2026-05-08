-- Migration 066: Battle Mode Phase B — RPCs
-- battle_heartbeat, battle_reconnect, battle_forfeit

-- ============================================================
-- battle_heartbeat
-- Client calls every 30 seconds while in an active match.
-- Keeps last_seen_at fresh to prevent is_automated from flipping.
-- ============================================================
CREATE OR REPLACE FUNCTION battle_heartbeat(p_match_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE battle_participants
  SET last_seen_at  = NOW(),
      is_automated  = FALSE
  WHERE match_id = p_match_id
    AND user_id   = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_reconnect
-- Client calls on reconnect after disconnect.
-- Re-enables manual control; does not undo auto-selected moves
-- already processed by the turn engine.
-- Returns current match state for client to resync.
-- ============================================================
CREATE OR REPLACE FUNCTION battle_reconnect(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_participant  battle_participants%ROWTYPE;
  v_match        battle_matches%ROWTYPE;
BEGIN
  SELECT * INTO v_match FROM battle_matches WHERE id = p_match_id;
  IF v_match.id IS NULL THEN
    RAISE EXCEPTION 'Match not found';
  END IF;

  SELECT * INTO v_participant
  FROM battle_participants
  WHERE match_id = p_match_id AND user_id = auth.uid();

  IF v_participant.id IS NULL THEN
    RAISE EXCEPTION 'You are not a participant in this match';
  END IF;

  UPDATE battle_participants
  SET is_automated  = FALSE,
      last_seen_at  = NOW()
  WHERE id = v_participant.id;

  RETURN jsonb_build_object(
    'match_id',      p_match_id,
    'status',        v_match.status,
    'current_turn',  v_match.current_turn,
    'turn_deadline', v_match.turn_deadline,
    'participant_id', v_participant.id,
    'current_hp',    v_participant.current_hp,
    'current_ap',    v_participant.current_ap,
    'momentum',      v_participant.momentum,
    'is_active',     v_participant.is_active,
    'is_fainted',    v_participant.is_fainted
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_forfeit
-- Any participant can forfeit for their entire team.
-- Immediately resolves the match, settles spectator bets,
-- emits a match_end event with rive key 'match_end_forfeit'.
-- token_balances uses available_tokens column (NOT balance).
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

  -- ── Spectator bet settlement (same logic as turn engine win condition) ──
  -- token_balances column is available_tokens, not balance.
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

  -- Mark losing bets.
  UPDATE battle_spectator_bets
  SET status = 'lost', payout = 0
  WHERE match_id    = p_match_id
    AND team_number != v_winner_team
    AND status      = 'pending';

  -- Log bet_lost transactions for losing bettors.
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

  -- ── Resolve match ──
  UPDATE battle_matches
  SET status             = 'resolved',
      winner_team_number = v_winner_team,
      resolved_at        = NOW()
  WHERE id = p_match_id;

  -- ── Forfeit event ──
  -- RIVE HOOK: Phase C Flutter controller reads this key and triggers
  --            the matching Rive state machine input for this event.
  -- 'match_end_forfeit' plays the forfeit animation in Phase C.
  INSERT INTO battle_events (
    match_id, turn_number, sequence_in_turn, event_type,
    actor_participant_id, rive_animation_key
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
