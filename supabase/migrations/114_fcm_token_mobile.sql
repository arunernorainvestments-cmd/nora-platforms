-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 114 — Mobile push token (doc6: Arena/Battle mobile app)
-- The nora-arena mobile app registers a Firebase Cloud Messaging token per user
-- so the backend can push battle invites, bet-resolution, and license-sync events.
-- The web app does not use FCM; this column is mobile-only and nullable.
--
-- doc6 §Push Notifications: "Add to web repo as migration 114 (runs after doc5's
-- 108–113): ALTER TABLE profiles ADD COLUMN fcm_token_mobile TEXT;"
-- Runs after the doc5 licensing migrations (108–113).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS fcm_token_mobile TEXT;

COMMENT ON COLUMN public.profiles.fcm_token_mobile IS
  'Firebase Cloud Messaging registration token for the nora-arena mobile app. '
  'NULL for web-only users. Updated by the app on each launch / token refresh.';
