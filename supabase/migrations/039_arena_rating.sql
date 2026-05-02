-- Migration 039: Arena MMR (hidden Elo-style rating)
--
-- Starts at 1000 for all users. Updated by Round 2 match resolution only.
-- Round 1 is mechanical practice; Round 3 is bracket-driven — neither affects MMR.
--
-- Elo formula (K = 32):
--   E_a = 1 / (1 + 10 ^ ((R_b - R_a) / 400))   (expected score for side A)
--   delta = ROUND(K × (S - E_a))                  (S = 1 for win, 0 for loss)
--   new_R_a = R_a + delta
--   new_R_b = R_b - delta                          (zero-sum)
--   Floor: 100 (rating never goes below this)
--
-- Used by Round 2 matchmaker for adjacent-rating pairing to produce fair cross-
-- category matches.

ALTER TABLE public.platform_metrics
  ADD COLUMN IF NOT EXISTS arena_rating integer NOT NULL DEFAULT 1000;

CREATE INDEX IF NOT EXISTS idx_platform_metrics_arena_rating
  ON public.platform_metrics (arena_rating DESC);
