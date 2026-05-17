-- Migration 070: battle_start_match_dev
-- Drops the 3-per-team requirement so 1v1 matches can start for testing.
-- Production flow still uses battle_start_match (requires 3v3).

CREATE OR REPLACE FUNCTION battle_start_match_dev(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_map_id      UUID;
  v_team1_count INTEGER;
  v_team2_count INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM battle_matches
    WHERE id = p_match_id
      AND host_user_id = auth.uid()
      AND status = 'lobby'
  ) THEN
    RAISE EXCEPTION 'Only the host can start, or match already started';
  END IF;

  SELECT COUNT(*) INTO v_team1_count
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 1;

  SELECT COUNT(*) INTO v_team2_count
  FROM battle_participants
  WHERE match_id = p_match_id AND team_number = 2;

  IF v_team1_count < 1 OR v_team2_count < 1 THEN
    RAISE EXCEPTION 'Need at least 1 player per team to start';
  END IF;

  SELECT id INTO v_map_id
  FROM battle_maps
  WHERE active = TRUE
  ORDER BY RANDOM()
  LIMIT 1;

  UPDATE battle_participants
  SET is_active = TRUE
  WHERE match_id = p_match_id AND slot_position = 1;

  UPDATE battle_matches
  SET
    status        = 'active',
    map_id        = v_map_id,
    current_turn  = 1,
    turn_deadline = NOW() + INTERVAL '30 seconds',
    started_at    = NOW()
  WHERE id = p_match_id;

  RETURN jsonb_build_object(
    'match_id',     p_match_id,
    'status',       'active',
    'current_turn', 1
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
