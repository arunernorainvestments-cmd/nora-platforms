-- Migration 031: Arena tick loop + matchmaker + pg_cron jobs
--
-- Two PL/pgSQL functions called by pg_cron (same pattern as main-character-check
-- in migration 018 — no pg_net / HTTP required):
--
--   process_arena_tick()   — flips pre_match→live, scores events, resolves matches
--   arena_matchmake(limit) — pairs eligible test creators; returns created match rows
--
-- Phase A constraints:
--   • Tick cron runs every 1 minute (pg_cron minimum with standard cron syntax).
--     Target cadence is 10 s; achievable with pg_cron 1.6+ '10 seconds' syntax
--     once the Supabase project is confirmed to be on that version.
--   • Only test creators (is_test_account=true) are matched in Phase A.
--   • evaluate-challenges hook is NOT fired from the tick (requires pg_net).
--     Wire it in Phase B when pg_net is confirmed available.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. process_arena_tick()
-- ─────────────────────────────────────────────────────────────────────────────
-- Algorithm per invocation:
--   a. Flip any pre_match rows to live whose scheduled_start has passed.
--   b. For each live match:
--      i.   Gather unprocessed events, compute incremental BaseFlow with
--           diminishing returns (0.9^n per event on the same side).
--      ii.  Read heat_score for both players; compute HeatInfluence.
--      iii. Update scores and flow_rates in arena_state; mark events processed.
--   c. For each live match past its 5-minute window:
--      i.   Determine winner (higher score; P1 wins ties as tiebreak).
--      ii.  Resolve arena_matches row (state, winner_id, final scores).
--      iii. Distribute pool: 90% to winning backers proportionally,
--           5% to winning creator, 5% platform (burned — not credited).

CREATE OR REPLACE FUNCTION public.process_arena_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Phase A constants — adjust in Phase B when abilities are live
  c_heat_weight    CONSTANT numeric  := 0.5;
  c_flow_factor    CONSTANT numeric  := 0.9;  -- diminishing returns per event per tick
  c_match_duration CONSTANT interval := '5 minutes';
  c_winner_share   CONSTANT numeric  := 0.90;
  c_creator_share  CONSTANT numeric  := 0.05;
  -- platform share = 0.05 (burned, not credited)

  v_match          record;
  v_state          record;
  v_event          record;
  v_p1_heat        numeric;
  v_p2_heat        numeric;
  v_heat_inf_p1    numeric;
  v_heat_inf_p2    numeric;
  v_delta_flow_p1  numeric;
  v_delta_flow_p2  numeric;
  v_idx_p1         int;
  v_idx_p2         int;
  v_new_flow_p1    numeric;
  v_new_flow_p2    numeric;
  v_new_score_p1   numeric;
  v_new_score_p2   numeric;
  v_winner_id      uuid;
  v_total_pool     numeric;
  v_winner_pool    numeric;
  v_creator_tokens int;
  v_win_side_total numeric;
  v_backer         record;
  v_payout         int;
