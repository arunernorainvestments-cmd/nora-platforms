-- Migration 014: active_boosts table for Promotions & Power-Ups
-- Tracks all time-limited heat_score modifications and cosmetic effects.
-- heat_score is always recomputed as display_score + sum(active non-cancelled deltas)
-- by sync-platform-metrics — this table is the source of truth for active modifications.

CREATE TABLE public.active_boosts (
  id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  target_user_id        UUID          NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  activated_by_user_id  UUID          NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  boost_type            TEXT          NOT NULL CHECK (boost_type IN (
                                        'quick_boost',
                                        'major_boost',
                                        'spotlight_entry',
                                        'instant_plus',
                                        'instant_minus',
                                        'universe',
                                        'galaxy',
                                        'black_hole'
                                      )),
  -- Signed delta applied to heat_score. 0 for cosmetic-only types (universe, galaxy, black_hole).
  heat_score_delta      NUMERIC       NOT NULL DEFAULT 0,
  tokens_spent          INTEGER       NOT NULL,
  -- NULL expires_at = instant effect (black_hole). Otherwise the row is active until this time.
  expires_at            TIMESTAMPTZ,
  -- Set to TRUE by black_hole cancellations or manual admin action.
  is_cancelled          BOOLEAN       NOT NULL DEFAULT FALSE,
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Index for the hot query: active boosts per target user
CREATE INDEX active_boosts_target_user_idx
  ON public.active_boosts (target_user_id, is_cancelled, expires_at);

-- Index for cooldown checks: boosts by activator on a given target
CREATE INDEX active_boosts_activator_idx
  ON public.active_boosts (activated_by_user_id, target_user_id, boost_type, created_at DESC);

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE public.active_boosts ENABLE ROW LEVEL SECURITY;

-- Users can read boosts where they are the activator or the target
CREATE POLICY "users_read_own_boosts"
  ON public.active_boosts FOR SELECT
  USING (
    auth.uid() = activated_by_user_id
    OR auth.uid() = target_user_id
  );

-- All writes go through the service role (edge functions only)
-- No INSERT/UPDATE/DELETE policies for authenticated role
