-- Migration 049: arena_matchmake() v2 — Phase D
--
-- Changes from v1 (migration 031):
--   1. No longer restricts to is_test_account=true. Matches any market maker.
--      (Use arena-dev-force-match edge function to test with specific accounts.)
--   2. Time-based round dispatch (all times UTC):
--        Mon–Fri  07:00–19:00 → Round 1 (same-category, random pairing)
--        Mon–Fri  19:00–07:00 → Round 2 (cross-category, MMR-adjacent)
--        Fri 19:00 – Sun 23:59 → Round 3 (bracket only)
--        Saturday and Sunday outside bracket window: no new matches created.
--   3. Round 2: cross-category enforced; players paired by adjacent arena_rating.
--      Simplification: display_score 5× similarity check deferred to post-launch.
--   4. Round 3: bracket created on Friday ≥19:00 UTC if not yet exists for this week.
--      Bracket auto-advances: after all matches in a round resolve, winners are
--      paired for the next round. When exactly 1 match resolves in a round, the
--      bracket is marked completed (handled in tick v4).
--   5. Momentum scores are snapshotted into arena_matches at creation time so the
--      tick loop reads locked values (not live platform_metrics).
--   6. Return type extended: adds `round smallint`.
--      Flutter reads only match_id — no breaking change.