BEGIN
  -- ── a. Flip pre_match → live ────────────────────────────────────────────────
  UPDATE public.arena_matches
  SET state        = 'live',
      actual_start = now()
  WHERE state            = 'pre_match'
    AND scheduled_start <= now();

  -- ── b. Process each live match ──────────────────────────────────────────────
  FOR v_match IN
    SELECT * FROM public.arena_matches WHERE state = 'live'
    ORDER BY actual_start ASC
  LOOP
    SELECT * INTO v_state
    FROM public.arena_state
    WHERE match_id = v_match.id;

    IF NOT FOUND THEN
      RAISE WARNING 'process_arena_tick: no arena_state for match %', v_match.id;
      CONTINUE;
    END IF;

    -- Read heat_score for both players (max across all platform rows; baseline 0)
    SELECT COALESCE(MAX(heat_score), 0)
    INTO v_p1_heat
    FROM public.platform_metrics
    WHERE user_id = v_match.player_1_id;

    SELECT COALESCE(MAX(heat_score), 0)
    INTO v_p2_heat
    FROM public.platform_metrics
    WHERE user_id = v_match.player_2_id;

    v_heat_inf_p1 := v_p1_heat * c_heat_weight;
    v_heat_inf_p2 := v_p2_heat * c_heat_weight;

    -- Accumulate BaseFlow from unprocessed events this tick
    v_delta_flow_p1 := 0;
    v_delta_flow_p2 := 0;
    v_idx_p1        := 0;
    v_idx_p2        := 0;

    FOR v_event IN
      SELECT * FROM public.arena_events
      WHERE match_id = v_match.id AND processed = false
      ORDER BY created_at ASC
    LOOP
      IF v_event.target_id = v_match.player_1_id THEN
        -- Each successive event on the same side contributes 0.9^n of its face value
        v_delta_flow_p1 := v_delta_flow_p1 + v_event.value * (c_flow_factor ^ v_idx_p1);
        v_idx_p1 := v_idx_p1 + 1;
      ELSIF v_event.target_id = v_match.player_2_id THEN
        v_delta_flow_p2 := v_delta_flow_p2 + v_event.value * (c_flow_factor ^ v_idx_p2);
        v_idx_p2 := v_idx_p2 + 1;
      END IF;
    END LOOP;

    -- New cumulative flow rates (no decay in Phase A; decay/momentum come in Phase B)
    v_new_flow_p1 := v_state.flow_rate_p1 + v_delta_flow_p1;
    v_new_flow_p2 := v_state.flow_rate_p2 + v_delta_flow_p2;

    -- Score per tick = current flow_rate + heat_influence
    -- (AbilityImpact, MomentumSpike, MomentumCarry, Suppression all zero in Phase A)
    v_new_score_p1 := v_state.score_p1 + v_new_flow_p1 + v_heat_inf_p1;
    v_new_score_p2 := v_state.score_p2 + v_new_flow_p2 + v_heat_inf_p2;

    -- Update arena_state (Realtime will broadcast the row change to subscribers)
    UPDATE public.arena_state
    SET tick              = tick + 1,
        score_p1          = v_new_score_p1,
        score_p2          = v_new_score_p2,
        flow_rate_p1      = v_new_flow_p1,
        flow_rate_p2      = v_new_flow_p2,
        heat_influence_p1 = v_heat_inf_p1,
        heat_influence_p2 = v_heat_inf_p2,
        updated_at        = now()
    WHERE match_id = v_match.id;

    -- Mark events processed
    UPDATE public.arena_events
    SET processed = true
    WHERE match_id = v_match.id AND processed = false;

    -- ── c. Resolve if time is up ──────────────────────────────────────────────
    CONTINUE WHEN v_match.actual_start IS NULL;
    CONTINUE WHEN now() < v_match.actual_start + c_match_duration;

    -- Determine winner; P1 wins on exact tie
    IF v_new_score_p1 >= v_new_score_p2 THEN
      v_winner_id := v_match.player_1_id;
    ELSE
      v_winner_id := v_match.player_2_id;
    END IF;

    UPDATE public.arena_matches
    SET state          = 'resolved',
        actual_end     = now(),
        winner_id      = v_winner_id,
        final_score_p1 = v_new_score_p1,
        final_score_p2 = v_new_score_p2
    WHERE id = v_match.id;

    -- Pool distribution using pool totals from arena_state
    -- (total_pool_p1/p2 are updated live by arena_back(), so v_state has current values)
    v_total_pool := v_state.total_pool_p1 + v_state.total_pool_p2;

    IF v_total_pool <= 0 THEN
      CONTINUE;  -- no tokens were backed; nothing to distribute
    END IF;

    IF v_winner_id = v_match.player_1_id THEN
      v_win_side_total := v_state.total_pool_p1;
    ELSE
      v_win_side_total := v_state.total_pool_p2;
    END IF;

    v_winner_pool    := FLOOR(v_total_pool * c_winner_share);
    v_creator_tokens := FLOOR(v_total_pool * c_creator_share);

    -- Credit winning creator (5%)
    IF v_creator_tokens > 0 THEN
      PERFORM public.increment_token_balance(v_winner_id, v_creator_tokens);
      INSERT INTO public.token_transactions
        (user_id, type, amount, reference_id, description)
      VALUES
        (v_winner_id, 'arena_win', v_creator_tokens, v_match.id,
         'Arena match — creator reward');
    END IF;

    -- Credit winning backers proportionally (90% of total pool)
    IF v_win_side_total > 0 THEN
      FOR v_backer IN
        SELECT ae.user_id,
               SUM(ae.value) AS backed_amount
        FROM public.arena_events ae
        WHERE ae.match_id  = v_match.id
          AND ae.type      = 'back'
          AND ae.target_id = v_winner_id
        GROUP BY ae.user_id
      LOOP
        v_payout := FLOOR(v_winner_pool * (v_backer.backed_amount / v_win_side_total));
        IF v_payout > 0 THEN
          PERFORM public.increment_token_balance(v_backer.user_id, v_payout);
          INSERT INTO public.token_transactions
            (user_id, type, amount, reference_id, description)
          VALUES
            (v_backer.user_id, 'arena_win', v_payout, v_match.id,
             'Arena match — backing reward');
        END IF;
      END LOOP;
    END IF;
    -- Platform 5% is intentionally burned (not credited to any account).

  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. arena_matchmake(p_limit)
