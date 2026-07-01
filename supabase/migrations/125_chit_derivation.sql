-- Migration 125: chit stat derivation + server-only writer (Phase 2 — P2.4).
--
-- Given (family, timing, tier[, effect template]) → concrete (aura_cost, atk, hp,
-- effect_magnitude) from the cost-banded tier ladder. This is the ONLY sanctioned way to
-- set a chit's power (Hard Rule 34): mint (P6), pack seeding, ascension (P6 re-derive),
-- and dev seeds all go through create_moment_chit(). Users never set power.
--
-- Also completes the mig-116 catalog: adds effect_magnitude + the effect_ref → effect_templates FK.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 2.4.

-- ── finish the catalog schema (deferred from mig 116) ───────────────────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS effect_magnitude INTEGER CHECK (effect_magnitude >= 0);

ALTER TABLE public.moment_chits
  ADD CONSTRAINT moment_chits_effect_ref_fk
  FOREIGN KEY (effect_ref) REFERENCES public.effect_templates(id);

-- ── derive_chit_stats: pure derivation from the ladder ──────────────────────────
-- Returns {aura_cost, atk, hp, effect_magnitude}. atk/hp NULL for spell_moment.
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
  v_l   public.tier_ladder%ROWTYPE;
  v_bm  NUMERIC;
  v_mag INTEGER;
BEGIN
  SELECT * INTO v_l FROM public.tier_ladder WHERE tier = p_tier;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown tier: %', p_tier; END IF;

  IF p_effect_template_id IS NOT NULL THEN
    SELECT base_magnitude INTO v_bm FROM public.effect_templates WHERE id = p_effect_template_id;
    IF v_bm IS NOT NULL THEN
      v_mag := ROUND(v_bm * v_l.effect_power)::INTEGER;   -- magnitude scaled to tier
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'aura_cost',        (v_l.aura_cost_min + v_l.aura_cost_max) / 2,   -- integer midpoint
    'atk',              CASE WHEN p_chit_type = 'creature'
                             THEN (v_l.atk_min + v_l.atk_max) / 2 ELSE NULL END,
    'hp',               CASE WHEN p_chit_type = 'creature'
                             THEN (v_l.hp_min + v_l.hp_max) / 2 ELSE NULL END,
    'effect_magnitude', v_mag
  );
END;
$$;

-- ── create_moment_chit: the sanctioned catalog writer ───────────────────────────
CREATE OR REPLACE FUNCTION public.create_moment_chit(
  p_name              TEXT,
  p_family            TEXT,
  p_chit_type         TEXT,
  p_tier              TEXT,
  p_timing            TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_character_class   TEXT DEFAULT 'consent_minted',
  p_moment_id         UUID DEFAULT NULL,
  p_keywords          TEXT[] DEFAULT '{}',
  p_vibe_gate         INTEGER DEFAULT NULL,
  p_card_art_url      TEXT DEFAULT NULL,
  p_moment_video_ref  TEXT DEFAULT NULL,
  p_description       TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stats JSONB;
  v_tmpl  public.effect_templates%ROWTYPE;
  v_id    UUID;
BEGIN
  -- Effect template must line up with the chit's family/timing (non-fusion templates).
  IF p_effect_template_id IS NOT NULL THEN
    SELECT * INTO v_tmpl FROM public.effect_templates WHERE id = p_effect_template_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown effect template: %', p_effect_template_id; END IF;
    IF v_tmpl.is_fusion THEN
      RAISE EXCEPTION 'Fusion templates are not directly attachable to a chit';
    END IF;
    IF v_tmpl.archetype_family <> p_family OR v_tmpl.timing_type IS DISTINCT FROM p_timing THEN
      RAISE EXCEPTION 'Effect template %/% does not match chit family %/timing %',
        v_tmpl.archetype_family, v_tmpl.timing_type, p_family, p_timing;
    END IF;
  END IF;

  v_stats := public.derive_chit_stats(p_tier, p_chit_type, p_effect_template_id);

  INSERT INTO public.moment_chits (
    moment_id, name, description, character_class, chit_type, archetype_family, tier,
    aura_cost, atk, hp, timing_type, keywords, effect_ref, effect_magnitude,
    vibe_gate, card_art_url, moment_video_ref
  ) VALUES (
    p_moment_id, p_name, p_description, p_character_class, p_chit_type, p_family, p_tier,
    (v_stats->>'aura_cost')::INTEGER,
    (v_stats->>'atk')::INTEGER,
    (v_stats->>'hp')::INTEGER,
    p_timing, COALESCE(p_keywords, '{}'), p_effect_template_id,
    (v_stats->>'effect_magnitude')::INTEGER,
    p_vibe_gate, p_card_art_url, p_moment_video_ref
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ── dev seed: a handful of catalog chits exercising the full chain ──────────────
-- Seeding through create_moment_chit validates derivation + FK + all CHECKs at apply
-- time. DEV seed (character_class flavor for testing) — swept by the P7 pre-launch reset.
DO $$
DECLARE fam TEXT; tmpl UUID;
BEGIN
  -- Two athletes (fusion-eligible: fuse_athlete_pair), one with charge.
  PERFORM public.create_moment_chit('Seed Sprinter','athlete','creature','C','on_summon',
    (SELECT id FROM public.effect_templates WHERE key='athlete_on_summon_rush'),
    'licensed', NULL, ARRAY['charge']::TEXT[], NULL, NULL, NULL, 'Dev seed athlete (charge).');
  PERFORM public.create_moment_chit('Seed Striker','athlete','creature','B','on_summon',
    (SELECT id FROM public.effect_templates WHERE key='athlete_on_summon_rush'),
    'licensed', NULL, ARRAY['charge']::TEXT[], NULL, NULL, NULL, 'Dev seed athlete (charge).');
  -- A musician (AoE debuff), an influencer draw, a scientist removal spell, an S-tier gated.
  PERFORM public.create_moment_chit('Seed Diva','musician','creature','C','on_summon',
    (SELECT id FROM public.effect_templates WHERE key='musician_on_summon_encore'),
    'licensed', NULL, '{}'::TEXT[], NULL, NULL, NULL, 'Dev seed musician.');
  PERFORM public.create_moment_chit('Seed Streamer','influencer','creature','D','on_summon',
    (SELECT id FROM public.effect_templates WHERE key='influencer_on_summon_viral'),
    'licensed', NULL, ARRAY['stealth']::TEXT[], NULL, NULL, NULL, 'Dev seed influencer.');
  PERFORM public.create_moment_chit('Seed Purge','scientist','spell_moment','C','activated',
    (SELECT id FROM public.effect_templates WHERE key='scientist_activated_purge'),
    'licensed', NULL, '{}'::TEXT[], NULL, NULL, NULL, 'Dev seed removal spell.');
  PERFORM public.create_moment_chit('Seed Legend','actor','creature','S','counter',
    (SELECT id FROM public.effect_templates WHERE key='actor_counter_understudy'),
    'licensed', NULL, ARRAY['taunt']::TEXT[], 60, NULL, NULL, 'Dev seed S-tier, Vibe-gated 60.');
END $$;
