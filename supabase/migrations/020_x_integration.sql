-- Migration 020: X (Twitter) Integration
-- Adds X-specific raw metric columns to platform_metrics.
-- display_score, follower_count, and live_viewer_count already exist (migrations 005, 019).

ALTER TABLE platform_metrics
  ADD COLUMN IF NOT EXISTS recent_post_views bigint DEFAULT 0;

ALTER TABLE platform_metrics
  ADD COLUMN IF NOT EXISTS recent_post_reposts integer DEFAULT 0;

ALTER TABLE platform_metrics
  ADD COLUMN IF NOT EXISTS recent_post_likes integer DEFAULT 0;
