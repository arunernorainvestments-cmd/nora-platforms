-- ─────────────────────────────────────────────────────────────────────────────
-- 080 — Creator Stat Sheets (Redesign Doc 1)
--
-- Renumbered from doc's "079" because 079_recruiter_badge.sql already exists.
--
-- One row per market maker (regular or celeb). Stats are six values
-- (Power, Charisma, Resilience, Agility, Wit, Influence) percentile-ranked
-- globally and normalized to a 300-point budget. A weekly poll multiplier is
-- applied on top of base stats to produce effective stats used in Battle/Arena.
--
-- Deviations from doc1:
--   - `pm.reposts`  → `pm.recent_post_reposts`  (actual column name from 020)
--   - `pm.likes`    → 0                          (column does not exist)
--   - `JOIN celeb_weeks` → subquery on `celeb_weekly_scores.week_id` directly
--     (celeb_weeks table does not exist; week_id text is on celeb_weekly_scores)
--
-- New-user guard: if all six percentile inputs are zero (no platform_metrics
-- yet) the function falls back to 50 across all stats. DO NOT remove this guard.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE creator_stat_sheets (
  user_id                     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  stat_power                  INTEGER NOT NULL DEFAULT 50
    CHECK (stat_power BETWEEN 0 AND 150),
  stat_charisma               INTEGER NOT NULL DEFAULT 50
    CHECK (stat_charisma BETWEEN 0 AND 150),
  stat_resilience             INTEGER NOT NULL DEFAULT 50
    CHECK (stat_resilience BETWEEN 0 AND 150),
  stat_agility                INTEGER NOT NULL DEFAULT 50
    CHECK (stat_agility BETWEEN 0 AND 150),
  stat_wit                    INTEGER NOT NULL DEFAULT 50
    CHECK (stat_wit BETWEEN 0 AND 150),
  stat_influence              INTEGER NOT NULL DEFAULT 50
    CHECK (stat_influence BETWEEN 0 AND 150),

  weekly_poll_rank            INTEGER,
  weekly_poll_multiplier      DECIMAL(4,3) NOT NULL DEFAULT 1.000,

  effective_power             INTEGER NOT NULL DEFAULT 50,
  effective_charisma          INTEGER NOT NULL DEFAULT 50,
  effective_resilience        INTEGER NOT NULL DEFAULT 50,
  effective_agility           INTEGER NOT NULL DEFAULT 50,
  effective_wit               INTEGER NOT NULL DEFAULT 50,
  effective_influence         INTEGER NOT NULL DEFAULT 50,

  platform_count              INTEGER NOT NULL DEFAULT 0,
  calculated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_poll_applied_at        TIMESTAMPTZ
);

CREATE INDEX stat_sheets_power_idx     ON creator_stat_sheets (stat_power DESC);
CREATE INDEX stat_sheets_charisma_idx  ON creator_stat_sheets (stat_charisma DESC);
CREATE INDEX stat_sheets_influence_idx ON creator_stat_sheets (stat_influence DESC);