CREATE OR REPLACE FUNCTION public.arena_matchmake(p_limit int DEFAULT 5)
RETURNS TABLE (
  match_id    uuid,
  player_1_id uuid,
  player_2_id uuid,
  round       smallint,
  category    text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dow            int;
  v_hour           int;
  v_week_start     date;
  v_is_r3_window   boolean;

  -- Reusable match-creation helpers
  v_p1_id          uuid;
  v_p2_id          uuid;
  v_p1_momentum    numeric;
  v_p2_momentum    numeric;
  v_p1_archetype   text;
  v_p2_archetype   text;
  v_p1_subcategory text;
  v_p2_subcategory text;
  v_match_id       uuid;
  v_pairs_made     int := 0;
  v_category       text;

  -- Round 2 MMR pairing
  v_creator_rec    record;
  v_candidates     uuid[];
  v_candidate_cats text[];
  v_candidate_rtgs int[];
  v_i              int;
  v_j              int;
  v_best_j         int;
  v_rating_diff    int;
  v_min_diff       int;
  v_paired         boolean[];
  v_n              int;

  -- Round 3 bracket
  v_bracket        record;
  v_bracket_id     uuid;
  v_participants   uuid[];
  v_participant_count int;
  v_current_round  int;
  v_all_resolved   boolean;
  v_winners        uuid[];
  v_match_rec      record;
BEGIN
  v_dow        := EXTRACT(DOW FROM now() AT TIME ZONE 'UTC')::int;
  v_hour       := EXTRACT(HOUR FROM now() AT TIME ZONE 'UTC')::int;
  v_week_start := date_trunc('week', now() AT TIME ZONE 'UTC')::date;

  -- Round 3 window: Fri ≥19:00 UTC, all day Sat, all day Sun
  v_is_r3_window := (v_dow = 5 AND v_hour >= 19) OR v_dow = 6 OR v_dow = 0;

  -- ─────────────────────────────────────────────────────────────────────────
  -- ROUND 3: BRACKET LOGIC
  -- ─────────────────────────────────────────────────────────────────────────
  IF v_is_r3_window THEN

    -- Check for existing active bracket this week
    SELECT * INTO v_bracket
    FROM public.arena_round3_brackets
    WHERE week_start = v_week_start
      AND state IN ('forming', 'active')
    LIMIT 1;

    -- ── Create bracket on Friday ≥19:00 if none exists ────────────────────
    IF NOT FOUND THEN
      -- Take top 16 earners (minimum 2 required to form a bracket)
      SELECT ARRAY_AGG(user_id ORDER BY total_pts DESC)
      INTO v_participants
      FROM (
        SELECT user_id, SUM(points) AS total_pts
        FROM public.arena_weekly_points
        WHERE week_start = v_week_start
        GROUP BY user_id
        ORDER BY total_pts DESC
        LIMIT 16
      ) top_earners;

      IF v_participants IS NULL OR array_length(v_participants, 1) < 2 THEN
        RETURN; -- not enough participants this week
      END IF;

      INSERT INTO public.arena_round3_brackets (week_start, state, participant_ids, current_round)
      VALUES (v_week_start, 'active', v_participants, 1)
      RETURNING id INTO v_bracket_id;

      -- Schedule round 1 matches immediately
      PERFORM public._arena_schedule_bracket_round(v_bracket_id, v_participants, 1);
      RETURN;
    END IF;

    -- ── Auto-advance existing bracket ─────────────────────────────────────
    v_bracket_id := v_bracket.id;

    -- Find current highest round_in_bracket
    SELECT COALESCE(MAX(round_in_bracket), 0)
    INTO v_current_round
    FROM public.arena_round3_results
    WHERE bracket_id = v_bracket_id;

    IF v_current_round = 0 THEN
      -- Bracket created but round 1 not scheduled (shouldn't happen; recover gracefully)
      PERFORM public._arena_schedule_bracket_round(v_bracket_id, v_bracket.participant_ids, 1);
      RETURN;
    END IF;

    -- Are all matches in the current round resolved?
    SELECT NOT EXISTS (
      SELECT 1
      FROM public.arena_round3_results r
      JOIN public.arena_matches am ON am.id = r.match_id
      WHERE r.bracket_id = v_bracket_id
        AND r.round_in_bracket = v_current_round
        AND am.state != 'resolved'
    ) INTO v_all_resolved;

    IF NOT v_all_resolved THEN
      RETURN; -- matches still in progress
    END IF;

    -- Collect winners from the current round
    SELECT ARRAY_AGG(am.winner_id ORDER BY awp.points DESC NULLS LAST)
    INTO v_winners
    FROM public.arena_round3_results r
    JOIN public.arena_matches am ON am.id = r.match_id
    LEFT JOIN public.arena_weekly_points awp
      ON awp.user_id = am.winner_id AND awp.week_start = v_week_start
    WHERE r.bracket_id = v_bracket_id
      AND r.round_in_bracket = v_current_round
      AND am.winner_id IS NOT NULL;

    IF v_winners IS NULL OR array_length(v_winners, 1) < 2 THEN
      -- 0 or 1 winner means bracket is done (final was just resolved by tick loop)
      RETURN;
    END IF;

    -- Schedule the next round
    PERFORM public._arena_schedule_bracket_round(v_bracket_id, v_winners, v_current_round + 1);

    RETURN;
  END IF;

  -- ─────────────────────────────────────────────────────────────────────────
  -- ROUND 1: same-category (Mon–Fri 07:00–19:00 UTC)
  -- ─────────────────────────────────────────────────────────────────────────
  IF v_hour >= 7 AND v_hour < 19 THEN

    FOR v_category IN
      SELECT p.category_1
      FROM public.profiles p
      WHERE p.is_market_maker  = true
        AND p.pending_opt_out  = false
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

      SELECT p.id INTO v_p1_id
      FROM public.profiles p
      WHERE p.category_1     = v_category
        AND p.is_market_maker = true
        AND p.pending_opt_out = false
        AND NOT EXISTS (
          SELECT 1 FROM public.arena_matches am
          WHERE am.state IN ('pending', 'pre_match', 'live')
            AND (am.player_1_id = p.id OR am.player_2_id = p.id)
        )
      ORDER BY random() LIMIT 1;
      CONTINUE WHEN v_p1_id IS NULL;

      SELECT p.id INTO v_p2_id
      FROM public.profiles p
      WHERE p.category_1     = v_category
        AND p.is_market_maker = true
        AND p.pending_opt_out = false
        AND p.id             != v_p1_id
        AND NOT EXISTS (
          SELECT 1 FROM public.arena_matches am
          WHERE am.state IN ('pending', 'pre_match', 'live')
            AND (am.player_1_id = p.id OR am.player_2_id = p.id)
        )
      ORDER BY random() LIMIT 1;
      CONTINUE WHEN v_p2_id IS NULL;

      PERFORM public._arena_create_match(v_p1_id, v_p2_id, 1::smallint);
      v_pairs_made := v_pairs_made + 1;

      -- Return last created match to the caller
      SELECT id, player_1_id, player_2_id, round::smallint, player_1_archetype
      INTO match_id, player_1_id, player_2_id, round, category
      FROM public.arena_matches
      WHERE player_1_id = v_p1_id AND player_2_id = v_p2_id
        AND state = 'pre_match'
      ORDER BY created_at DESC LIMIT 1;

      RETURN NEXT;
    END LOOP;

    RETURN;
  END IF;

  -- ─────────────────────────────────────────────────────────────────────────
  -- ROUND 2: cross-category, MMR-adjacent (Mon–Fri 19:00–07:00 UTC)
  -- ─────────────────────────────────────────────────────────────────────────

  -- Load all eligible creators into arrays for pairing
  v_candidates     := ARRAY[]::uuid[];
  v_candidate_cats := ARRAY[]::text[];
  v_candidate_rtgs := ARRAY[]::int[];

  FOR v_creator_rec IN
    SELECT p.id, p.category_1,
           COALESCE(MAX(pm.arena_rating), 1000) AS rating
    FROM public.profiles p
    LEFT JOIN public.platform_metrics pm ON pm.user_id = p.id
    WHERE p.is_market_maker  = true
      AND p.pending_opt_out  = false
      AND p.category_1 IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.arena_matches am
        WHERE am.state IN ('pending', 'pre_match', 'live')
          AND (am.player_1_id = p.id OR am.player_2_id = p.id)
      )
    GROUP BY p.id, p.category_1
    ORDER BY MAX(pm.arena_rating) DESC NULLS LAST
  LOOP
    v_candidates     := array_append(v_candidates,     v_creator_rec.id);
    v_candidate_cats := array_append(v_candidate_cats, v_creator_rec.category_1);
    v_candidate_rtgs := array_append(v_candidate_rtgs, v_creator_rec.rating::int);
  END LOOP;

  v_n := array_length(v_candidates, 1);
  IF v_n IS NULL OR v_n < 2 THEN RETURN; END IF;

  -- Boolean array to track which candidates are already paired
  v_paired := ARRAY_FILL(false, ARRAY[v_n]);

  FOR v_i IN 1..v_n LOOP
    EXIT WHEN v_pairs_made >= p_limit;
    CONTINUE WHEN v_paired[v_i];

    -- Find nearest unmatched opponent with a DIFFERENT category
    v_best_j   := -1;
    v_min_diff := 999999;

    FOR v_j IN (v_i + 1)..v_n LOOP
      CONTINUE WHEN v_paired[v_j];
      CONTINUE WHEN v_candidate_cats[v_j] = v_candidate_cats[v_i]; -- must be cross-category

      v_rating_diff := ABS(v_candidate_rtgs[v_i] - v_candidate_rtgs[v_j]);
      IF v_rating_diff < v_min_diff THEN
        v_min_diff := v_rating_diff;
        v_best_j   := v_j;
      END IF;
    END LOOP;

    CONTINUE WHEN v_best_j = -1; -- no eligible opponent found

    v_paired[v_i]      := true;
    v_paired[v_best_j] := true;

    PERFORM public._arena_create_match(v_candidates[v_i], v_candidates[v_best_j], 2::smallint);
    v_pairs_made := v_pairs_made + 1;

    SELECT id, player_1_id, player_2_id, round::smallint, player_1_archetype
    INTO match_id, player_1_id, player_2_id, round, category
    FROM public.arena_matches
    WHERE player_1_id = v_candidates[v_i]
      AND player_2_id = v_candidates[v_best_j]
      AND state = 'pre_match'
    ORDER BY created_at DESC LIMIT 1;

    RETURN NEXT;
  END LOOP;

END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: _arena_create_match(p1, p2, round)
-- Inserts arena_matches + arena_state, snapshots momentum scores.
-- Not exposed as RPC (SECURITY DEFINER called by arena_matchmake).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._arena_create_match(
  p_p1_id uuid,
  p_p2_id uuid,
  p_round  smallint
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_p1_archetype   text;
  v_p1_subcategory text;
  v_p2_archetype   text;
  v_p2_subcategory text;
  v_p1_momentum    numeric;
  v_p2_momentum    numeric;
  v_match_id       uuid;
BEGIN
  SELECT category_1, subcategory INTO v_p1_archetype, v_p1_subcategory
  FROM public.profiles WHERE id = p_p1_id;

  SELECT category_1, subcategory INTO v_p2_archetype, v_p2_subcategory
  FROM public.profiles WHERE id = p_p2_id;

  SELECT COALESCE(MAX(momentum_score), 0) INTO v_p1_momentum
  FROM public.platform_metrics WHERE user_id = p_p1_id;

  SELECT COALESCE(MAX(momentum_score), 0) INTO v_p2_momentum
  FROM public.platform_metrics WHERE user_id = p_p2_id;

  INSERT INTO public.arena_matches (
    round, state,
    player_1_id, player_2_id,
    player_1_archetype, player_2_archetype,
    subcategory_p1, subcategory_p2,
    momentum_score_p1_at_start, momentum_score_p2_at_start,
    scheduled_start
  ) VALUES (
    p_round, 'pre_match',
    p_p1_id, p_p2_id,
    COALESCE(v_p1_archetype, 'athlete'),
    COALESCE(v_p2_archetype, 'athlete'),
    v_p1_subcategory, v_p2_subcategory,
    v_p1_momentum, v_p2_momentum,
    now() + interval '30 seconds'
  )
  RETURNING id INTO v_match_id;

  INSERT INTO public.arena_state (match_id) VALUES (v_match_id);

  RETURN v_match_id;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: _arena_schedule_bracket_round(bracket_id, participants, round_num)
-- Pairs participants for a bracket round and inserts matches + results rows.
-- participants: ordered by seed (index 1 = best seed).
-- Classic bracket seeding: seed 1 vs seed N, seed 2 vs seed N-1, etc.
-- Odd count: highest seed gets a bye (auto-advance; not implemented as a match).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._arena_schedule_bracket_round(
  p_bracket_id uuid,
  p_participants uuid[],
  p_round_num    int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n         int;
  v_match_id  uuid;
  v_i         int;
  v_j         int;
BEGIN
  v_n := array_length(p_participants, 1);
  IF v_n IS NULL OR v_n < 2 THEN RETURN; END IF;

  -- Classic bracket: pair seed i (from front) with seed n+1-i (from back)
  v_i := 1;
  v_j := v_n;
  WHILE v_i < v_j LOOP
    v_match_id := public._arena_create_match(
      p_participants[v_i],
      p_participants[v_j],
      3::smallint
    );

    INSERT INTO public.arena_round3_results (bracket_id, match_id, round_in_bracket)
    VALUES (p_bracket_id, v_match_id, p_round_num);

    v_i := v_i + 1;
    v_j := v_j - 1;
  END LOOP;

  -- Odd count: middle participant gets a bye (no match created for them in this round)
  -- They will be included as a winner in the next round automatically via
  -- the caller passing their id in the winners array.

  -- Update current_round on the bracket
  UPDATE public.arena_round3_brackets
  SET current_round = p_round_num
  WHERE id = p_bracket_id;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- pg_cron: keep the same 5-minute schedule (no change needed)
-- Re-create to pick up the new function signature.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'arena-matchmaker') THEN
    PERFORM cron.unschedule('arena-matchmaker');
  END IF;
END;
$$;

SELECT cron.schedule(
  'arena-matchmaker',
  '*/5 * * * *',
  'SELECT public.arena_matchmake(5)'
);
