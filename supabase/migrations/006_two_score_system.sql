-- ─────────────────────────────────────────────────────────────────────────────
-- 006_two_score_system.sql — Separate display_score from resolution_score
--
-- resolution_score: raw follower/subscriber count — NEVER touched by promotions
-- display_score:    heat_score + future promotion modifiers — what UI shows
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Add new score columns to platform_metrics ─────────────────────────────────

ALTER TABLE platform_metrics
  ADD COLUMN display_score    numeric(5,2) DEFAULT 0,
  ADD COLUMN resolution_score bigint       DEFAULT 0;

-- ── Add snapshot columns to markets ──────────────────────────────────────────

ALTER TABLE markets
  ADD COLUMN opening_resolution_score bigint,
  ADD COLUMN opening_display_score    numeric(5,2);

-- ── Update spotlight trigger to use display_score ─────────────────────────────
-- display_score is the correct signal for leaderboard/spotlight going forward.
-- heat_score remains the raw calculation; display_score will incorporate
-- promotion modifiers in future phases.

CREATE OR REPLACE FUNCTION update_spotlight_from_heat()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE spotlight_scores
  SET score       = NEW.display_score,
      computed_at = now()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Re-fire trigger on display_score changes in addition to heat_score
DROP TRIGGER IF EXISTS trg_update_spotlight ON platform_metrics;

CREATE TRIGGER trg_update_spotlight
  AFTER INSERT OR UPDATE OF heat_score, display_score ON platform_metrics
  FOR EACH ROW EXECUTE FUNCTION update_spotlight_from_heat();

-- ── Trigger: snapshot scores into markets on INSERT ───────────────────────────

CREATE OR REPLACE FUNCTION snapshot_scores_on_market_open()
RETURNS TRIGGER AS $$
DECLARE
  v_resolution_score bigint;
  v_display_score    numeric(5,2);
BEGIN
  -- opened_by is the market maker; look up their current scores
  SELECT resolution_score, display_score
    INTO v_resolution_score, v_display_score
    FROM platform_metrics
   WHERE user_id = NEW.opened_by
   LIMIT 1;

  -- If no metrics row exists yet, leave NULLs (do not error)
  IF FOUND THEN
    NEW.opening_resolution_score := v_resolution_score;
    NEW.opening_display_score    := v_display_score;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_snapshot_market_scores
  BEFORE INSERT ON markets
  FOR EACH ROW EXECUTE FUNCTION snapshot_scores_on_market_open();
