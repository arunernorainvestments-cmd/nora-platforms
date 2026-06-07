-- Migration 099: Fix battle_start_match — set timeframe on the auto-created market
--
-- markets.timeframe is NOT NULL with no default. battle_start_match() (migration
-- 091) inserts the battle_outcome market without a timeframe, so every real call
-- raises a NOT NULL violation and the match fails to start. (Unnoticed until now
-- because the Flutter battle screen uses a 'test-match' placeholder that never
-- calls this RPC.) Set timeframe='24h' (aligns with the 24h end_at safety window)
-- and duration_label='1day' (passes markets_duration_label_check) so battle
-- markets create cleanly and render with a sensible label.
--
-- Body reproduced verbatim from 091 except the two added columns/values.

CREATE OR REPLACE FUNCTION battle_start_match(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_map_id          UUID;
  v_team1_count     INTEGER;
  v_team2_count     INTEGER;
  v_expected_slots  INTEGER;
  v_market_id       UUID;
  v_char_name_1     TEXT;
  v_char_name_2     TEXT;
  v_char_creator_id UUID;
BEGIN
  -- Only host can start, and only from lobby state.
  IF NOT EXISTS (
    SELECT 1 FROM battle_matches
    WHERE id = p_match_id AND host_user_id = auth.uid() AND status = 'lobby'
  ) THEN
    RAISE EXCEPTION 'Only the host can start, or match already started';
  END IF;

  -- Format-aware slot count validation
  SELECT CASE format WHEN '1v1' THEN 1 WHEN '2v2' THEN 2 ELSE 3 END
  INTO v_expected_slots FROM battle_matches WHERE id = p_match_id;

  SELECT COUNT(*) INTO v_team1_count FROM battle_participants WHERE match_id = p_match_id AND team_number = 1;
  SELECT COUNT(*) INTO v_team2_count FROM battle_participants WHERE match_id = p_match_id AND team_number = 2;

  IF v_team1_count != v_expected_slots OR v_team2_count != v_expected_slots THEN
    RAISE EXCEPTION 'Each team needs % player(s) for this format', v_expected_slots;
  END IF;

  -- Random map selection.
  SELECT id INTO v_map_id FROM battle_maps WHERE active = TRUE ORDER BY RANDOM() LIMIT 1;

  -- Activate slot 1 for each team.
  UPDATE battle_participants SET is_active = TRUE WHERE match_id = p_match_id AND slot_position = 1;

  -- Snapshot effective stats into snap_* columns (NULL creator_id = 50 default)
  UPDATE battle_participants bp
  SET
    snap_power      = COALESCE(css.effective_power,      50),
    snap_charisma   = COALESCE(css.effective_charisma,   50),
    snap_resilience = COALESCE(css.effective_resilience, 50),
    snap_agility    = COALESCE(css.effective_agility,    50),
    snap_wit        = COALESCE(css.effective_wit,        50),
    snap_influence  = COALESCE(css.effective_influence,  50)
  FROM creator_stat_sheets css
  WHERE css.user_id = bp.creator_id AND bp.match_id = p_match_id;

  -- Recalculate speed from snap_agility (±20% of archetype base)
  UPDATE battle_participants
  SET speed = ROUND(
    battle_get_archetype_speed(archetype)
    * (0.8 + (snap_agility::float / 300.0) * 0.4)
  )
  WHERE match_id = p_match_id;

  -- Start match, set first turn deadline.
  UPDATE battle_matches
  SET status = 'active', map_id = v_map_id, current_turn = 1,
      turn_deadline = NOW() + INTERVAL '30 seconds', started_at = NOW()
  WHERE id = p_match_id;

  -- Auto-create linked prediction market
  SELECT COALESCE(bp.character_name, p.display_name, p.username)
  INTO v_char_name_1
  FROM battle_participants bp LEFT JOIN profiles p ON p.id = bp.creator_id
  WHERE bp.match_id = p_match_id AND bp.team_number = 1 AND bp.slot_position = 1;

  SELECT COALESCE(bp.character_name, p.display_name, p.username)
  INTO v_char_name_2
  FROM battle_participants bp LEFT JOIN profiles p ON p.id = bp.creator_id
  WHERE bp.match_id = p_match_id AND bp.team_number = 2 AND bp.slot_position = 1;

  SELECT bp.creator_id INTO v_char_creator_id
  FROM battle_participants bp
  WHERE bp.match_id = p_match_id AND bp.team_number = 1 AND bp.slot_position = 1;

  INSERT INTO markets (
    creator_id, opened_by, title, status, timeframe, duration_label,
    opening_resolution_score, yes_pool, no_pool,
    end_at, resolution_type, battle_match_id
  ) VALUES (
    COALESCE(v_char_creator_id, auth.uid()),
    auth.uid(),
    'Battle: ' || COALESCE(v_char_name_1, 'Team 1') || ' vs ' || COALESCE(v_char_name_2, 'Team 2'),
    'open',
    '24h',
    '1day',
    0, 0, 0,
    NOW() + INTERVAL '24 hours',
    'battle_outcome',
    p_match_id
  ) RETURNING id INTO v_market_id;

  RETURN jsonb_build_object(
    'match_id',     p_match_id,
    'map_id',       v_map_id,
    'status',       'active',
    'current_turn', 1,
    'market_id',    v_market_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
