-- Migration 137: fusion expansion + magnitude balance pass (Phase 7 — P7.1, partial).
--
-- Additive/tuning only. The DESTRUCTIVE P7 items (physically archiving the legacy 1v1/
-- battle_abilities tables, dropping check_battle_eligibility/get_eligible_characters,
-- removing dev_* tooling, the pre-launch reset) are DEFERRED to launch prep — the mobile
-- client still consumes the legacy fns and the pending companion↔nora-arena pivot may change
-- what "legacy" means. See NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md P7.
--
-- Balance: the launch fusion magnitude was too high (base × Σ effect_power ≈ 27 face dmg on
-- turn 2). Two changes: (1) gentle effect_power curve on tier_ladder; (2) fusion rules use
-- 'avg' scaling. Then re-derive the existing seed chits so their magnitudes update.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 7.

-- ── (1) gentler effect_power curve (still monotonic — passes cost-banding guard) ─
UPDATE public.tier_ladder SET effect_power = v.ep
FROM (VALUES ('F',1),('E',1),('D',2),('C',2),('B',3),('A',3),('S',4)) AS v(tier, ep)
WHERE public.tier_ladder.tier = v.tier;

-- ── (2) existing fusion rules → 'avg' scaling (gentler than 'sum') ───────────────
UPDATE public.fusion_rules SET power_scaling = 'avg' WHERE power_scaling <> 'avg';

-- ── fusion expansion: more templates + rules (content, not engine) ──────────────
INSERT INTO public.effect_templates (key, name, is_fusion, effect_kind, target, base_magnitude, description) VALUES
  ('fusion_control_purge', 'Control Purge', TRUE, 'removal',         'enemy_target', 1,
     'Two minds fuse to erase a threat.'),
  ('fusion_disrupt',       'Punchline',     TRUE, 'disrupt_discard', 'enemy_target', 2,
     'A comedic tag-team rattles the opponent''s hand.'),
  ('fusion_wall',          'Phalanx',       TRUE, 'shield_grant',    'all_allies',   2,
     'Shielded units lock formation.')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.fusion_rules (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_scientist_pair', 'Scientist Control', 'scientist', NULL, 2,
       (SELECT id FROM public.effect_templates WHERE key='fusion_control_purge'), 'avg',
       '≥2 Scientist-family creatures in one turn → remove an enemy creature.'
WHERE NOT EXISTS (SELECT 1 FROM public.fusion_rules WHERE key='fuse_scientist_pair');

INSERT INTO public.fusion_rules (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_comedian_pair', 'Comedian Disruption', 'comedian', NULL, 2,
       (SELECT id FROM public.effect_templates WHERE key='fusion_disrupt'), 'avg',
       '≥2 Comedian-family creatures in one turn → opponent discards.'
WHERE NOT EXISTS (SELECT 1 FROM public.fusion_rules WHERE key='fuse_comedian_pair');

INSERT INTO public.fusion_rules (key, name, match_family, match_keyword, min_count, fusion_effect_template_id, power_scaling, description)
SELECT 'fuse_shield_pair', 'Phalanx Formation', NULL, 'shield', 2,
       (SELECT id FROM public.effect_templates WHERE key='fusion_wall'), 'avg',
       '≥2 creatures with shield in one turn → shield the whole board.'
WHERE NOT EXISTS (SELECT 1 FROM public.fusion_rules WHERE key='fuse_shield_pair');

-- ── re-derive the seed chits so magnitudes reflect the new effect_power ──────────
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id, tier FROM public.moment_chits WHERE name LIKE 'Seed %' LOOP
    PERFORM public.moment_chit_rederive(r.id, r.tier);
  END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Smoke: gentler magnitudes (Seed Sprinter C: base 2 × effect_power 2 = 4), all fusion
-- rules on 'avg', and the expanded rule set present.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_mag INTEGER; v_nonavg INTEGER; v_rules INTEGER;
BEGIN
  SELECT effect_magnitude INTO v_mag FROM public.moment_chits WHERE name='Seed Sprinter';
  IF v_mag IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'SMOKE FAIL: Seed Sprinter magnitude expected 4, got %', v_mag; END IF;

  SELECT COUNT(*) INTO v_nonavg FROM public.fusion_rules WHERE power_scaling <> 'avg';
  IF v_nonavg <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: % fusion rules not on avg scaling', v_nonavg; END IF;

  SELECT COUNT(*) INTO v_rules FROM public.fusion_rules WHERE is_active;
  IF v_rules < 6 THEN RAISE EXCEPTION 'SMOKE FAIL: expected ≥6 fusion rules, got %', v_rules; END IF;

  RAISE NOTICE 'P7 fusion/balance smoke OK: seed magnitude 4, all rules avg, % fusion rules', v_rules;
END $$;
