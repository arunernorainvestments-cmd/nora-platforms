-- Migration 151: effect-library framework columns + derivation upgrade (Wave 1).
--
-- Implements the structural half of NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md (MTG color-pie /
-- cycles / rarity + D&D CR-budget imports), scoped to the approved Wave 1 (single-clause).
-- All columns are additive/nullable-or-defaulted — the 10 live templates are untouched except
-- for a stat_lean / magnitude_scales / cycle back-fill. mig 152 seeds the 20 new templates.
--
--   cycle_key        — groups horizontally-authored templates (§2), organizational.
--   grants_keywords  — evergreen keyword(s) the template stamps on the minted chit (§3).
--   complexity       — 1 = single-clause (all of Wave 1); 2 = compound (Wave 2, needs the
--                      resolver extension), gated by min_tier_band.
--   min_tier_band    — min tier a compound template is eligible for at MINT selection only
--                      (never re-picked on ascension — Hard Rule 36 / framework §4 guardrail).
--   stat_lean        — where inside the tier's ATK/HP range the roll lands (§4, CR budget).
--   family_signature — flags a family's identity mechanic (§7, thematic; false in Wave 1).
--   magnitude_scales — FALSE for count/resource effects so they don't explode with tier
--                      (a draw_card at S would draw 8 — reconciliation beyond the framework).

-- ── effect_templates: the framework columns ─────────────────────────────────────
ALTER TABLE public.effect_templates
  ADD COLUMN IF NOT EXISTS cycle_key        TEXT,
  ADD COLUMN IF NOT EXISTS grants_keywords  TEXT[] NOT NULL DEFAULT '{}'
    CHECK (grants_keywords <@ ARRAY['taunt','charge','shield','stealth']::TEXT[]),
  ADD COLUMN IF NOT EXISTS complexity       SMALLINT NOT NULL DEFAULT 1
    CHECK (complexity IN (1,2)),
  ADD COLUMN IF NOT EXISTS min_tier_band    TEXT
    CHECK (min_tier_band IN ('F','E','D','C','B','A','S')),
  ADD COLUMN IF NOT EXISTS stat_lean        TEXT NOT NULL DEFAULT 'balanced'
    CHECK (stat_lean IN ('aggressive','balanced','defensive')),
  ADD COLUMN IF NOT EXISTS family_signature BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS magnitude_scales BOOLEAN NOT NULL DEFAULT TRUE;

-- Compound templates must state their eligibility band (Wave 2 guard; no-op in Wave 1).
ALTER TABLE public.effect_templates DROP CONSTRAINT IF EXISTS effect_template_complexity_band;
ALTER TABLE public.effect_templates
  ADD CONSTRAINT effect_template_complexity_band
  CHECK (complexity = 1 OR min_tier_band IS NOT NULL);

-- ── moments: the server-selected effect (Hard Rule 34 — never client-supplied) ──
-- moment-classify selects the effect from the classified family's candidates and persists
-- it here; cinematic-mint reads it from the moment, ignoring any client-supplied effect.
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS selected_effect_template_id UUID REFERENCES public.effect_templates(id),
  ADD COLUMN IF NOT EXISTS selected_timing             TEXT
    CHECK (selected_timing IN ('on_summon','activated','triggered','counter'));

-- ── back-fill the 10 live templates (stat_lean + count-effect non-scaling + cycles) ──
UPDATE public.effect_templates SET stat_lean = 'aggressive'
  WHERE key IN ('athlete_on_summon_rush','gamer_activated_snipe');
UPDATE public.effect_templates SET stat_lean = 'defensive'
  WHERE key = 'actor_counter_understudy';

-- Count/resource/removal/taunt kinds resolve at their flat base, never scaled by tier.
UPDATE public.effect_templates SET magnitude_scales = FALSE
  WHERE effect_kind IN ('draw_card','disrupt_discard','aura_refund','removal','taunt_grant','summon_token');

-- Existing cycle memberships (the new templates in mig 152 join these).
UPDATE public.effect_templates SET cycle_key = 'single_target_burst' WHERE key = 'gamer_activated_snipe';
UPDATE public.effect_templates SET cycle_key = 'aegis'               WHERE key = 'actor_counter_understudy';

