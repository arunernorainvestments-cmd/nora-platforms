-- Migration 124: fusion rules (Phase 2 — P2.3).
--
-- Fusion is TAG-BASED: authored PATTERNS keyed on {archetype_family, keyword, element/tag,
-- count}, never per-card recipes — so a rule applies to ANY qualifying chit, including
-- user-minted ones. A rule maps to a fusion effect template (is_fusion) whose power scales
-- with the component chits' tiers. Detection/resolution lives in P3 (the engine); this
-- migration defines the rule + fusion-effect data model and a launch starter set.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 2.3.

-- ── fusion effect templates (family/timing-agnostic effect_templates rows) ──────
INSERT INTO public.effect_templates
  (key, name, is_fusion, effect_kind, target, base_magnitude, description) VALUES
  ('fusion_power_advance', 'Power-Advance', TRUE, 'direct_damage', 'enemy_face',  3,
     'Combined strike from a coordinated athlete push.'),
  ('fusion_blitz',         'Blitz',         TRUE, 'direct_damage', 'enemy_target', 3,
     'Two charging bodies fuse into a single decisive hit.'),
  ('fusion_crowd_roar',    'Crowd Roar',    TRUE, 'aoe_damage',    'all_enemies',  2,
     'A duet overwhelms the whole enemy board.');

-- ── fusion_rules ────────────────────────────────────────────────────────────────
CREATE TABLE public.fusion_rules (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key                       TEXT NOT NULL UNIQUE,
  name                      TEXT NOT NULL,

  -- Pattern to match (at least one of family/keyword/tag). NULL = wildcard on that facet.
  match_family              TEXT CHECK (match_family IN (
    'athlete','musician','artist','scientist','comedian',
    'influencer','politician','business','gamer','actor'
  )),
  match_keyword             TEXT CHECK (match_keyword IN ('taunt','charge','shield','stealth')),
  match_tag                 TEXT,                         -- free element/tag facet
  min_count                 INTEGER NOT NULL DEFAULT 2 CHECK (min_count >= 2),
  same_turn                 BOOLEAN NOT NULL DEFAULT TRUE, -- within one turn's Advance window

  fusion_effect_template_id UUID NOT NULL REFERENCES public.effect_templates(id),
  -- How the component chits' tier effect_power combines into the fusion magnitude.
  power_scaling             TEXT NOT NULL DEFAULT 'sum' CHECK (power_scaling IN ('sum','max','avg')),

  description               TEXT,
  is_active                 BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT fusion_rule_has_facet CHECK (
    match_family IS NOT NULL OR match_keyword IS NOT NULL OR match_tag IS NOT NULL
  )
);

CREATE INDEX fusion_rules_active_idx ON public.fusion_rules (is_active);

-- fusion effect template must actually be a fusion template.
CREATE OR REPLACE FUNCTION public.fusion_rule_template_guard()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.effect_templates
    WHERE id = NEW.fusion_effect_template_id AND is_fusion = TRUE
  ) THEN
    RAISE EXCEPTION 'fusion_rules.fusion_effect_template_id must reference an is_fusion effect_template';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER fusion_rules_template_check
  BEFORE INSERT OR UPDATE ON public.fusion_rules
  FOR EACH ROW EXECUTE FUNCTION public.fusion_rule_template_guard();

-- ── launch starter set (expandable in P7) ───────────────────────────────────────
INSERT INTO public.fusion_rules
  (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_athlete_pair', 'Athlete Power-Advance', 'athlete', NULL, 2,
       (SELECT id FROM public.effect_templates WHERE key = 'fusion_power_advance'), 'sum',
       '≥2 Athlete-family creatures summoned in one turn → Power-Advance combined strike.';

INSERT INTO public.fusion_rules
  (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_charge_pair', 'Charge Blitz', NULL, 'charge', 2,
       (SELECT id FROM public.effect_templates WHERE key = 'fusion_blitz'), 'max',
       '≥2 creatures with charge summoned in one turn → Blitz direct hit.';

INSERT INTO public.fusion_rules
  (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_musician_pair', 'Musician Crowd Roar', 'musician', NULL, 2,
       (SELECT id FROM public.effect_templates WHERE key = 'fusion_crowd_roar'), 'avg',
       '≥2 Musician-family creatures summoned in one turn → Crowd Roar AoE.';

-- ── RLS: public-read reference; no client writes ────────────────────────────────
ALTER TABLE public.fusion_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fusion_rules_public_read" ON public.fusion_rules
  FOR SELECT USING (is_active);