CREATE TABLE creator_stat_history (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  stat_power                  INTEGER NOT NULL,
  stat_charisma               INTEGER NOT NULL,
  stat_resilience             INTEGER NOT NULL,
  stat_agility                INTEGER NOT NULL,
  stat_wit                    INTEGER NOT NULL,
  stat_influence              INTEGER NOT NULL,
  weekly_poll_multiplier      DECIMAL(4,3) NOT NULL DEFAULT 1.000,
  recorded_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX stat_history_user_idx ON creator_stat_history (user_id, recorded_at DESC);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE creator_stat_sheets   ENABLE ROW LEVEL SECURITY;
ALTER TABLE creator_stat_history  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stat_sheets_public_read"
  ON creator_stat_sheets FOR SELECT
  USING (TRUE);

CREATE POLICY "stat_history_public_read"
  ON creator_stat_history FOR SELECT
  USING (TRUE);
-- No write policies: writes happen only via calculate_stat_sheets() SECURITY DEFINER.

-- ─────────────────────────────────────────────────────────────────────────────
-- calculate_stat_sheets() — called from sync-platform-metrics at the end of
-- every run. Recomputes all market makers' stats and snapshots to history.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION calculate_stat_sheets()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  WITH regular_raw AS (
    SELECT
      pm.user_id,
      COALESCE(SUM(pm.follower_count), 0)::float AS raw_power,

      COALESCE(AVG(
        CASE
          WHEN pm.platform = 'x' THEN
            (COALESCE(pm.recent_post_views, 0) * 0.1
             + COALESCE(pm.recent_post_reposts, 0) * 3
             + 0)::float  -- 'likes' column does not exist on platform_metrics
            / NULLIF(pm.follower_count, 0)
          WHEN pm.platform IN ('youtube', 'twitch') THEN
            COALESCE(pm.live_viewer_count, 0)::float
            / NULLIF(pm.follower_count, 0) * 50
          WHEN pm.platform = 'spotify' THEN
            -- per migration 020 column-reuse: recent_post_views = saved_tracks,
            -- recent_post_reposts = saved_albums
            (COALESCE(pm.recent_post_views, 0) * 3
             + COALESCE(pm.recent_post_reposts, 0) * 3)::float
            / NULLIF(pm.follower_count, 0)
          ELSE 0
        END
      ), 0) AS raw_charisma,

      COALESCE(AVG(
        1.0 - GREATEST(0.0,
          (COALESCE(pm.previous_follower_count, pm.follower_count)
           - pm.follower_count)::float
          / NULLIF(pm.previous_follower_count, 0)
        )
      ), 0.5) AS raw_resilience,

      (COALESCE(AVG(
        GREATEST(0.0,
          (pm.follower_count
           - COALESCE(pm.previous_follower_count, pm.follower_count))::float
          / NULLIF(pm.previous_follower_count, 0)
        )
      ), 0) * 0.7
      + (COUNT(DISTINCT pm.platform)::float / 4.0) * 0.3) AS raw_agility,

      COALESCE(AVG(
        CASE
          WHEN pm.platform = 'x' THEN
            0::float  -- likes column missing; substitute 0 until x integration adds it
            / NULLIF(pm.recent_post_views, 0)
          WHEN pm.platform = 'spotify' THEN
            (COALESCE(pm.recent_post_views, 0)
             + COALESCE(pm.recent_post_reposts, 0))::float
            / NULLIF(pm.follower_count, 0)
          WHEN pm.platform IN ('youtube', 'twitch') THEN
            COALESCE(pm.live_viewer_count, 0)::float
            / NULLIF(pm.follower_count, 0)
          ELSE 0
        END
      ), 0) AS raw_wit,

      COALESCE(SUM(pm.display_score)::float
        / NULLIF(COUNT(DISTINCT pm.platform), 0), 0) AS raw_influence,

      COUNT(DISTINCT pm.platform)::INTEGER AS platform_count

    FROM platform_metrics pm
    JOIN profiles p ON p.id = pm.user_id
    WHERE p.is_market_maker = TRUE
      AND p.pending_opt_out = FALSE
      AND (p.is_celeb IS NULL OR p.is_celeb = FALSE)
      AND (p.is_test_account IS NULL OR p.is_test_account = FALSE)
    GROUP BY pm.user_id
  ),

  celeb_raw AS (
    SELECT
      p.id AS user_id,
      COALESCE(cws.story_volume, 0)::float * 1000 AS raw_power,
      COALESCE(
        SUM(CASE WHEN csh.delta > 0 THEN 1 ELSE 0 END)::float
        / NULLIF(COUNT(csh.id), 0) * 100, 50
      ) AS raw_charisma,
      COALESCE(
        1.0 - (SUM(CASE WHEN csh.delta < -5 THEN 1 ELSE 0 END)::float
        / NULLIF(COUNT(csh.id), 0)), 0.5
      ) AS raw_resilience,
      COALESCE(cws.story_volume, 0)::float / 10.0 AS raw_agility,
      COALESCE(AVG(ABS(csh.delta)), 0)::float AS raw_wit,
      COALESCE((26 - cws.rank)::float * 10, 50) AS raw_influence,
      1 AS platform_count
    FROM profiles p
    JOIN celebs c ON c.id = p.celeb_id
    LEFT JOIN celeb_weekly_scores cws ON cws.celeb_id = c.id
      AND cws.week_id = (
        -- celeb_weeks does not exist; pick the most recently updated week.
        SELECT week_id FROM celeb_weekly_scores
        ORDER BY updated_at DESC LIMIT 1
      )
    LEFT JOIN celeb_score_history csh ON csh.celeb_id = c.id
      AND csh.scored_at > NOW() - INTERVAL '7 days'
    WHERE p.is_celeb = TRUE
    GROUP BY p.id, cws.story_volume, cws.rank
  ),

  all_raw AS (
    SELECT * FROM regular_raw
    UNION ALL
    SELECT * FROM celeb_raw
  ),

  percentiled AS (
    SELECT
      user_id,
      platform_count,
      PERCENT_RANK() OVER (ORDER BY raw_power)      * 100 AS pct_power,
      PERCENT_RANK() OVER (ORDER BY raw_charisma)   * 100 AS pct_charisma,
      PERCENT_RANK() OVER (ORDER BY raw_resilience) * 100 AS pct_resilience,
      PERCENT_RANK() OVER (ORDER BY raw_agility)    * 100 AS pct_agility,
      PERCENT_RANK() OVER (ORDER BY raw_wit)        * 100 AS pct_wit,
      PERCENT_RANK() OVER (ORDER BY raw_influence)  * 100 AS pct_influence
    FROM all_raw
  ),

  -- Division-by-zero guard: new users with no platform data get 50 across all stats.
  -- Do NOT remove this guard — calculate_stat_sheets must run cleanly on any
  -- creator including freshly signed-up market makers.
  budgeted AS (
    SELECT
      user_id,
      platform_count,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_power / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_power,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_charisma / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_charisma,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_resilience / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_resilience,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_agility / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_agility,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_wit / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_wit,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_influence / NULLIF(pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence, 0)) * 300)::INTEGER
      END AS stat_influence
    FROM percentiled
  )

  INSERT INTO creator_stat_sheets (
    user_id,
    stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence,
    effective_power, effective_charisma, effective_resilience,
    effective_agility, effective_wit, effective_influence,
    platform_count, calculated_at
  )
  SELECT
    b.user_id,
    b.stat_power, b.stat_charisma, b.stat_resilience,
    b.stat_agility, b.stat_wit, b.stat_influence,
    ROUND(b.stat_power      * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_charisma   * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_resilience * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_agility    * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_wit        * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_influence  * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    b.platform_count,
    NOW()
  FROM budgeted b
  LEFT JOIN creator_stat_sheets css ON css.user_id = b.user_id
  ON CONFLICT (user_id) DO UPDATE SET
    stat_power      = EXCLUDED.stat_power,
    stat_charisma   = EXCLUDED.stat_charisma,
    stat_resilience = EXCLUDED.stat_resilience,
    stat_agility    = EXCLUDED.stat_agility,
    stat_wit        = EXCLUDED.stat_wit,
    stat_influence  = EXCLUDED.stat_influence,
    effective_power      = EXCLUDED.effective_power,
    effective_charisma   = EXCLUDED.effective_charisma,
    effective_resilience = EXCLUDED.effective_resilience,
    effective_agility    = EXCLUDED.effective_agility,
    effective_wit        = EXCLUDED.effective_wit,
    effective_influence  = EXCLUDED.effective_influence,
    platform_count  = EXCLUDED.platform_count,
    calculated_at   = EXCLUDED.calculated_at;

  INSERT INTO creator_stat_history (
    user_id, stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence, weekly_poll_multiplier
  )
  SELECT
    user_id, stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence, weekly_poll_multiplier
  FROM creator_stat_sheets;

END;
$$;

-- NOTE: scheduling is handled inline at the end of sync-platform-metrics
-- (see doc 2). A pg_cron fallback is intentionally omitted here so the stat
-- recalc remains coupled to the metrics sync that drives it.
