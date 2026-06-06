-- ─────────────────────────────────────────────────────────────────────────────
-- 091 — Doc 2 Game Logic
--
-- Changes from design doc (ground truth):
--   • resolution_type + battle_match_id added to `markets` (not arena_matches —
--     084 put them on arena_matches for live-view display; prediction markets
--     live in `markets` + `bets` as doc2 intends)
--   • battle_use_chit() uses battle_participant_status_effects (not arena_state —
--     chits are Battle artifacts; arena_state is the live Arena game's mutable row)
--   • base_archetype_speed() → battle_get_archetype_speed() already exists (062);
--     new alias created for doc2 naming
--   • process_poll_results() stub created here; full implementation in doc3
--   • battle_create_lobby / battle_join_lobby format+eligibility changes deferred
--     until Flutter lobby screen is updated (coordinated frontend change)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Add resolution_type + battle_match_id to markets ──────────────────────

ALTER TABLE public.markets
  ADD COLUMN resolution_type TEXT NOT NULL DEFAULT 'display_score'
    CHECK (resolution_type IN ('display_score', 'battle_outcome')),
  ADD COLUMN battle_match_id UUID REFERENCES battle_matches(id);

CREATE INDEX markets_battle_link_idx
  ON public.markets (battle_match_id)
  WHERE battle_match_id IS NOT NULL;

-- ── 2. Snap stat columns on battle_participants ──────────────────────────────

ALTER TABLE public.battle_participants
  ADD COLUMN snap_power      INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_charisma   INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_resilience INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_agility    INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_wit        INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_influence  INTEGER NOT NULL DEFAULT 50;

-- ── 3. Extend battle_participant_status_effects.effect_type for chit effects ──
-- Drop + re-add to include new types. Existing rows are not affected
-- (the new types are additive; no existing rows use them).

ALTER TABLE battle_participant_status_effects
  DROP CONSTRAINT IF EXISTS battle_participant_status_effects_effect_type_check;

ALTER TABLE battle_participant_status_effects
  ADD CONSTRAINT battle_participant_status_effects_effect_type_check
  CHECK (effect_type IN (
    -- Existing ability effects
    'speed_debuff', 'force_skip', 'save_state', 'double_damage',
    'type_reversed', 'forced_ability', 'encore', 'momentum_locked',
    -- Chit effects (post-launch processing — scaffold only)
    'stat_boost', 'damage_shield', 'speed_burst', 'counter',
    'type_override', 'aura', 'disruption'
  ));

-- ── 4. process_poll_results() stub (full implementation in doc3) ─────────────

CREATE OR REPLACE FUNCTION process_poll_results()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  -- Doc 3 will implement: read the most recently closed weekly_poll,
  -- compute rank-based multipliers, and update creator_stat_sheets.
  -- This stub satisfies the arena_monday_rollover() call added in step 8.
  RAISE NOTICE 'process_poll_results: stub — doc3 not yet applied';
END;
$$;

-- ── 5. distribute_match_revenue() ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION distribute_match_revenue(
  p_market_id        UUID,
  p_battle_match_id  UUID,
  p_winning_position TEXT,   -- 'team_1' or 'team_2'
  p_losing_position  TEXT
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_market              markets%ROWTYPE;
  v_total_pool          NUMERIC;
  v_losing_pool         NUMERIC;
  v_winner_pool         NUMERIC;
  v_active_pool         NUMERIC;
  v_creator_pool        NUMERIC;
  v_passive_pool        NUMERIC;
  v_platform_pool       NUMERIC;

  v_betters_pct         DECIMAL(6,4);
  v_active_pct          DECIMAL(6,4);
  v_creator_pct         DECIMAL(6,4);
  v_passive_pct         DECIMAL(6,4);

  v_row                 RECORD;
  v_total_winning_bet   NUMERIC;
  v_payout              BIGINT;

  v_active_participants INT;
  v_active_payout_each  BIGINT;

  v_unique_creators     INT;
  v_creator_payout_each BIGINT;

  v_total_royalty_pct   DECIMAL(10,6);
  v_passive_payout      BIGINT;

  v_platform_acct       UUID;
BEGIN
  SELECT * INTO v_market FROM markets WHERE id = p_market_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found: %', p_market_id; END IF;

  -- Load config pcts
  SELECT config_value INTO v_betters_pct  FROM match_revenue_config WHERE config_key = 'winner_betters_pct';
  SELECT config_value INTO v_active_pct   FROM match_revenue_config WHERE config_key = 'active_participants_pct';
  SELECT config_value INTO v_creator_pct  FROM match_revenue_config WHERE config_key = 'creator_pct';
  SELECT config_value INTO v_passive_pct  FROM match_revenue_config WHERE config_key = 'passive_owners_pct';

  v_total_pool  := COALESCE(v_market.yes_pool, 0) + COALESCE(v_market.no_pool, 0);

  v_losing_pool := CASE p_losing_position
    WHEN 'team_2' THEN COALESCE(v_market.no_pool, 0)
    WHEN 'team_1' THEN COALESCE(v_market.yes_pool, 0)
    ELSE COALESCE(v_market.no_pool, 0)
  END;

  -- Nothing to distribute if no pool at all
  IF v_total_pool = 0 THEN
    UPDATE markets SET status = 'voided', resolved_at = NOW() WHERE id = p_market_id;
    UPDATE bets SET status = 'refunded', settled_at = NOW() WHERE market_id = p_market_id;
    RETURN;
  END IF;

  -- Void if no one bet on the losing side (no redistribution possible)
  IF v_losing_pool = 0 THEN
    UPDATE markets SET status = 'voided', resolved_at = NOW() WHERE id = p_market_id;
    UPDATE bets SET status = 'refunded', settled_at = NOW() WHERE market_id = p_market_id;
    INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
    SELECT user_id, 'refund', amount::BIGINT, p_market_id, 'Battle market voided — no opposing bets'
    FROM bets WHERE market_id = p_market_id AND status = 'refunded';
    RETURN;
  END IF;

  -- Slice the total pool
  v_winner_pool  := FLOOR(v_total_pool * COALESCE(v_betters_pct, 0.75));
  v_active_pool  := FLOOR(v_total_pool * COALESCE(v_active_pct,  0.10));
  v_creator_pool := FLOOR(v_total_pool * COALESCE(v_creator_pct, 0.05));
  v_passive_pool := FLOOR(v_total_pool * COALESCE(v_passive_pct, 0.05));
  v_platform_pool:= v_total_pool - v_winner_pool - v_active_pool - v_creator_pool - v_passive_pool;

  -- ── Part 1: Winning betters (proportional) ──
  SELECT COALESCE(SUM(amount), 0) INTO v_total_winning_bet
  FROM bets
  WHERE market_id = p_market_id AND position = p_winning_position AND status = 'active';

  IF v_total_winning_bet > 0 THEN
    FOR v_row IN
      SELECT id AS bet_id, user_id, amount
      FROM bets
      WHERE market_id = p_market_id AND position = p_winning_position AND status = 'active'
    LOOP
      v_payout := FLOOR(v_winner_pool * v_row.amount::float / v_total_winning_bet::float)
                  + FLOOR(v_row.amount);  -- original bet returned

      PERFORM increment_token_balance(v_row.user_id, v_payout);
      INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
      VALUES (v_row.user_id, 'bet_won', v_payout, p_market_id, 'Battle prediction win');
      UPDATE bets SET status = 'won', settled_at = NOW() WHERE id = v_row.bet_id;
    END LOOP;
  END IF;

  UPDATE bets SET status = 'lost', settled_at = NOW()
  WHERE market_id = p_market_id AND position = p_losing_position AND status = 'active';

  FOR v_row IN SELECT user_id, amount FROM bets WHERE market_id = p_market_id AND position = p_losing_position AND status = 'lost' AND settled_at >= NOW() - INTERVAL '5 seconds' LOOP
    INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
    VALUES (v_row.user_id, 'bet_lost', 0, p_market_id, 'Battle prediction loss');
  END LOOP;

  -- ── Part 2: Active battle participants on winning team (equal split) ──
  SELECT COUNT(DISTINCT COALESCE(bts.user_id, bp.user_id))
  INTO v_active_participants
  FROM battle_participants bp
  LEFT JOIN (
    SELECT DISTINCT participant_id, user_id FROM battle_turn_submissions WHERE match_id = p_battle_match_id
  ) bts ON bts.participant_id = bp.id
  WHERE bp.match_id = p_battle_match_id
    AND bp.team_number = CASE p_winning_position WHEN 'team_1' THEN 1 ELSE 2 END;

  IF COALESCE(v_active_participants, 0) > 0 AND v_active_pool > 0 THEN
    v_active_payout_each := FLOOR(v_active_pool::float / v_active_participants::float);
    FOR v_row IN
      SELECT DISTINCT COALESCE(bts.user_id, bp.user_id) AS player_user_id
      FROM battle_participants bp
      LEFT JOIN (
        SELECT DISTINCT participant_id, user_id FROM battle_turn_submissions WHERE match_id = p_battle_match_id
      ) bts ON bts.participant_id = bp.id
      WHERE bp.match_id = p_battle_match_id
        AND bp.team_number = CASE p_winning_position WHEN 'team_1' THEN 1 ELSE 2 END
    LOOP
      PERFORM increment_token_balance(v_row.player_user_id, v_active_payout_each);
      INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
      VALUES (v_row.player_user_id, 'match_active_reward', v_active_payout_each, p_market_id, 'Battle win reward');
    END LOOP;
  END IF;

  -- ── Part 3: Original market makers of all characters (equal split) ──
  SELECT COUNT(DISTINCT bp.creator_id) INTO v_unique_creators
  FROM battle_participants bp WHERE bp.match_id = p_battle_match_id AND bp.creator_id IS NOT NULL;

  IF COALESCE(v_unique_creators, 0) > 0 AND v_creator_pool > 0 THEN
    v_creator_payout_each := FLOOR(v_creator_pool::float / v_unique_creators::float);
    FOR v_row IN
      SELECT DISTINCT bp.creator_id AS creator_user_id
      FROM battle_participants bp WHERE bp.match_id = p_battle_match_id AND bp.creator_id IS NOT NULL
    LOOP
      IF EXISTS (SELECT 1 FROM profiles WHERE id = v_row.creator_user_id AND managed_by_platform = TRUE) THEN
        UPDATE celebs SET managed_wallet_usd_cents = managed_wallet_usd_cents + v_creator_payout_each
        WHERE profile_id = v_row.creator_user_id;
      ELSE
        PERFORM increment_token_balance(v_row.creator_user_id, v_creator_payout_each);
        INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
        VALUES (v_row.creator_user_id, 'match_creator_reward', v_creator_payout_each, p_market_id, 'Character in battle reward');
      END IF;
    END LOOP;
  END IF;

  -- ── Part 4: Passive card holders proportional to royalty_pct ──
  SELECT COALESCE(SUM(lc.royalty_pct), 0) INTO v_total_royalty_pct
  FROM battle_participants bp
  JOIN likeness_cards lc ON lc.creator_id = bp.creator_id
  WHERE bp.match_id = p_battle_match_id AND lc.is_active = TRUE;

  IF v_total_royalty_pct > 0 AND v_passive_pool > 0 THEN
    FOR v_row IN
      SELECT lc.current_owner_id AS owner_user_id, SUM(lc.royalty_pct) AS total_stake
      FROM battle_participants bp
      JOIN likeness_cards lc ON lc.creator_id = bp.creator_id
      WHERE bp.match_id = p_battle_match_id AND lc.is_active = TRUE
      GROUP BY lc.current_owner_id
    LOOP
      v_passive_payout := FLOOR(
        v_passive_pool::float * v_row.total_stake::float / v_total_royalty_pct::float
      );
      IF v_passive_payout > 0 THEN
        PERFORM increment_token_balance(v_row.owner_user_id, v_passive_payout);
        INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
        VALUES (v_row.owner_user_id, 'match_passive_reward', v_passive_payout, p_market_id, 'Card holder match reward');
      END IF;
    END LOOP;
  END IF;

  -- ── Platform fee (audit log only — tokens burned) ──
  SELECT id INTO v_platform_acct FROM profiles WHERE username = 'platform' LIMIT 1;
  IF v_platform_acct IS NOT NULL AND v_platform_pool > 0 THEN
    INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
    VALUES (v_platform_acct, 'platform_fee', FLOOR(v_platform_pool), p_market_id, 'Battle market platform fee')
    ON CONFLICT DO NOTHING;
  END IF;

  -- Mark market resolved
  UPDATE markets SET
    status = 'resolved',
    resolution_result = p_winning_position,
    resolved_at = NOW()
  WHERE id = p_market_id;

END;
$$;

-- ── 6. battle_use_chit() ──────────────────────────────────────────────────────
-- Post-launch collectible economy scaffold. Effects are written to
-- battle_participant_status_effects (not arena_state) and logged to battle_events.
-- Full effect processing in process_battle_turn is wired post-launch.

CREATE OR REPLACE FUNCTION battle_use_chit(
  p_match_id       UUID,
  p_participant_id UUID,
  p_chit_def_id    UUID
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_chit     battle_chit_definitions%ROWTYPE;
  v_user_id  UUID;
  v_turn     INTEGER;
  v_expires  INTEGER;
BEGIN
  -- Validate caller owns this participant
  SELECT user_id INTO v_user_id FROM battle_participants
  WHERE id = p_participant_id AND match_id = p_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Participant not found'; END IF;
  IF v_user_id != auth.uid() THEN RAISE EXCEPTION 'Not your participant'; END IF;

  -- Load chit definition
  SELECT * INTO v_chit FROM battle_chit_definitions WHERE id = p_chit_def_id AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found or inactive'; END IF;

  -- Decrement inventory
  UPDATE user_battle_chits
  SET quantity = quantity - 1
  WHERE user_id = v_user_id AND chit_definition_id = p_chit_def_id AND quantity > 0;
  IF NOT FOUND THEN RAISE EXCEPTION 'No chits of this type in inventory'; END IF;

  -- Get current turn
  SELECT current_turn INTO v_turn FROM battle_matches WHERE id = p_match_id AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Match is not active'; END IF;

  -- Determine expiry
  v_expires := v_turn + COALESCE(v_chit.effect_duration_turns, 0);

  -- Apply immediate effects directly; queue status effects for duration-based chits
  IF v_chit.effect_type = 'momentum_surge' THEN
    UPDATE battle_participants
    SET momentum = LEAST(100, momentum + v_chit.effect_value::INTEGER)
    WHERE id = p_participant_id;
  ELSE
    -- Write to status effects; process_battle_turn picks up on next tick
    INSERT INTO battle_participant_status_effects (
      match_id, participant_id, applied_by_participant_id,
      effect_type, effect_value, applied_at_turn, expires_at_turn, indicator_key
    ) VALUES (
      p_match_id, p_participant_id, p_participant_id,
      v_chit.effect_type, COALESCE(v_chit.effect_value::INTEGER, 0),
      v_turn, GREATEST(v_turn, v_expires),
      'chit_' || v_chit.effect_type
    );
  END IF;

  -- Log event
  INSERT INTO battle_events (
    match_id, turn_number, sequence_in_turn,
    event_type, actor_participant_id, chit_id, animation_key
  )
  SELECT p_match_id, v_turn, 999, 'chit_used', p_participant_id,
         p_chit_def_id, v_chit.effect_type || '_chit'
  FROM battle_matches WHERE id = p_match_id;

END;
$$;

-- ── 7. battle_start_match() — updated ────────────────────────────────────────
-- Changes from 062:
--   • Format-aware slot count validation (1v1/2v2/3v3)
--   • Snapshot creator_stat_sheets into snap_* columns
--   • Recalculate speed from snap_agility
--   • Auto-create linked battle_outcome prediction market

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
    creator_id, opened_by, title, status,
    opening_resolution_score, yes_pool, no_pool,
    end_at, resolution_type, battle_match_id
  ) VALUES (
    COALESCE(v_char_creator_id, auth.uid()),
    auth.uid(),
    'Battle: ' || COALESCE(v_char_name_1, 'Team 1') || ' vs ' || COALESCE(v_char_name_2, 'Team 2'),
    'open',
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

-- ── 8. process_battle_turn() — updated ───────────────────────────────────────
-- Changes from 070:
--   • Damage formula now applies snap_power / snap_wit / snap_resilience modifiers
--   • Settles linked battle_outcome market on match resolve
--   • RNG chit drop for winning team on resolve

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
$$ LANGUAGE plpgsql;

-- ── 9. arena_monday_rollover() — updated ─────────────────────────────────────
-- Changes from 041:
--   • Spotlight now computed from battle win leaderboard (top 5 this week)
--   • Poll multiplier reset added (process_poll_results stub called)
--   • All other rollover steps preserved verbatim

CREATE OR REPLACE FUNCTION public.arena_monday_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_this_monday    date;
  v_last_monday    date;
  v_finalist_ids   uuid[];
  v_slot_1         uuid;
  v_slot_2         uuid;
  v_slot_3         uuid;
  v_slot_4         uuid;
  v_slot_5         uuid;

  v_reset_count    int := 0;
  v_decay_count    int := 0;
  v_points_wiped   int := 0;
BEGIN
  v_this_monday := date_trunc('week', now() AT TIME ZONE 'UTC')::date;
  v_last_monday := v_this_monday - 7;

  -- ── 1. Spotlight from battle win leaderboard (top 5 this week) ───────────
  SELECT
    MAX(CASE WHEN rn = 1 THEN creator_id END),
    MAX(CASE WHEN rn = 2 THEN creator_id END),
    MAX(CASE WHEN rn = 3 THEN creator_id END),
    MAX(CASE WHEN rn = 4 THEN creator_id END),
    MAX(CASE WHEN rn = 5 THEN creator_id END)
  INTO v_slot_1, v_slot_2, v_slot_3, v_slot_4, v_slot_5
  FROM (
    SELECT
      bp.creator_id,
      ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rn
    FROM battle_participants bp
    JOIN battle_matches bm ON bm.id = bp.match_id
    WHERE bm.status = 'resolved'
      AND bm.resolved_at >= v_last_monday::timestamptz
      AND bm.resolved_at <  v_this_monday::timestamptz
      AND bp.team_number  = bm.winner_team_number
      AND bp.creator_id IS NOT NULL
    GROUP BY bp.creator_id
    HAVING COUNT(*) > 0
  ) ranked
  WHERE rn <= 5;

  v_finalist_ids := ARRAY_REMOVE(
    ARRAY[v_slot_1, v_slot_2, v_slot_3, v_slot_4, v_slot_5],
    NULL
  );

  -- ── 2. Insert spotlight assignments ──────────────────────────────────────
  INSERT INTO public.arena_spotlight_assignments
    (week_start, slot_1_user_id, slot_2_user_id, slot_3_user_id, slot_4_user_id, slot_5_user_id)
  VALUES
    (v_this_monday, v_slot_1, v_slot_2, v_slot_3, v_slot_4, v_slot_5)
  ON CONFLICT (week_start) DO UPDATE
  SET slot_1_user_id = EXCLUDED.slot_1_user_id,
      slot_2_user_id = EXCLUDED.slot_2_user_id,
      slot_3_user_id = EXCLUDED.slot_3_user_id,
      slot_4_user_id = EXCLUDED.slot_4_user_id,
      slot_5_user_id = EXCLUDED.slot_5_user_id,
      locked_at      = now();

  -- ── 3. Reset Spotlight winners (heat_score = 0, momentum_score = 0) ──────
  -- SANCTIONED heat_score write (CLAUDE.md Hard Rule 4 exception).
  IF array_length(v_finalist_ids, 1) > 0 THEN
    UPDATE public.platform_metrics
    SET heat_score = 0, momentum_score = 0
    WHERE user_id = ANY(v_finalist_ids);
    GET DIAGNOSTICS v_reset_count = ROW_COUNT;
  END IF;

  -- ── 4. Decay momentum for all others × 0.5 ───────────────────────────────
  IF array_length(v_finalist_ids, 1) > 0 THEN
    UPDATE public.platform_metrics SET momentum_score = GREATEST(0, momentum_score * 0.5) WHERE user_id != ALL(v_finalist_ids);
  ELSE
    UPDATE public.platform_metrics SET momentum_score = GREATEST(0, momentum_score * 0.5);
  END IF;
  GET DIAGNOSTICS v_decay_count = ROW_COUNT;

  -- ── 5. Wipe prior weeks' arena_weekly_points ──────────────────────────────
  DELETE FROM public.arena_weekly_points WHERE week_start < v_this_monday;
  GET DIAGNOSTICS v_points_wiped = ROW_COUNT;

  -- ── 6. Apply weekly poll results + reset multipliers ─────────────────────
  -- process_poll_results() is a stub until doc3 lands. Multiplier reset is live.
  BEGIN
    PERFORM process_poll_results();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[arena_monday_rollover] process_poll_results failed: %', SQLERRM;
  END;

  UPDATE creator_stat_sheets
  SET weekly_poll_multiplier = 1.000,
      weekly_poll_rank       = NULL,
      last_poll_applied_at   = NULL;

  UPDATE creator_stat_sheets SET
    effective_power      = stat_power,
    effective_charisma   = stat_charisma,
    effective_resilience = stat_resilience,
    effective_agility    = stat_agility,
    effective_wit        = stat_wit,
    effective_influence  = stat_influence;

  -- ── 7. Audit log ──────────────────────────────────────────────────────────
  INSERT INTO public.arena_rollover_log
    (week_start, spotlight_user_ids, reset_count, decayed_count, points_wiped)
  VALUES
    (v_this_monday, COALESCE(v_finalist_ids, ARRAY[]::uuid[]), v_reset_count, v_decay_count, v_points_wiped);

  RETURN jsonb_build_object(
    'week_start',    v_this_monday,
    'spotlight_ids', COALESCE(v_finalist_ids, ARRAY[]::uuid[]),
    'reset_count',   v_reset_count,
    'decayed_count', v_decay_count,
    'points_wiped',  v_points_wiped,
    'completed_at',  now()
  );
END;
$$;
