-- ─────────────────────────────────────────────────────────────────────────────
-- 005_social_oauth.sql — Platform OAuth connections + live metrics cache
-- ─────────────────────────────────────────────────────────────────────────────

-- Stores OAuth tokens per user per platform
CREATE TABLE platform_connections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform         text NOT NULL CHECK (platform IN (
                     'youtube','twitch','tiktok','instagram','facebook','x','kick'
                   )),
  platform_user_id text NOT NULL,           -- e.g. YouTube channel ID
  platform_username text,                   -- display name on platform
  access_token     text NOT NULL,
  refresh_token    text,
  token_expires_at timestamptz,
  scopes           text[],                  -- granted OAuth scopes
  connected_at     timestamptz DEFAULT now(),
  last_synced_at   timestamptz,
  is_active        boolean DEFAULT true,
  UNIQUE(user_id, platform)
);

-- Live + follower metrics cache (refreshed every 5 minutes)
CREATE TABLE platform_metrics (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_connection_id uuid NOT NULL REFERENCES platform_connections(id) ON DELETE CASCADE,
  user_id                uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform               text NOT NULL,
  is_live                boolean DEFAULT false,
  live_viewer_count      integer DEFAULT 0,
  follower_count         bigint DEFAULT 0,
  subscriber_count       bigint DEFAULT 0,    -- YouTube only
  stream_title           text,
  stream_category        text,               -- Twitch game/category
  heat_score             numeric(5,2) DEFAULT 0,
  raw_metrics            jsonb,
  fetched_at             timestamptz DEFAULT now(),
  UNIQUE(platform_connection_id)
);

-- Indexes
CREATE INDEX idx_platform_connections_user     ON platform_connections(user_id);
CREATE INDEX idx_platform_connections_platform ON platform_connections(platform);
CREATE INDEX idx_platform_metrics_user         ON platform_metrics(user_id);
CREATE INDEX idx_platform_metrics_live         ON platform_metrics(is_live) WHERE is_live = true;
CREATE INDEX idx_platform_metrics_heat         ON platform_metrics(heat_score DESC);

-- ── RLS ──────────────────────────────────────────────────────────────────────

ALTER TABLE platform_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_metrics ENABLE ROW LEVEL SECURITY;

-- Users can read their own connections
CREATE POLICY "users_read_own_connections" ON platform_connections
  FOR SELECT USING (auth.uid() = user_id);

-- Service role only for writes (edge functions use service role)
CREATE POLICY "service_write_connections" ON platform_connections
  FOR ALL USING (auth.role() = 'service_role');

-- Platform metrics: users read their own; public reads live data only
CREATE POLICY "users_read_own_metrics" ON platform_metrics
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "public_read_live_metrics" ON platform_metrics
  FOR SELECT USING (is_live = true);

CREATE POLICY "service_write_metrics" ON platform_metrics
  FOR ALL USING (auth.role() = 'service_role');

-- ── Trigger: sync heat_score → spotlight_scores ───────────────────────────────

CREATE OR REPLACE FUNCTION update_spotlight_from_heat()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE spotlight_scores
  SET score      = NEW.heat_score,
      updated_at = now()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_update_spotlight
  AFTER INSERT OR UPDATE OF heat_score ON platform_metrics
  FOR EACH ROW EXECUTE FUNCTION update_spotlight_from_heat();
