-- Rename heat_score → display_score (raw computed composite, never modified by promotions)
-- Rename display_score → heat_score (0–100 UI composite, can be modified by promotions)

-- Step 1: Add new columns with temporary names to avoid collision
ALTER TABLE public.platform_metrics
ADD COLUMN IF NOT EXISTS _new_heat_score NUMERIC,
ADD COLUMN IF NOT EXISTS _new_display_score NUMERIC;

-- Step 2: Copy data across
UPDATE public.platform_metrics SET
  _new_heat_score = display_score,
  _new_display_score = heat_score;

-- Step 3: Drop old columns
ALTER TABLE public.platform_metrics
DROP COLUMN heat_score,
DROP COLUMN display_score;

-- Step 4: Rename temp columns to final names
ALTER TABLE public.platform_metrics
RENAME COLUMN _new_heat_score TO heat_score;

ALTER TABLE public.platform_metrics
RENAME COLUMN _new_display_score TO display_score;

-- Markets table: rename opening_display_score → opening_heat_score
ALTER TABLE public.markets
RENAME COLUMN opening_display_score TO opening_heat_score;
