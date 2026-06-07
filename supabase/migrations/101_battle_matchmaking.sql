-- Migration 101: Battle matchmaking queue (1v1/2v2/3v3) + likeness-aware start
--
-- Adds a format-based matchmaking queue. Players enqueue with an eligible
-- character (self if market maker, or a creator whose active likeness card they
-- own). When enough players for a format are queued, a battle_match is created
-- with participants carrying creator_id + likeness_card_id, and the match is
-- auto-started (stats snapshot + battle_outcome prediction market opens).
--
-- battle_start_match is refactored into a host-checked wrapper + an internal
-- starter so matchmaking can start a match it created without an interactive host.

-- ── 1. Internal starter (no host/lobby auth check) ───────────────────────────
CREATE OR REPLACE FUNCTION battle_start_match_internal(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_map_id          UUID;
  v_market_id       UUID;
  v_char_name_1     TEXT;
  v_char_name_2     TEXT;
  v_char_creator_id UUID;
BEGIN
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

  -- Auto-create linked prediction market (team_1 = yes_pool, team_2 = no_pool)
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
    COALESCE(v_char_creator_id, (SELECT host_user_id FROM battle_matches WHERE id = p_match_id)),
    (SELECT host_user_id FROM battle_matches WHERE id = p_match_id),
    'Battle: ' || COALESCE(v_char_name_1, 'Team 1') || ' vs ' || COALESCE(v_char_name_2, 'Team 2'),
    'open', '24h', '1day',
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

-- ── 2. Host-checked wrapper (preserves existing lobby flow) ──────────────────
CREATE OR REPLACE FUNCTION battle_start_match(p_match_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_expected_slots INTEGER;
  v_team1_count    INTEGER;
  v_team2_count    INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM battle_matches
    WHERE id = p_match_id AND host_user_id = auth.uid() AND status = 'lobby'
  ) THEN
    RAISE EXCEPTION 'Only the host can start, or match already started';
  END IF;

  SELECT CASE format WHEN '1v1' THEN 1 WHEN '2v2' THEN 2 ELSE 3 END
  INTO v_expected_slots FROM battle_matches WHERE id = p_match_id;

  SELECT COUNT(*) INTO v_team1_count FROM battle_participants WHERE match_id = p_match_id AND team_number = 1;
  SELECT COUNT(*) INTO v_team2_count FROM battle_participants WHERE match_id = p_match_id AND team_number = 2;

  IF v_team1_count != v_expected_slots OR v_team2_count != v_expected_slots THEN
    RAISE EXCEPTION 'Each team needs % player(s) for this format', v_expected_slots;
  END IF;

  RETURN battle_start_match_internal(p_match_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3. Matchmaking queue table ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS battle_matchmaking_queue (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID NOT NULL REFERENCES auth.users(id),
  format           TEXT NOT NULL CHECK (format IN ('1v1', '2v2', '3v3')),
  creator_id       UUID NOT NULL REFERENCES auth.users(id),  -- character's market maker (self if user is a maker)
  likeness_card_id UUID REFERENCES likeness_cards(id),       -- NULL when fielding self
  archetype        TEXT NOT NULL,
  character_name   TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'queued'
                     CHECK (status IN ('queued', 'matched', 'cancelled')),
  matched_match_id UUID REFERENCES battle_matches(id),
  enqueued_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One active queue entry per user.
CREATE UNIQUE INDEX IF NOT EXISTS battle_queue_one_active
  ON battle_matchmaking_queue (user_id) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS battle_queue_format_idx
  ON battle_matchmaking_queue (format, enqueued_at) WHERE status = 'queued';

ALTER TABLE battle_matchmaking_queue ENABLE ROW LEVEL SECURITY;

-- Users read their own queue rows (to detect matched_match_id). Public read of
-- queued rows is allowed for live counts (no sensitive data).
DROP POLICY IF EXISTS battle_queue_read ON battle_matchmaking_queue;
CREATE POLICY battle_queue_read ON battle_matchmaking_queue
  FOR SELECT USING (TRUE);

-- Writes go exclusively through SECURITY DEFINER RPCs; no direct client writes.

-- Realtime so clients can watch their row flip to 'matched'.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'battle_matchmaking_queue'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.battle_matchmaking_queue;
  END IF;
END $$;

-- ── 4. Try to form a match for a format ──────────────────────────────────────
CREATE OR REPLACE FUNCTION battle_try_matchmake(p_format TEXT)
RETURNS UUID AS $$
DECLARE
  v_slots        INTEGER;
  v_needed       INTEGER;
  v_match_id     UUID;
  v_lobby_code   TEXT;
  v_host         UUID;
  v_rows         UUID[];
  v_row          RECORD;
  v_idx          INTEGER := 0;
  v_team         INTEGER;
  v_slot         INTEGER;
BEGIN
  v_slots  := CASE p_format WHEN '1v1' THEN 1 WHEN '2v2' THEN 2 ELSE 3 END;
  v_needed := v_slots * 2;

  -- Lock the oldest queued rows for this format.
  SELECT array_agg(id ORDER BY enqueued_at)
  INTO v_rows
  FROM (
    SELECT id, enqueued_at
    FROM battle_matchmaking_queue
    WHERE status = 'queued' AND format = p_format
    ORDER BY enqueued_at
    LIMIT v_needed
    FOR UPDATE SKIP LOCKED
  ) q;

  IF v_rows IS NULL OR array_length(v_rows, 1) < v_needed THEN
    RETURN NULL;  -- not enough players yet
  END IF;

  -- Host = first enqueued player.
  SELECT user_id INTO v_host FROM battle_matchmaking_queue WHERE id = v_rows[1];

  LOOP
    v_lobby_code := UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM battle_matches WHERE lobby_code = v_lobby_code);
  END LOOP;

  INSERT INTO battle_matches (lobby_code, host_user_id, status, format)
  VALUES (v_lobby_code, v_host, 'lobby', p_format)
  RETURNING id INTO v_match_id;

  -- Assign players: first half → team 1, second half → team 2.
  FOR v_row IN
    SELECT * FROM battle_matchmaking_queue
    WHERE id = ANY(v_rows) ORDER BY enqueued_at
  LOOP
    v_team := CASE WHEN v_idx < v_slots THEN 1 ELSE 2 END;
    v_slot := (v_idx % v_slots) + 1;

    INSERT INTO battle_participants
      (match_id, user_id, team_number, slot_position, archetype, character_name,
       max_hp, current_hp, max_ap, current_ap, speed, momentum, is_active,
       creator_id, likeness_card_id)
    VALUES
      (v_match_id, v_row.user_id, v_team, v_slot, v_row.archetype, v_row.character_name,
       150, 150, 50, 50, battle_get_archetype_speed(v_row.archetype), 0, FALSE,
       v_row.creator_id, v_row.likeness_card_id);

    UPDATE battle_matchmaking_queue
    SET status = 'matched', matched_match_id = v_match_id
    WHERE id = v_row.id;

    v_idx := v_idx + 1;
  END LOOP;

  -- Auto-start (snapshot stats + open prediction market).
  PERFORM battle_start_match_internal(v_match_id);

  RETURN v_match_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. Enqueue with an eligible character ────────────────────────────────────
CREATE OR REPLACE FUNCTION battle_enqueue(
  p_format     TEXT,
  p_creator_id UUID
)
RETURNS JSONB AS $$
DECLARE
  v_user       UUID := auth.uid();
  v_elig       RECORD;
  v_archetype  TEXT;
  v_char_name  TEXT;
  v_match_id   UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_format NOT IN ('1v1', '2v2', '3v3') THEN RAISE EXCEPTION 'Invalid format'; END IF;

  -- Eligibility (self = market maker, owner = holds active card for the creator).
  SELECT * INTO v_elig FROM check_battle_eligibility(v_user, p_creator_id);
  IF NOT v_elig.is_eligible THEN
    RAISE EXCEPTION 'You are not eligible to field this character';
  END IF;

  -- Resolve character name + archetype.
  IF v_elig.eligibility_type = 'self' THEN
    SELECT LOWER(COALESCE(category_1, 'influencer')), COALESCE(display_name, username)
    INTO v_archetype, v_char_name
    FROM profiles WHERE id = p_creator_id;
  ELSE
    SELECT lo.archetype, lo.character_name
    INTO v_archetype, v_char_name
    FROM likeness_cards lc JOIN likeness_offerings lo ON lo.id = lc.offering_id
    WHERE lc.id = v_elig.card_id;
  END IF;

  v_archetype := COALESCE(v_archetype, 'influencer');
  v_char_name := COALESCE(v_char_name, 'Challenger');

  -- Replace any existing queued entry for this user.
  UPDATE battle_matchmaking_queue SET status = 'cancelled'
  WHERE user_id = v_user AND status = 'queued';

  INSERT INTO battle_matchmaking_queue
    (user_id, format, creator_id, likeness_card_id, archetype, character_name)
  VALUES
    (v_user, p_format, p_creator_id, v_elig.card_id, v_archetype, v_char_name);

  -- Attempt to form a match immediately.
  v_match_id := battle_try_matchmake(p_format);

  RETURN jsonb_build_object(
    'status',   CASE WHEN v_match_id IS NULL THEN 'queued' ELSE 'matched' END,
    'match_id', v_match_id,
    'format',   p_format
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 6. Leave the queue ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION battle_leave_queue()
RETURNS void AS $$
BEGIN
  UPDATE battle_matchmaking_queue SET status = 'cancelled'
  WHERE user_id = auth.uid() AND status = 'queued';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION battle_enqueue(TEXT, UUID)        TO authenticated;
GRANT EXECUTE ON FUNCTION battle_leave_queue()             TO authenticated;
GRANT EXECUTE ON FUNCTION battle_try_matchmake(TEXT)       TO authenticated;
