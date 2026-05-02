-- Migration 041: Arena Spotlight assignment + Monday rollover system
--
-- arena_spotlight_assignments: locked Monday 00:00 UTC each week.
--   5 slots populated from previous week's Round 3 bracket finalists.
--   Static for the week — no mid-week reshuffling.
--   If no bracket completed last week, all slots are NULL (empty state).
--
-- arena_rollover_log: audit table for each Monday rollover execution.
--
-- arena_monday_rollover(): PL/pgSQL function called by pg_cron Monday 00:00 UTC.
--   Wraps the entire rollover in a single transaction.
--   heat_score write: this function contains the SINGLE sanctioned write to
--   heat_score from outside the promotion system (resets Spotlight winners to 0).
--   See CLAUDE.md "Hard Implementation Rules" rule 3 exception.

-- ── Tables ─────────────────────────────────────────────────────────────────────

CREATE TABLE public.arena_spotlight_assignments (
  week_start     date PRIMARY KEY,  -- Monday of the week the slots are active
  slot_1_user_id uuid REFERENCES public.profiles(id),
  slot_2_user_id uuid REFERENCES public.profiles(id),
  slot_3_user_id uuid REFERENCES public.profiles(id),
  slot_4_user_id uuid REFERENCES public.profiles(id),
  slot_5_user_id uuid REFERENCES public.profiles(id),
  locked_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.arena_spotlight_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_spotlight_assignments: authenticated read"
  ON public.arena_spotlight_assignments FOR SELECT TO authenticated USING (true);


CREATE TABLE public.arena_rollover_log (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start       date        NOT NULL,
  spotlight_user_ids uuid[]    NOT NULL,
  reset_count      integer     NOT NULL DEFAULT 0,
  decayed_count    integer     NOT NULL DEFAULT 0,
  points_wiped     integer     NOT NULL DEFAULT 0,
  completed_at     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.arena_rollover_log ENABLE ROW LEVEL SECURITY;

-- Rollover log is service-role only (no public read; for debugging/audit only).


-- ── arena_monday_rollover() ────────────────────────────────────────────────────
-- Called every Monday 00:00 UTC by pg_cron.
-- Also callable via the arena-monday-rollover edge function for manual execution.
-- Entire operation runs in one implicit transaction (PL/pgSQL block).
--
-- Steps:
--   1. Find last week's completed Round 3 bracket → derive 5 Spotlight finalists.
--   2. Insert arena_spotlight_assignments for this Monday.
--   3. Reset finalists' heat_score = 0 AND momentum_score = 0.
--      (SANCTIONED heat_score write — documented exception in CLAUDE.md rule 3.)
--   4. Decay all other creators' momentum_score × 0.5.
--   5. Delete arena_weekly_points rows for prior weeks.
--   6. Write audit row to arena_rollover_log.
-- Returns: jsonb summary of what happened.

CREATE OR REPLACE FUNCTION public.arena_monday_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_this_monday    date;
  v_last_monday    date;
  v_bracket_id     uuid;
  v_finalist_ids   uuid[];

  v_slot_1         uuid;
  v_slot_2         uuid;
  v_slot_3         uuid;
  v_slot_4         uuid;
  v_slot_5         uuid;

  v_final_round    int;
  v_semi_round     int;
  v_match_rec      record;
  v_loser_id       uuid;
  v_semi_losers    uuid[];
  v_semi_seeds     int[];
  v_seed_rank      int;
  v_slots_filled   int;
  v_i              int;

  v_reset_count    int := 0;
  v_decay_count    int := 0;
  v_points_wiped   int := 0;
BEGIN
  v_this_monday := date_trunc('week', now() AT TIME ZONE 'UTC')::date;
  v_last_monday := v_this_monday - 7;

  -- ── 1. Find last week's completed bracket ──────────────────────────────────
  SELECT id INTO v_bracket_id
  FROM public.arena_round3_brackets
  WHERE week_start = v_last_monday
    AND state = 'completed'
  LIMIT 1;

  IF v_bracket_id IS NOT NULL THEN
    -- Find the max round_in_bracket (the final round)
    SELECT COALESCE(MAX(round_in_bracket), 0)
    INTO v_final_round
    FROM public.arena_round3_results
    WHERE bracket_id = v_bracket_id;

    -- Slot 1: winner of the final match
    SELECT am.winner_id INTO v_slot_1
    FROM public.arena_round3_results r
    JOIN public.arena_matches am ON am.id = r.match_id
    WHERE r.bracket_id = v_bracket_id
      AND r.round_in_bracket = v_final_round
    LIMIT 1;

    -- Slot 2: loser of the final match
    SELECT CASE
      WHEN am.winner_id = am.player_1_id THEN am.player_2_id
      ELSE am.player_1_id
    END INTO v_slot_2
    FROM public.arena_round3_results r
    JOIN public.arena_matches am ON am.id = r.match_id
    WHERE r.bracket_id = v_bracket_id
      AND r.round_in_bracket = v_final_round
    LIMIT 1;

    -- Slots 3–5: from the semifinal round (final_round - 1), up to 3 losers
    -- sorted by their original seed (position in participant_ids array = lower index = better seed)
    IF v_final_round > 1 THEN
      v_semi_round := v_final_round - 1;
      v_semi_losers := ARRAY[]::uuid[];
      v_semi_seeds  := ARRAY[]::int[];

      FOR v_match_rec IN
        SELECT r.match_id,
               am.player_1_id, am.player_2_id, am.winner_id,
               CASE WHEN am.winner_id = am.player_1_id THEN am.player_2_id
                    ELSE am.player_1_id END AS loser_id
        FROM public.arena_round3_results r
        JOIN public.arena_matches am ON am.id = r.match_id
        WHERE r.bracket_id = v_bracket_id
          AND r.round_in_bracket = v_semi_round
      LOOP
        v_loser_id := v_match_rec.loser_id;
        -- Find seed from participant_ids (array index, 1-based; lower = better)
        SELECT idx INTO v_seed_rank
        FROM (
          SELECT unnest(participant_ids) AS pid,
                 generate_subscripts(participant_ids, 1) AS idx
          FROM public.arena_round3_brackets WHERE id = v_bracket_id
        ) seeds
        WHERE pid = v_loser_id
        LIMIT 1;

        IF v_seed_rank IS NULL THEN v_seed_rank := 999; END IF;

        v_semi_losers := array_append(v_semi_losers, v_loser_id);
        v_semi_seeds  := array_append(v_semi_seeds,  v_seed_rank);
      END LOOP;

      -- Sort semi_losers by seed (ascending seed = better rank)
      -- Use a lateral unnest + sort since PL/pgSQL has no built-in array sort
      v_slots_filled := 0;
      FOR v_i IN
        SELECT ord FROM (
          SELECT s.seed, s.ord
          FROM unnest(v_semi_seeds) WITH ORDINALITY AS s(seed, ord)
          ORDER BY s.seed ASC
        ) sorted
      LOOP
        v_slots_filled := v_slots_filled + 1;
        IF v_slots_filled = 1 AND v_slot_3 IS NULL THEN
          v_slot_3 := v_semi_losers[v_i];
        ELSIF v_slots_filled = 2 AND v_slot_4 IS NULL THEN
          v_slot_4 := v_semi_losers[v_i];
        ELSIF v_slots_filled = 3 AND v_slot_5 IS NULL THEN
          v_slot_5 := v_semi_losers[v_i];
          EXIT;
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- Build finalist array (non-null slots only)
  v_finalist_ids := ARRAY_REMOVE(
    ARRAY[v_slot_1, v_slot_2, v_slot_3, v_slot_4, v_slot_5],
    NULL
  );

  -- ── 2. Insert spotlight assignments ───────────────────────────────────────
  INSERT INTO public.arena_spotlight_assignments
    (week_start, slot_1_user_id, slot_2_user_id, slot_3_user_id,
     slot_4_user_id, slot_5_user_id)
  VALUES
    (v_this_monday, v_slot_1, v_slot_2, v_slot_3, v_slot_4, v_slot_5)
  ON CONFLICT (week_start) DO UPDATE
  SET slot_1_user_id = EXCLUDED.slot_1_user_id,
      slot_2_user_id = EXCLUDED.slot_2_user_id,
      slot_3_user_id = EXCLUDED.slot_3_user_id,
      slot_4_user_id = EXCLUDED.slot_4_user_id,
      slot_5_user_id = EXCLUDED.slot_5_user_id,
      locked_at      = now();

  -- ── 3. Reset Spotlight winners (heat_score = 0, momentum_score = 0) ───────
  -- SANCTIONED heat_score write (see CLAUDE.md rule 3 Phase D exception).
  IF array_length(v_finalist_ids, 1) > 0 THEN
    UPDATE public.platform_metrics
    SET heat_score     = 0,
        momentum_score = 0
    WHERE user_id = ANY(v_finalist_ids);

    GET DIAGNOSTICS v_reset_count = ROW_COUNT;
  END IF;

  -- ── 4. Decay momentum for all others × 0.5 ────────────────────────────────
  IF array_length(v_finalist_ids, 1) > 0 THEN
    UPDATE public.platform_metrics
    SET momentum_score = GREATEST(0, momentum_score * 0.5)
    WHERE user_id != ALL(v_finalist_ids);
  ELSE
    UPDATE public.platform_metrics
    SET momentum_score = GREATEST(0, momentum_score * 0.5);
  END IF;

  GET DIAGNOSTICS v_decay_count = ROW_COUNT;

  -- ── 5. Wipe prior weeks' arena_weekly_points ──────────────────────────────
  DELETE FROM public.arena_weekly_points
  WHERE week_start < v_this_monday;

  GET DIAGNOSTICS v_points_wiped = ROW_COUNT;

  -- ── 6. Audit log ──────────────────────────────────────────────────────────
  INSERT INTO public.arena_rollover_log
    (week_start, spotlight_user_ids, reset_count, decayed_count, points_wiped)
  VALUES
    (v_this_monday,
     COALESCE(v_finalist_ids, ARRAY[]::uuid[]),
     v_reset_count,
     v_decay_count,
     v_points_wiped);

  RETURN jsonb_build_object(
    'week_start',      v_this_monday,
    'spotlight_ids',   COALESCE(v_finalist_ids, ARRAY[]::uuid[]),
    'reset_count',     v_reset_count,
    'decayed_count',   v_decay_count,
    'points_wiped',    v_points_wiped,
    'completed_at',    now()
  );
END;
$$;


-- ── pg_cron: Monday 00:00 UTC ──────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'arena-monday-rollover') THEN
    PERFORM cron.unschedule('arena-monday-rollover');
  END IF;
END;
$$;

SELECT cron.schedule(
  'arena-monday-rollover',
  '0 0 * * 1',
  'SELECT public.arena_monday_rollover()'
);