-- ── derive_chit_stats: stat_lean bias + magnitude_scales flat ───────────────────
-- Unchanged contract; now reads the two new template fields. balanced = tier midpoint
-- (rounded); aggressive skews ATK to the top of the range / HP to the bottom (0.75/0.25),
-- defensive the reverse. Non-scaling effects use the flat base magnitude.
CREATE OR REPLACE FUNCTION public.derive_chit_stats(
  p_tier              TEXT,
  p_chit_type         TEXT,
  p_effect_template_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SET search_path = public
AS $$
DECLARE
  v_l      public.tier_ladder%ROWTYPE;
  v_bm     NUMERIC;
  v_scales BOOLEAN := TRUE;
  v_lean   TEXT    := 'balanced';
  v_mag    INTEGER;
  v_fa     NUMERIC;   -- ATK position in range (0..1)
  v_fh     NUMERIC;   -- HP  position in range (0..1)
BEGIN
  SELECT * INTO v_l FROM public.tier_ladder WHERE tier = p_tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown tier: %', p_tier; END IF;

  IF p_effect_template_id IS NOT NULL THEN
    SELECT base_magnitude, COALESCE(magnitude_scales, TRUE), COALESCE(stat_lean, 'balanced')
      INTO v_bm, v_scales, v_lean
    FROM public.effect_templates WHERE id = p_effect_template_id;
    IF v_bm IS NOT NULL THEN
      v_mag := ROUND(CASE WHEN v_scales THEN v_bm * v_l.effect_power ELSE v_bm END)::INTEGER;
    END IF;
  END IF;

  v_fa := CASE v_lean WHEN 'aggressive' THEN 0.75 WHEN 'defensive' THEN 0.25 ELSE 0.5 END;
  v_fh := CASE v_lean WHEN 'aggressive' THEN 0.25 WHEN 'defensive' THEN 0.75 ELSE 0.5 END;

  RETURN jsonb_build_object(
    'aura_cost',        (v_l.aura_cost_min + v_l.aura_cost_max) / 2,   -- cost is lean-independent
    'atk',              CASE WHEN p_chit_type = 'creature'
                             THEN ROUND(v_l.atk_min + v_fa * (v_l.atk_max - v_l.atk_min))::INTEGER ELSE NULL END,
    'hp',               CASE WHEN p_chit_type = 'creature'
                             THEN ROUND(v_l.hp_min + v_fh * (v_l.hp_max - v_l.hp_min))::INTEGER ELSE NULL END,
    'effect_magnitude', v_mag
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: stat_lean biases the roll; magnitude_scales flattens counts.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_agg UUID; v_def UUID; v_count UUID;
  v_a JSONB; v_d JSONB; v_s_low JSONB; v_s_high JSONB;
BEGIN
  SELECT id INTO v_agg   FROM public.effect_templates WHERE key = 'athlete_on_summon_rush';
  SELECT id INTO v_def   FROM public.effect_templates WHERE key = 'actor_counter_understudy';
  SELECT id INTO v_count FROM public.effect_templates WHERE key = 'influencer_on_summon_viral';

  -- Aggressive vs defensive at the same tier: aggressive ATK ≥ defensive ATK, HP ≤.
  v_a := public.derive_chit_stats('A', 'creature', v_agg);
  v_d := public.derive_chit_stats('A', 'creature', v_def);
  IF (v_a->>'atk')::INT < (v_d->>'atk')::INT OR (v_a->>'hp')::INT > (v_d->>'hp')::INT THEN
    RAISE EXCEPTION 'SMOKE FAIL: stat_lean bias wrong (agg %/% vs def %/%)',
      v_a->>'atk', v_a->>'hp', v_d->>'atk', v_d->>'hp';
  END IF;

  -- A non-scaling count effect has the SAME magnitude at F and S (flat base).
  v_s_low  := public.derive_chit_stats('F', 'creature', v_count);
  v_s_high := public.derive_chit_stats('S', 'creature', v_count);
  IF (v_s_low->>'effect_magnitude') IS DISTINCT FROM (v_s_high->>'effect_magnitude') THEN
    RAISE EXCEPTION 'SMOKE FAIL: magnitude_scales=false should be tier-flat (F=% S=%)',
      v_s_low->>'effect_magnitude', v_s_high->>'effect_magnitude';
  END IF;

  RAISE NOTICE 'effect-library-framework smoke OK: stat_lean bias + non-scaling counts';
END $$;
