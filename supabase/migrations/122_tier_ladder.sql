-- Migration 122: tier ladder + engagement thresholds (Phase 2 — P2.1).
--
-- THE CORE BALANCE TABLE. Tiers F/E/D/C/B/A/S are COST-BANDED: a higher tier is
-- stronger AND costs more Aura (Hard Rule 34) — an S-tier is a different point on the
-- curve, never strictly-better-for-cost. A statement-level guard enforces that Aura cost
-- is monotonic non-decreasing by tier rank, so rebalancing (SQL UPDATE) can never break
-- cost-banding. All values are illustrative + tunable (rebalance via UPDATE only).
--
-- Aura cap is 10 (§1 combat constants), so no cost band exceeds 10.
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 2.1.

-- ── tier_ladder ─────────────────────────────────────────────────────────────────
CREATE TABLE public.tier_ladder (
  tier            TEXT PRIMARY KEY CHECK (tier IN ('F','E','D','C','B','A','S')),
  tier_rank       SMALLINT NOT NULL UNIQUE CHECK (tier_rank BETWEEN 1 AND 7),  -- F=1 … S=7
  aura_cost_min   INTEGER NOT NULL CHECK (aura_cost_min BETWEEN 0 AND 10),
  aura_cost_max   INTEGER NOT NULL CHECK (aura_cost_max BETWEEN 0 AND 10),
  atk_min         INTEGER NOT NULL CHECK (atk_min >= 0),
  atk_max         INTEGER NOT NULL CHECK (atk_max >= 0),
  hp_min          INTEGER NOT NULL CHECK (hp_min >= 1),
  hp_max          INTEGER NOT NULL CHECK (hp_max >= 1),
  effect_power    NUMERIC NOT NULL CHECK (effect_power > 0),   -- magnitude scalar for effect templates
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT tier_cost_range_ok CHECK (aura_cost_min <= aura_cost_max),
  CONSTRAINT tier_atk_range_ok  CHECK (atk_min <= atk_max),
  CONSTRAINT tier_hp_range_ok   CHECK (hp_min <= hp_max)
);

-- ── cost-banding guard (Hard Rule 34): cost + stats monotonic by rank ────────────
CREATE OR REPLACE FUNCTION public.assert_tier_cost_banding()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE v_bad INTEGER;
BEGIN
  -- Any higher-ranked tier must NOT cost less (min) or hit weaker (max) than a lower rank.
  SELECT COUNT(*) INTO v_bad
  FROM public.tier_ladder lo
  JOIN public.tier_ladder hi ON hi.tier_rank > lo.tier_rank
  WHERE hi.aura_cost_min < lo.aura_cost_min
     OR hi.aura_cost_max < lo.aura_cost_max
     OR hi.atk_max       < lo.atk_max
     OR hi.hp_max        < lo.hp_max
     OR hi.effect_power  < lo.effect_power;

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'tier_ladder violates cost-banding: a higher tier costs less / is weaker than a lower tier (Hard Rule 34)';
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER tier_ladder_cost_banding
  AFTER INSERT OR UPDATE OR DELETE ON public.tier_ladder
  FOR EACH STATEMENT EXECUTE FUNCTION public.assert_tier_cost_banding();

-- ── seed the ladder (cost-banded; tunable) ──────────────────────────────────────
INSERT INTO public.tier_ladder
  (tier, tier_rank, aura_cost_min, aura_cost_max, atk_min, atk_max, hp_min, hp_max, effect_power) VALUES
  ('F', 1,  1, 1,   1,  2,   1,  3,  1),
  ('E', 2,  2, 2,   2,  3,   2,  4,  2),
  ('D', 3,  3, 3,   3,  5,   3,  6,  3),
  ('C', 4,  4, 5,   4,  6,   5,  8,  4),
  ('B', 5,  6, 7,   6,  8,   7, 10,  5),
  ('A', 6,  8, 9,   8, 11,  10, 13,  6),
  ('S', 7, 10, 10, 11, 14,  13, 17,  8);

-- ── engagement → tier thresholds (min engagement inclusive, per §Phase 2.2) ─────
CREATE TABLE public.engagement_tier_thresholds (
  tier            TEXT PRIMARY KEY REFERENCES public.tier_ladder(tier),
  min_engagement  BIGINT NOT NULL CHECK (min_engagement >= 0),  -- normalized post-engagement
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.engagement_tier_thresholds (tier, min_engagement) VALUES
  ('F', 0),
  ('E', 1000),
  ('D', 10000),
  ('C', 50000),
  ('B', 250000),
  ('A', 1000000),
  ('S', 5000000);

-- tier_for_engagement: highest tier whose min_engagement <= count (mint + ascension read this).
CREATE OR REPLACE FUNCTION public.tier_for_engagement(p_engagement BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT tier FROM public.engagement_tier_thresholds
  WHERE min_engagement <= GREATEST(p_engagement, 0)
  ORDER BY min_engagement DESC
  LIMIT 1;
$$;

-- ── RLS: both are public-read reference data; no client writes ───────────────────
ALTER TABLE public.tier_ladder                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_tier_thresholds ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tier_ladder_public_read" ON public.tier_ladder
  FOR SELECT USING (true);
CREATE POLICY "engagement_thresholds_public_read" ON public.engagement_tier_thresholds
  FOR SELECT USING (true);
