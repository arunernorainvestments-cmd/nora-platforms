-- Migration 024: Two-tier category system
-- Replaces the flat 14-category list on profiles with:
--   category_1  TEXT — one of 10 primary categories (check constraint updated)
--   subcategory TEXT — role-specific label within that primary (new column)
--
-- category_2 is nulled out and retired; the column is left in place to avoid
-- a potentially risky DROP COLUMN on a large table. All app code stops reading it.

-- ── 1. Drop old CHECK constraints ────────────────────────────────────────────
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_category_1_check,
  DROP CONSTRAINT IF EXISTS profiles_category_2_check;

-- ── 2. Add subcategory column ─────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS subcategory TEXT;

-- ── 3. Migrate old category_1 values → new primary + subcategory ─────────────
-- Direct 1:1 — already valid primary categories, no subcategory yet
-- (Athlete, Influencer, Musician, Healthcare, Politician, Gamer,
--  Educator, Business, Religion are all valid primaries → leave as-is)

-- Comedian → Performer / Comedian
UPDATE public.profiles
SET category_1 = 'Performer', subcategory = 'Comedian'
WHERE category_1 = 'Comedian';

-- Doctor → Healthcare / Doctor General
UPDATE public.profiles
SET category_1 = 'Healthcare', subcategory = 'Doctor General'
WHERE category_1 = 'Doctor';

-- Researcher → Healthcare / Researcher
UPDATE public.profiles
SET category_1 = 'Healthcare', subcategory = 'Researcher'
WHERE category_1 = 'Researcher';

-- Fitness → Influencer / Fitness
UPDATE public.profiles
SET category_1 = 'Influencer', subcategory = 'Fitness'
WHERE category_1 = 'Fitness';

-- Sports → Athlete / null (flag for reselection)
UPDATE public.profiles
SET category_1 = 'Athlete', subcategory = NULL
WHERE category_1 = 'Sports';

-- ── 4. Retire category_2 ──────────────────────────────────────────────────────
-- The new structure supports one primary + one subcategory.
-- Any second primary a user had is cleared; they can reselect after launch.
UPDATE public.profiles SET category_2 = NULL;

-- ── 5. Add new CHECK constraint for the 10 primary categories ────────────────
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_category_1_check
  CHECK (
    category_1 IS NULL OR category_1 IN (
      'Athlete', 'Musician', 'Healthcare', 'Performer', 'Gamer',
      'Influencer', 'Educator', 'Politician', 'Religion', 'Business'
    )
  );

-- ── 6. Also update the markets table category snapshot columns ───────────────
-- Markets snapshot category_1 from the creator's profile at creation time.
-- Old markets may have stale values; update them using the same mapping so
-- the markets screen filter tabs work correctly.

UPDATE public.markets SET category_1 = 'Performer' WHERE category_1 = 'Comedian';
UPDATE public.markets SET category_1 = 'Healthcare' WHERE category_1 = 'Doctor';
UPDATE public.markets SET category_1 = 'Healthcare' WHERE category_1 = 'Researcher';
UPDATE public.markets SET category_1 = 'Influencer' WHERE category_1 = 'Fitness';
UPDATE public.markets SET category_1 = 'Athlete'    WHERE category_1 = 'Sports';
UPDATE public.markets SET category_2 = NULL; -- retire category_2 on markets too