-- ─────────────────────────────────────────────────────────────────────────────
-- Pairs eligible creators and inserts arena_matches + arena_state rows.
-- Called by:
--   • pg_cron every 5 minutes (automated pairing)
--   • Flutter client via supabase.rpc('arena_matchmake', params: {'p_limit': 1})
--     ("Find a Match" button — creates one match and returns it)
--
-- Phase A: only pairs test creators (is_test_account=true). Round 1 only.
-- Returns TABLE so the Flutter client can get the created match_id(s).

CREATE OR REPLACE FUNCTION public.arena_matchmake(p_limit int DEFAULT 5)
RETURNS TABLE (match_id uuid, player_1_id uuid, player_2_id uuid, category text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category   text;
  v_p1_id      uuid;
  v_p2_id      uuid;
  v_match_id   uuid;
  v_pairs_made int := 0;
BEGIN
  -- For each category that has 2+ unmatched eligible test creators, create a pair.
  FOR v_category IN
    SELECT p.category_1
    FROM public.profiles p
    WHERE p.is_market_maker  = true
      AND p.pending_opt_out  = false
      AND p.is_test_account  = true
      AND p.category_1 IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.arena_matches am
        WHERE am.state IN ('pending', 'pre_match', 'live')
          AND (am.player_1_id = p.id OR am.player_2_id = p.id)
      )
    GROUP BY p.category_1
    HAVING COUNT(*) >= 2
    ORDER BY random()
  LOOP
    EXIT WHEN v_pairs_made >= p_limit;

    -- Pick first random eligible creator from this category
    SELECT p.id INTO v_p1_id
    FROM public.profiles p
    WHERE p.category_1     = v_category
      AND p.is_market_maker = true
      AND p.pending_opt_out = false
      AND p.is_test_account = true
      AND NOT EXISTS (
        SELECT 1 FROM public.arena_matches am
        WHERE am.state IN ('pending', 'pre_match', 'live')
          AND (am.player_1_id = p.id OR am.player_2_id = p.id)
      )
    ORDER BY random()
    LIMIT 1;

    CONTINUE WHEN v_p1_id IS NULL;

    -- Pick second random eligible creator from the same category (not P1)
    SELECT p.id INTO v_p2_id
    FROM public.profiles p
    WHERE p.category_1     = v_category
      AND p.is_market_maker = true
      AND p.pending_opt_out = false
      AND p.is_test_account = true
      AND p.id             != v_p1_id
      AND NOT EXISTS (
        SELECT 1 FROM public.arena_matches am
        WHERE am.state IN ('pending', 'pre_match', 'live')
          AND (am.player_1_id = p.id OR am.player_2_id = p.id)
      )
    ORDER BY random()
    LIMIT 1;

    CONTINUE WHEN v_p2_id IS NULL;

    -- Create match (pre_match: starts 30 seconds from now)
    INSERT INTO public.arena_matches (
      round, state,
      player_1_id, player_2_id,
      player_1_archetype, player_2_archetype,
      scheduled_start
    )
    VALUES (
      1, 'pre_match',
      v_p1_id, v_p2_id,
      v_category, v_category,
      now() + interval '30 seconds'
    )
    RETURNING id INTO v_match_id;

    -- Seed arena_state row (all zeros; tick loop populates each minute)
    INSERT INTO public.arena_state (match_id)
    VALUES (v_match_id);

    match_id    := v_match_id;
    player_1_id := v_p1_id;
    player_2_id := v_p2_id;
    category    := v_category;
    RETURN NEXT;

    v_pairs_made := v_pairs_made + 1;
  END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. pg_cron jobs
-- ─────────────────────────────────────────────────────────────────────────────
-- Unschedule previous runs if they exist (safe re-run).

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'arena-tick') THEN
    PERFORM cron.unschedule('arena-tick');
  END IF;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'arena-matchmaker') THEN
    PERFORM cron.unschedule('arena-matchmaker');
  END IF;
END;
$$;

-- Tick: 10 seconds requires pg_cron 1.6+ (SELECT extversion FROM pg_extension WHERE extname='pg_cron').
-- If the migration fails here, fall back to '* * * * *' (every 1 minute).
-- To stop the tick at any time: SELECT cron.unschedule('arena-tick');
SELECT cron.schedule(
  'arena-tick',
  '10 seconds',
  'SELECT public.process_arena_tick()'
);

-- Matchmaker: runs every 5 minutes to auto-pair test creators.
-- For manual-only control, comment this out and call arena_matchmake(1) from SQL
-- or the "Find a Match" button. To stop: SELECT cron.unschedule('arena-matchmaker');
SELECT cron.schedule(
  'arena-matchmaker',
  '*/5 * * * *',
  'SELECT public.arena_matchmake(5)'
);
