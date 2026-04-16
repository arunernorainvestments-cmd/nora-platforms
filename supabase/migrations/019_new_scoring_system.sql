-- Migration 019: New Scoring System
-- display_score: bigint per-platform point sum (followers×1, live_viewers×10, 24h_growth×5)
-- heat_score: baseline 0, only active boost deltas move it
-- resolution_score: deprecated (display_score is now the resolution metric)
-- score_history: new table for Robinhood-style time-series chart

-- 0. Drop existing spotlight trigger (depends on display_score column — must go first)
DROP TRIGGER IF EXISTS trg_update_spotlight ON platform_metrics;

-- 1. Change display_score from numeric(5,2) to bigint (per-platform point contribution)
ALTER TABLE platform_metrics ALTER COLUMN display_score TYPE bigint USING 0;

-- 2. Add previous_follower_count for 24h growth delta tracking
ALTER TABLE platform_metrics
  ADD COLUMN previous_follower_count bigint NOT NULL DEFAULT 0;

-- 3. Reset all heat_scores to 0 (baseline is now 0 — boost-only)
UPDATE platform_metrics SET heat_score = 0;

-- 4. Drop resolution_score (deprecated — composite display_score is the resolution metric now)
ALTER TABLE platform_metrics DROP COLUMN IF EXISTS resolution_score;

-- 5. Create score_history table for Robinhood dashboard
CREATE TABLE public.score_history (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  composite_score bigint      NOT NULL,
  recorded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX score_history_user_time_idx ON score_history (user_id, recorded_at DESC);
ALTER TABLE score_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read_score_history" ON score_history FOR SELECT USING (true);
CREATE POLICY "service_write_score_history" ON score_history FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- 6. Update snapshot trigger:
--    - Fix bug: use creator_id (Market Maker) instead of opened_by (first bettor)
--    - Now snapshots composite display_score (SUM across all platforms) into opening_resolution_score
CREATE OR REPLACE FUNCTION snapshot_scores_on_market_open()
RETURNS TRIGGER AS $$
DECLARE
  v_composite_score bigint;
  v_heat_score      numeric;
BEGIN
  SELECT COALESCE(SUM(display_score), 0), COALESCE(MAX(heat_score), 0)
    INTO v_composite_score, v_heat_score
    FROM platform_metrics
   WHERE user_id = NEW.creator_id;

  NEW.opening_resolution_score := v_composite_score;
  NEW.opening_heat_score       := v_heat_score;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Update Spotlight trigger: fire only on heat_score (display_score no longer drives Spotlight)
CREATE OR REPLACE FUNCTION update_spotlight_from_heat()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE spotlight_scores
  SET score       = NEW.heat_score,
      computed_at = now()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_update_spotlight
  AFTER INSERT OR UPDATE OF heat_score ON platform_metrics
  FOR EACH ROW EXECUTE FUNCTION update_spotlight_from_heat();
