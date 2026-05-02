-- Migration 038: Arena weekly points ledger
--
-- Separate from momentum_score. Points are a simple integer accumulation per week,
-- used to qualify for the Round 3 Champions bracket.
-- Resets (deleted) every Monday by arena_monday_rollover().
-- Round 1 win: +1 pt. Round 2 win: +2 pts. Round 3 win: +5 pts.

CREATE TABLE public.arena_weekly_points (
  user_id      uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  week_start   date        NOT NULL,  -- Monday of the ISO week (UTC)
  points       integer     NOT NULL DEFAULT 0,
  last_updated timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, week_start)
);

-- Used by Monday rollover and matchmaker (top weekly earners for bracket seeding)
CREATE INDEX idx_arena_weekly_points_week_points
  ON public.arena_weekly_points (week_start, points DESC);

ALTER TABLE public.arena_weekly_points ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_weekly_points: authenticated read"
  ON public.arena_weekly_points FOR SELECT TO authenticated USING (true);
