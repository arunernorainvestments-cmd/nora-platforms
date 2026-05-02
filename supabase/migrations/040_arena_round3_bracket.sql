-- Migration 040: Round 3 Champions bracket tables
--
-- arena_round3_brackets: one row per weekly bracket.
--   Created Friday 7 PM UTC by arena_matchmake().
--   participant_ids: up to 16 user_ids ranked by weekly_points (seed 1 = most points).
--   state: forming → active → completed.
--
-- arena_round3_results: one row per match within a bracket.
--   round_in_bracket: 1 = first round (e.g., round of 16), incrementing each stage.
--   The final match has the highest round_in_bracket value.
--   position: assigned at bracket completion (NULL during active play).
--     Slot 1 = bracket winner (final match winner).
--     Slot 2 = final match loser.
--     Slots 3–5 = top 3 semifinal losers by original seed (lowest seed = higher points = better rank).
--   If fewer than 16 participants: bracket still proceeds; position logic is identical.
--
-- Bracket auto-advance behavior:
--   arena_matchmake() (called every 5 min by pg_cron) checks for resolved matches in
--   the current bracket round and schedules the next round when all are done.
--   When only 1 match remains in a round and it resolves, the bracket is marked
--   completed and arena_monday_rollover() will pick up the results.
--
-- Offline / no-backing scenario:
--   Matches resolve normally via tick loop. A creator with no audience backing
--   still scores via HeatInfluence + MomentumCarry. The tick loop determines the
--   winner regardless of audience participation.

CREATE TABLE public.arena_round3_brackets (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start      date        NOT NULL UNIQUE,   -- Monday this bracket is FOR
  state           text        NOT NULL CHECK (state IN ('forming', 'active', 'completed'))
                              DEFAULT 'forming',
  participant_ids uuid[]      NOT NULL DEFAULT '{}',
  current_round   integer     NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz
);

CREATE INDEX idx_arena_round3_brackets_week
  ON public.arena_round3_brackets (week_start);
CREATE INDEX idx_arena_round3_brackets_state
  ON public.arena_round3_brackets (state);

ALTER TABLE public.arena_round3_brackets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_round3_brackets: authenticated read"
  ON public.arena_round3_brackets FOR SELECT TO authenticated USING (true);


CREATE TABLE public.arena_round3_results (
  bracket_id       uuid    NOT NULL REFERENCES public.arena_round3_brackets(id),
  match_id         uuid    NOT NULL REFERENCES public.arena_matches(id),
  round_in_bracket integer NOT NULL,
  position         integer,   -- NULL until bracket completes; 1=champion, 2=runner-up, etc.

  PRIMARY KEY (bracket_id, match_id)
);

CREATE INDEX idx_arena_round3_results_bracket_position
  ON public.arena_round3_results (bracket_id, position);
CREATE INDEX idx_arena_round3_results_bracket_round
  ON public.arena_round3_results (bracket_id, round_in_bracket);

ALTER TABLE public.arena_round3_results ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_round3_results: authenticated read"
  ON public.arena_round3_results FOR SELECT TO authenticated USING (true);
