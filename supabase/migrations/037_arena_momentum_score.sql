-- Migration 037: momentum_score column on platform_metrics + match-start snapshots
--
-- momentum_score: persistent Arena-only win-streak signal.
--   Lives on platform_metrics (one row per user per platform, but momentum is
--   user-level — every platform row for a user will have the same value since we
--   UPDATE WHERE user_id = ... in the tick loop).
--
-- Write paths (sanctioned, documented):
--   1. process_arena_tick() at match resolution — winner gains round points,
--      loser decays 5%.
--   2. arena_monday_rollover() — Spotlight winners reset to 0, all others ×0.5.
--      This is the SINGLE sanctioned write to momentum_score from outside the
--      Arena tick system (mirroring the heat_score rollover documented in CLAUDE.md).
--
-- momentum_score_p1_at_start / momentum_score_p2_at_start on arena_matches:
--   Locked at match creation time so mid-match momentum changes to other players
--   do not bleed into the live MomentumCarry calculation.

ALTER TABLE public.platform_metrics
  ADD COLUMN IF NOT EXISTS momentum_score numeric NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_platform_metrics_momentum_score
  ON public.platform_metrics (momentum_score DESC);

ALTER TABLE public.arena_matches
  ADD COLUMN IF NOT EXISTS momentum_score_p1_at_start numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS momentum_score_p2_at_start numeric NOT NULL DEFAULT 0;
