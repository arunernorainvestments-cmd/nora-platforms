-- ─────────────────────────────────────────────────────────────────────────────
-- Battle ↔ prediction-market pipeline smoke test
--
-- Validates that a battle_outcome prediction market runs IN PARALLEL with a live
-- battle and settles on resolution, plus the migration 102/103 integrity + chit
-- paths. NON-DESTRUCTIVE: the whole script runs in one transaction and ROLLs BACK
-- — nothing persists (test accounts' balances/KYC/etc. are restored).
--
-- HOW TO RUN
--   • Supabase Dashboard → SQL Editor → paste this file → Run. Read the NOTICEs.
--   • or: psql "<DIRECT_CONNECTION_STRING>" -f supabase/tests/battle_market_pipeline_smoke.sql
--
-- Any "FAIL:" raises and aborts (and rolls back). All-green ends with
-- "ALL CHECKS PASSED". Reuses the seeded test accounts (migration 026,
-- 10000000-…-0000000000XX); never touches real users.
-- ─────────────────────────────────────────────────────────────────────────────

BEGIN;

DO $$
DECLARE
  A   UUID := '10000000-0000-0000-0000-000000000001'; -- team 1 combatant + creator
  B   UUID := '10000000-0000-0000-0000-000000000002'; -- team 2 combatant + creator
  S1  UUID := '10000000-0000-0000-0000-000000000003'; -- spectator, backs team 1 (winner)
  S2  UUID := '10000000-0000-0000-0000-000000000004'; -- spectator, backs team 2 (loser)
  ALT UUID := '10000000-0000-0000-0000-000000000005'; -- sybil-anchor test

  v_match  UUID := gen_random_uuid();
  v_arena  UUID := gen_random_uuid();
  v_pa     UUID := gen_random_uuid();   -- participant A (team 1)
  v_pb     UUID := gen_random_uuid();   -- participant B (team 2)
  v_market UUID;
  v_chit   UUID;

  v_before INT;
  v_num    NUMERIC;
  v_txt    TEXT;
  v_err    TEXT;
BEGIN
  RAISE NOTICE '── Battle ↔ market pipeline smoke test ──';

  -- Give the actors spending room (restored on rollback).
  UPDATE token_balances SET available_tokens = 1000 WHERE user_id IN (A, B, S1, S2, ALT);

  -- ── Set up a 1v1 lobby and start it (snaps stats + opens the linked market) ──
  INSERT INTO battle_matches (id, lobby_code, status, host_user_id, format, current_turn, turn_duration_seconds)
  VALUES (v_match, upper(substr(replace(v_match::text, '-', ''), 1, 8)), 'lobby', A, '1v1', 0, 30);

  INSERT INTO battle_participants
    (id, match_id, user_id, creator_id, team_number, slot_position, archetype, character_name,
     speed, max_hp, current_hp, max_ap, current_ap, momentum)
  VALUES
    (v_pa, v_match, A, A, 1, 1, 'athlete',    'Alpha', 90, 150, 150, 50, 50, 0),
    (v_pb, v_match, B, B, 2, 1, 'politician', 'Bravo', 40, 150, 150, 50, 50, 0);

  PERFORM battle_start_match_internal(v_match);

  SELECT id INTO v_market FROM markets
  WHERE battle_match_id = v_match AND resolution_type = 'battle_outcome';
  IF v_market IS NULL THEN RAISE EXCEPTION 'FAIL: linked market not created at match start'; END IF;
  RAISE NOTICE 'PASS 1: market % opened in parallel with the live match', v_market;

  -- ── Spectator backs team 1 → bet flows into the pool while the match is live ─
  INSERT INTO bets (market_id, user_id, position, amount, status)
  VALUES (v_market, S1, 'team_1', 30, 'active');
  SELECT yes_pool INTO v_num FROM markets WHERE id = v_market;
  IF v_num <> 30 THEN RAISE EXCEPTION 'FAIL: bet did not accumulate into yes_pool (got %)', v_num; END IF;
  RAISE NOTICE 'PASS 2: live bet accumulated into the pool (yes_pool = %)', v_num;

  -- Opposing-side bet so settlement has a losing pool to redistribute.
  INSERT INTO bets (market_id, user_id, position, amount, status)
  VALUES (v_market, S2, 'team_2', 20, 'active');

  -- ── Integrity: a combatant cannot bet on their own battle ───────────────────
  v_err := NULL;
  BEGIN
    INSERT INTO bets (market_id, user_id, position, amount, status)
    VALUES (v_market, A, 'team_1', 10, 'active');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  IF v_err IS NULL OR v_err NOT LIKE '%combatants cannot bet%' THEN
    RAISE EXCEPTION 'FAIL: combatant bet was not blocked (got: %)', v_err;
  END IF;
  RAISE NOTICE 'PASS 3: combatant bet blocked — "%"', v_err;

  -- ── Chit usage by a player (immediate stat_boost effect) ────────────────────
  SELECT id INTO v_chit FROM battle_chit_definitions WHERE name = 'Power Surge';
  INSERT INTO user_battle_chits (user_id, chit_definition_id, quantity, acquired_via)
  VALUES (A, v_chit, 2, 'event')
  ON CONFLICT (user_id, chit_definition_id) DO UPDATE SET quantity = 2;

  SELECT snap_power INTO v_before FROM battle_participants WHERE id = v_pa;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', A::text)::text, true);
  PERFORM battle_use_chit(v_match, v_pa, v_chit, NULL);
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT snap_power INTO v_num FROM battle_participants WHERE id = v_pa;
  IF v_num <> v_before + 15 THEN
    RAISE EXCEPTION 'FAIL: stat_boost chit not applied (% -> %, expected +15)', v_before, v_num;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM battle_chit_uses WHERE match_id = v_match AND user_id = A) THEN
    RAISE EXCEPTION 'FAIL: chit use not recorded in ledger';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM battle_events WHERE match_id = v_match AND event_type = 'chit_used') THEN
    RAISE EXCEPTION 'FAIL: chit_used animation event not emitted';
  END IF;
  RAISE NOTICE 'PASS 4: chit applied (power % -> %), ledger + animation event written', v_before, v_num;

  -- ── One chit per participant per turn ───────────────────────────────────────
  v_err := NULL;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', A::text)::text, true);
  BEGIN PERFORM battle_use_chit(v_match, v_pa, v_chit, NULL);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_err IS NULL OR v_err NOT LIKE '%one chit%per turn%' THEN
    RAISE EXCEPTION 'FAIL: per-turn chit cap not enforced (got: %)', v_err;
  END IF;
  RAISE NOTICE 'PASS 5: per-turn chit cap — "%"', v_err;

  -- ── Legacy Arena: a backer cannot also trigger a powerup (one role per match) ─
  INSERT INTO arena_matches
    (id, round, state, player_1_id, player_2_id, player_1_archetype, player_2_archetype, scheduled_start, actual_start)
  VALUES (v_arena, 1, 'live', A, B, 'athlete', 'politician', now(), now());
  INSERT INTO arena_state (match_id) VALUES (v_arena);

  INSERT INTO arena_events (match_id, user_id, target_id, type, value) VALUES (v_arena, S1, A, 'back', 10);
  v_err := NULL;
  BEGIN
    INSERT INTO arena_events (match_id, user_id, target_id, type, value) VALUES (v_arena, S1, A, 'trigger', 25);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  IF v_err IS NULL OR v_err NOT LIKE '%backers cannot trigger%' THEN
    RAISE EXCEPTION 'FAIL: backer-then-trigger not blocked (got: %)', v_err;
  END IF;
  RAISE NOTICE 'PASS 6: legacy-arena backer cannot trigger — "%"', v_err;

  -- ── KYC sybil anchor: one verified human → one staking identity ─────────────
  INSERT INTO kyc_verifications (user_id, status, identity_hash, verified_at, expires_at)
  VALUES (A, 'approved', 'SMOKEHASH', now(), now() + INTERVAL '1 year')
  ON CONFLICT (user_id) DO UPDATE
    SET status = 'approved', identity_hash = 'SMOKEHASH', verified_at = now(), expires_at = now() + INTERVAL '1 year';

  v_err := NULL;
  BEGIN
    INSERT INTO kyc_verifications (user_id, status, identity_hash, verified_at, expires_at)
    VALUES (ALT, 'approved', 'SMOKEHASH', now(), now() + INTERVAL '1 year');
  EXCEPTION WHEN unique_violation THEN v_err := SQLERRM; END;
  IF v_err IS NULL THEN
    RAISE EXCEPTION 'FAIL: identity_hash uniqueness not enforced — a human could approve two accounts';
  END IF;
  RAISE NOTICE 'PASS 7: identity_hash unique on approved rows — second account rejected';

  -- ── KYC staking gate (live-mode flag) blocks an unverified bettor ───────────
  UPDATE platform_integrity_settings SET require_kyc_for_staking = TRUE WHERE id = TRUE;
  v_err := NULL;
  BEGIN
    INSERT INTO bets (market_id, user_id, position, amount, status)
    VALUES (v_market, S2, 'team_2', 5, 'active');  -- S2 has no approved KYC
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  IF v_err IS NULL OR v_err NOT LIKE '%KYC verification required%' THEN
    RAISE EXCEPTION 'FAIL: KYC staking gate not enforced (got: %)', v_err;
  END IF;
  RAISE NOTICE 'PASS 8: KYC staking gate blocks unverified bet — "%"', v_err;
  UPDATE platform_integrity_settings SET require_kyc_for_staking = FALSE WHERE id = TRUE;

  -- ── Full parallel resolution: match ends → linked market settles ────────────
  UPDATE battle_participants SET current_hp = 0, is_fainted = TRUE, is_active = FALSE WHERE id = v_pb;
  UPDATE battle_matches SET turn_deadline = now() - INTERVAL '1 minute' WHERE id = v_match;
  PERFORM process_battle_turn(v_match);

  SELECT status INTO v_txt FROM markets WHERE id = v_market;
  IF v_txt <> 'resolved' THEN
    RAISE EXCEPTION 'FAIL: market not resolved after match end (status = %)', v_txt;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM token_transactions
    WHERE user_id = S1 AND type = 'bet_won' AND reference_id = v_market::text
  ) THEN
    RAISE EXCEPTION 'FAIL: winning bettor (team 1) was not paid out';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM bets WHERE market_id = v_market AND user_id = S2 AND status = 'lost'
  ) THEN
    RAISE EXCEPTION 'FAIL: losing bet (team 2) was not settled';
  END IF;
  RAISE NOTICE 'PASS 9: match resolved → market settled (winner paid, loser settled)';

  RAISE NOTICE '── ALL CHECKS PASSED — rolling back, no data persisted ──';
END $$;

ROLLBACK;
