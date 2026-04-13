-- Migration 015: promotion_banners table + super_massive_black_hole boost type
-- promotion_banners is the source of truth for the home ticker and flash banner overlay.
-- Realtime must be enabled on this table in the Supabase Dashboard → Database → Replication.

-- ── 1. Update active_boosts CHECK constraint to include super_massive_black_hole ─

-- Drop the existing unnamed check constraint on boost_type
DO $$
DECLARE
  c TEXT;
BEGIN
  SELECT conname INTO c
  FROM pg_constraint
  WHERE conrelid = 'public.active_boosts'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%boost_type%';
  IF c IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.active_boosts DROP CONSTRAINT ' || quote_ident(c);
  END IF;
END $$;

ALTER TABLE public.active_boosts
  ADD CONSTRAINT active_boosts_boost_type_check CHECK (boost_type IN (
    'quick_boost',
    'major_boost',
    'spotlight_entry',
    'instant_plus',
    'instant_minus',
    'universe',
    'galaxy',
    'black_hole',
    'super_massive_black_hole'
  ));

-- ── 2. promotion_banners table ────────────────────────────────────────────────

CREATE TABLE public.promotion_banners (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  boost_id         UUID         REFERENCES public.active_boosts(id) ON DELETE CASCADE,
  type             TEXT         NOT NULL CHECK (type IN ('universe', 'galaxy')),
  target_user_id   UUID         NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  target_username  TEXT         NOT NULL,
  -- category_1 of the target MM — populated for galaxy only, NULL for universe
  category         TEXT,
  expires_at       TIMESTAMPTZ  NOT NULL,
  is_cancelled     BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX promotion_banners_active_idx
  ON public.promotion_banners (is_cancelled, expires_at)
  WHERE is_cancelled = FALSE;

CREATE INDEX promotion_banners_target_idx
  ON public.promotion_banners (target_user_id, is_cancelled);

-- ── RLS ───────────────────────────────────────────────────────────────────────
ALTER TABLE public.promotion_banners ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read active (non-cancelled, non-expired) banners.
-- Galaxy filtering (by category) is done client-side in Flutter.
CREATE POLICY "all_read_active_banners"
  ON public.promotion_banners FOR SELECT
  USING (is_cancelled = FALSE);

-- All writes via service role only (edge functions).

-- ── 3. Enable Realtime on promotion_banners ───────────────────────────────────
-- This publishes INSERT/UPDATE events to connected Flutter clients.
ALTER PUBLICATION supabase_realtime ADD TABLE public.promotion_banners;
