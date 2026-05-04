-- Hot Topic: week initialization function, scoring helper, + seed current week
-- week_id format: IYYY-IW (ISO year + ISO week, zero-padded to 2 digits)

-- Upserts a celeb's weekly score: inserts at 1000+delta on first run,
-- increments points on subsequent runs.
CREATE OR REPLACE FUNCTION hot_topic_score_celeb(
  p_week_id      TEXT,
  p_celeb_id     UUID,
  p_delta        INTEGER,
  p_tier         TEXT,
  p_story_volume INTEGER,
  p_reason       TEXT
) RETURNS void AS $$
BEGIN
  INSERT INTO celeb_weekly_scores
    (week_id, celeb_id, points, last_delta, last_tier, story_volume, reason_text, updated_at)
  VALUES
    (p_week_id, p_celeb_id, 1000 + p_delta, p_delta, p_tier, p_story_volume, p_reason, NOW())
  ON CONFLICT (week_id, celeb_id) DO UPDATE
    SET points       = celeb_weekly_scores.points + p_delta,
        last_delta   = p_delta,
        last_tier    = p_tier,
        story_volume = p_story_volume,
        reason_text  = p_reason,
        updated_at   = NOW();
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION initialize_hot_topic_week(p_week_id TEXT)
RETURNS INTEGER AS $$
DECLARE
  inserted_count INTEGER;
BEGIN
  INSERT INTO celeb_weekly_scores (week_id, celeb_id, points)
  SELECT p_week_id, id, 1000
  FROM celebs
  WHERE active = TRUE
  ON CONFLICT (week_id, celeb_id) DO NOTHING;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$ LANGUAGE plpgsql;

-- Initialize the current ISO week immediately so the leaderboard is populated on deploy.
SELECT initialize_hot_topic_week(
  TO_CHAR(NOW(), 'IYYY') || '-' || LPAD(TO_CHAR(NOW(), 'IW'), 2, '0')
);
