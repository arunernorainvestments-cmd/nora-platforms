-- Migration 062: Battle Mode Phase A — RPCs
-- battle_get_archetype_speed, battle_create_lobby, battle_join_lobby,
-- battle_start_match, battle_submit_turn, battle_place_spectator_bet

-- ============================================================
-- Helper: archetype speed lookup
-- ============================================================
CREATE OR REPLACE FUNCTION battle_get_archetype_speed(p_archetype TEXT)
RETURNS INTEGER AS $$
BEGIN
  RETURN CASE p_archetype
    WHEN 'athlete'    THEN 90
    WHEN 'gamer'      THEN 85
    WHEN 'influencer' THEN 75
    WHEN 'actor'      THEN 70
    WHEN 'comedian'   THEN 65
    WHEN 'musician'   THEN 60
    WHEN 'artist'     THEN 55
    WHEN 'scientist'  THEN 50
    WHEN 'business'   THEN 45
    WHEN 'politician' THEN 40
    ELSE 50
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- battle_create_lobby
-- Creates a new match in 'lobby' status and joins the caller
-- as team 1, slot 1.
-- Returns: { match_id, lobby_code, participant_id }
-- ============================================================
CREATE OR REPLACE FUNCTION battle_create_lobby(
  p_archetype       TEXT,
  p_character_name  TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_match_id       UUID;
  v_lobby_code     TEXT;
  v_participant_id UUID;
BEGIN
  -- Generate unique 6-character uppercase lobby code.
  LOOP
    v_lobby_code := UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM battle_matches WHERE lobby_code = v_lobby_code
    );
  END LOOP;

  INSERT INTO battle_matches (lobby_code, host_user_id)
  VALUES (v_lobby_code, auth.uid())
  RETURNING id INTO v_match_id;

  -- Host joins as team 1, slot 1 (bench until match starts).
  INSERT INTO battle_participants
    (match_id, user_id, team_number, slot_position, archetype, character_name,
     max_hp, current_hp, max_ap, current_ap, speed, is_active)
  VALUES
    (v_match_id, auth.uid(), 1, 1, p_archetype, p_character_name,
     150, 150, 50, 50, battle_get_archetype_speed(p_archetype), FALSE)
  RETURNING id INTO v_participant_id;

  RETURN jsonb_build_object(
    'match_id',       v_match_id,
    'lobby_code',     v_lobby_code,
    'participant_id', v_participant_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_join_lobby
-- Joins an existing lobby by code. Assigns the caller to the
-- next available slot on the requested team.
-- Returns: { match_id, participant_id, team_number, slot_position }
-- ============================================================
CREATE OR REPLACE FUNCTION battle_join_lobby(
  p_lobby_code      TEXT,
  p_archetype       TEXT,
  p_character_name  TEXT,
  p_team_number     INTEGER  -- 1 or 2
)
RETURNS JSONB AS $$
DECLARE
  v_match_id       UUID;
  v_slot           INTEGER;
  v_participant_id UUID;
BEGIN
  SELECT id INTO v_match_id
  FROM battle_matches
  WHERE lobby_code = UPPER(p_lobby_code) AND status = 'lobby';

  IF v_match_id IS NULL THEN
    RAISE EXCEPTION 'Lobby not found or already started';
  END IF;

  IF p_team_number NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Team number must be 1 or 2';
  END IF;

  -- Find next available slot on this team.
  SELECT COALESCE(MAX(slot_position), 0) + 1 INTO v_slot
  FROM battle_participants
  WHERE match_id = v_match_id AND team_number = p_team_number;

  IF v_slot > 3 THEN
    RAISE EXCEPTION 'Team % is full', p_team_number;
  END IF;

  -- Prevent duplicate joins.
  IF EXISTS (
    SELECT 1 FROM battle_participants
    WHERE match_id = v_match_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Already joined this match';
  END IF;

  INSERT INTO battle_participants
    (match_id, user_id, team_number, slot_position, archetype, character_name,
     max_hp, current_hp, max_ap, current_ap, speed, is_active)
  VALUES
    (v_match_id, auth.uid(), p_team_number, v_slot, p_archetype, p_character_name,
     150, 150, 50, 50, battle_get_archetype_speed(p_archetype), FALSE)
  RETURNING id INTO v_participant_id;

  RETURN jsonb_build_object(
    'match_id',       v_match_id,
    'participant_id', v_participant_id,
    'team_number',    p_team_number,
    'slot_position',  v_slot
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_start_match
-- Host-only. Requires exactly 3 players per team. Selects a
-- random map, activates slot 1 for each team, sets turn 1.
-- Returns: { match_id, map_id, status, current_turn }
-- ============================================================
CREATE OR REPLACE FUNCTION battle_start_match(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_map_id         UUID;
  v_team1_count    INTEGER;
  v_team2_count    INTEGER;
BEGIN
  -- Only host can start, and only from lobby state.
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

  IF v_team1_count != 3 OR v_team2_count != 3 THEN
    RAISE EXCEPTION 'Both teams must have exactly 3 players to start';
  END IF;

  -- Random map selection.
  SELECT id INTO v_map_id
  FROM battle_maps
  WHERE active = TRUE
  ORDER BY RANDOM()
  LIMIT 1;

  -- Activate slot 1 players for each team.
  UPDATE battle_participants
  SET is_active = TRUE
  WHERE match_id = p_match_id AND slot_position = 1;

  -- Start match, set first turn deadline.
  UPDATE battle_matches
  SET
    status                = 'active',
    map_id                = v_map_id,
    current_turn          = 1,
    turn_deadline         = NOW() + INTERVAL '30 seconds',
    started_at            = NOW()
  WHERE id = p_match_id;

  RETURN jsonb_build_object(
    'match_id',     p_match_id,
    'map_id',       v_map_id,
    'status',       'active',
    'current_turn', 1
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_submit_turn
-- Submit an action (ability OR voluntary swap) for the current turn.
-- Validates: match active, caller has active character, AP sufficient,
-- momentum sufficient for ultimates, valid swap target.
-- UNIQUE constraint prevents double-submit.
-- Returns: { submitted: true, turn: <n> }
-- ============================================================
CREATE OR REPLACE FUNCTION battle_submit_turn(
  p_match_id                UUID,
  p_ability_id              UUID DEFAULT NULL,
  p_swap_to_participant_id  UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_participant  battle_participants%ROWTYPE;
  v_ability      battle_abilities%ROWTYPE;
  v_current_turn INTEGER;
BEGIN
  -- Validate match is active.
  SELECT current_turn INTO v_current_turn
  FROM battle_matches
  WHERE id = p_match_id AND status = 'active';

  IF v_current_turn IS NULL THEN
    RAISE EXCEPTION 'Match is not active';
  END IF;

  -- Get this user's active, non-fainted participant.
  SELECT * INTO v_participant
  FROM battle_participants
  WHERE match_id = p_match_id
    AND user_id = auth.uid()
    AND is_active = TRUE;

  IF v_participant.id IS NULL THEN
    RAISE EXCEPTION 'You do not have an active character in this match';
  END IF;

  IF v_participant.is_fainted THEN
    RAISE EXCEPTION 'Your active character has fainted';
  END IF;

  -- Validate: exactly one action type provided.
  IF (p_ability_id IS NULL) = (p_swap_to_participant_id IS NULL) THEN
    RAISE EXCEPTION 'Provide exactly one of ability_id or swap_to_participant_id';
  END IF;

  -- Validate ability if using one.
  IF p_ability_id IS NOT NULL THEN
    SELECT * INTO v_ability FROM battle_abilities WHERE id = p_ability_id;

    IF v_ability.id IS NULL THEN
      RAISE EXCEPTION 'Ability not found';
    END IF;

    IF v_ability.archetype != v_participant.archetype THEN
      RAISE EXCEPTION 'Ability does not belong to your archetype';
    END IF;

    IF v_participant.current_ap < v_ability.ap_cost THEN
      RAISE EXCEPTION 'Insufficient AP';
    END IF;

    IF v_ability.requires_momentum AND v_participant.momentum < 100 THEN
      RAISE EXCEPTION 'Ultimate requires 100 momentum';
    END IF;
  END IF;

  -- Validate swap target: must be on same team, alive, and on bench.
  IF p_swap_to_participant_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM battle_participants
      WHERE id           = p_swap_to_participant_id
        AND match_id     = p_match_id
        AND team_number  = v_participant.team_number
        AND is_fainted   = FALSE
        AND is_active    = FALSE
    ) THEN
      RAISE EXCEPTION 'Invalid swap target';
    END IF;
  END IF;

  -- Insert submission. UNIQUE constraint prevents double-submit.
  INSERT INTO battle_turn_submissions
    (match_id, turn_number, participant_id, user_id,
     ability_id, swap_to_participant_id)
  VALUES
    (p_match_id, v_current_turn, v_participant.id, auth.uid(),
     p_ability_id, p_swap_to_participant_id)
  ON CONFLICT (match_id, turn_number, participant_id)
    DO NOTHING;

  RETURN jsonb_build_object('submitted', TRUE, 'turn', v_current_turn);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- battle_place_spectator_bet
-- Spectators (non-participants) bet on a team while match is active.
-- Deducts tokens from token_balances.available_tokens, logs to
-- token_transactions, and adds to match spectator_pool.
-- Returns: { bet_id, tokens_wagered }
-- ============================================================
CREATE OR REPLACE FUNCTION battle_place_spectator_bet(
  p_match_id       UUID,
  p_team_number    INTEGER,
  p_tokens_wagered INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_balance INTEGER;
  v_bet_id  UUID;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM battle_matches
    WHERE id = p_match_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Match is not active or does not exist';
  END IF;

  -- Participants cannot bet on their own match.
  IF EXISTS (
    SELECT 1 FROM battle_participants
    WHERE match_id = p_match_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Match participants cannot place spectator bets';
  END IF;

  -- Check token balance. token_balances uses available_tokens column.
  SELECT available_tokens INTO v_balance
  FROM token_balances
  WHERE user_id = auth.uid();

  IF COALESCE(v_balance, 0) < p_tokens_wagered THEN
    RAISE EXCEPTION 'Insufficient token balance';
  END IF;

  -- Deduct tokens.
  UPDATE token_balances
  SET available_tokens = available_tokens - p_tokens_wagered
  WHERE user_id = auth.uid();

  -- Record the bet.
  INSERT INTO battle_spectator_bets
    (match_id, user_id, team_number, tokens_wagered)
  VALUES
    (p_match_id, auth.uid(), p_team_number, p_tokens_wagered)
  RETURNING id INTO v_bet_id;

  -- Log token movement. bet_placed is an existing valid type.
  INSERT INTO token_transactions (user_id, type, amount, reference_id)
  VALUES (auth.uid(), 'bet_placed', -p_tokens_wagered, v_bet_id);

  -- Add to match spectator pool.
  UPDATE battle_matches
  SET spectator_pool = spectator_pool + p_tokens_wagered
  WHERE id = p_match_id;

  RETURN jsonb_build_object(
    'bet_id',         v_bet_id,
    'tokens_wagered', p_tokens_wagered
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
