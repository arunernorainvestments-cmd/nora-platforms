-- Migration 152: effect-library Wave 1 seed — 20 new single-clause templates.
--
-- Per NORA_CHIT_EFFECT_LIBRARY_WAVE1.md (user-approved balance numbers). Two new templates
-- per family (each family already had one live template → 3 total). Authored horizontally by
-- cycle (§2), each obeying its family's identity matrix (§1). complexity=1 for all (compound
-- is Wave 2). Depends on mig 151 (columns + magnitude_scales-aware derivation).
--
-- Magnitude convention: count/resource/taunt effects carry magnitude_scales=FALSE (flat base);
-- damage/buff/heal/shield scale with tier.effect_power.

INSERT INTO public.effect_templates
  (key, name, archetype_family, timing_type, effect_kind, target, base_magnitude,
   trigger_condition, description, cycle_key, grants_keywords, stat_lean, magnitude_scales) VALUES

-- ── Athlete (P: direct_damage, buff_atk) ──────────────────────────────────────
  ('athlete_on_summon_highlight', 'Highlight Reel', 'athlete', 'on_summon', 'direct_damage', 'enemy_target', 2,
     NULL, 'A signature play that lands the instant it drops — deals damage and can strike immediately.',
     'single_target_burst', ARRAY['charge']::TEXT[], 'aggressive', TRUE),
  ('athlete_activated_secondwind', 'Second Wind', 'athlete', 'activated', 'heal', 'self', 2,
     NULL, 'Digs deep and recovers.', 'second_wind', '{}'::TEXT[], 'balanced', TRUE),

-- ── Musician (P: debuff_atk, heal) ────────────────────────────────────────────
  ('musician_on_summon_moshpit', 'Mosh Pit', 'musician', 'on_summon', 'aoe_damage', 'all_enemies', 1,
     NULL, 'The crowd surges — everyone across the pit takes a hit.', 'crowd_control_aoe', '{}'::TEXT[], 'balanced', TRUE),
  ('musician_activated_ballad', 'Ballad', 'musician', 'activated', 'heal', 'ally_target', 2,
     NULL, 'A slow number that brings an ally back.', 'second_wind', '{}'::TEXT[], 'balanced', TRUE),

-- ── Artist (P: buff_hp, buff_atk_hp) ──────────────────────────────────────────
  ('artist_on_summon_masterpiece', 'Masterpiece', 'artist', 'on_summon', 'buff_atk_hp', 'ally_target', 1,
     NULL, 'Elevates one ally into a work of art.', NULL, '{}'::TEXT[], 'balanced', TRUE),
  ('artist_triggered_muse', 'Muse', 'artist', 'triggered', 'draw_card', 'self', 1,
     'start_of_turn', 'Inspiration each turn — draw a card.', 'steady_draw', '{}'::TEXT[], 'balanced', FALSE),

-- ── Scientist (P: removal, debuff_atk) ────────────────────────────────────────
  ('scientist_on_summon_experiment', 'Experiment', 'scientist', 'on_summon', 'debuff_hp', 'enemy_target', 2,
     NULL, 'A risky trial that weakens a target.', NULL, '{}'::TEXT[], 'balanced', TRUE),
  ('scientist_activated_formula', 'Formula', 'scientist', 'activated', 'shield_grant', 'ally_target', 2,
     NULL, 'A protective compound shields an ally.', 'aegis', '{}'::TEXT[], 'defensive', TRUE),

-- ── Comedian (P: disrupt_discard, debuff_atk) ─────────────────────────────────
  ('comedian_on_summon_punchline', 'Punchline', 'comedian', 'on_summon', 'aoe_damage', 'all_enemies', 1,
     NULL, 'The joke lands on the whole room.', 'crowd_control_aoe', '{}'::TEXT[], 'balanced', TRUE),
  ('comedian_activated_roast', 'Roast', 'comedian', 'activated', 'debuff_atk', 'enemy_target', 2,
     NULL, 'Cuts a target down to size.', NULL, '{}'::TEXT[], 'balanced', TRUE),

-- ── Influencer (P: draw_card) ─────────────────────────────────────────────────
  ('influencer_on_summon_trending', 'Trending', 'influencer', 'on_summon', 'buff_hp', 'all_allies', 1,
     NULL, 'The whole squad rides the wave — allies gain HP.', NULL, '{}'::TEXT[], 'balanced', TRUE),
  ('influencer_activated_clapback', 'Clapback', 'influencer', 'activated', 'disrupt_discard', 'enemy_target', 1,
     NULL, 'A perfectly-timed reply makes the opponent discard.', NULL, '{}'::TEXT[], 'balanced', FALSE),

-- ── Politician (P: buff_atk, taunt_grant) ─────────────────────────────────────
  ('politician_on_summon_takethehit', 'Take the Hit', 'politician', 'on_summon', 'taunt_grant', 'ally_target', 1,
     NULL, 'Puts an ally out front to draw enemy fire.', 'bodyguard', '{}'::TEXT[], 'defensive', FALSE),
  ('politician_activated_filibuster', 'Filibuster', 'politician', 'activated', 'aura_refund', 'self', 1,
     NULL, 'Stalls for time and refunds Aura.', NULL, '{}'::TEXT[], 'balanced', FALSE),

-- ── Business (P: aura_refund) ─────────────────────────────────────────────────
  ('business_on_summon_investment', 'Investment', 'business', 'on_summon', 'buff_hp', 'self', 2,
     NULL, 'Puts capital into its own resilience.', NULL, '{}'::TEXT[], 'defensive', TRUE),
  ('business_activated_acquisition', 'Acquisition', 'business', 'activated', 'draw_card', 'self', 1,
     NULL, 'Buys up options — draw a card.', 'steady_draw', '{}'::TEXT[], 'balanced', FALSE),

-- ── Gamer (P: direct_damage) ──────────────────────────────────────────────────
  ('gamer_on_summon_multikill', 'Multi-Kill', 'gamer', 'on_summon', 'aoe_damage', 'all_enemies', 1,
     NULL, 'A spray that tags the whole enemy line.', 'crowd_control_aoe', '{}'::TEXT[], 'aggressive', TRUE),
  ('gamer_activated_grind', 'Grind', 'gamer', 'activated', 'draw_card', 'self', 1,
     NULL, 'Grinds out card advantage.', 'steady_draw', '{}'::TEXT[], 'balanced', FALSE),

-- ── Actor (P: shield_grant) ───────────────────────────────────────────────────
  ('actor_on_summon_stuntdouble', 'Stunt Double', 'actor', 'on_summon', 'taunt_grant', 'ally_target', 1,
     NULL, 'Steps in so an ally takes the hits.', 'bodyguard', '{}'::TEXT[], 'defensive', FALSE),
  ('actor_triggered_recovery', 'Recovery Scene', 'actor', 'triggered', 'heal', 'self', 2,
     'start_of_turn', 'Recovers a little at the top of each turn.', 'second_wind', '{}'::TEXT[], 'balanced', TRUE);

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: every family now has exactly 3 active non-fusion templates; every
-- 'triggered' template carries a trigger_condition (else it never fires — mig 128).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE r RECORD; v_bad INT;
BEGIN
  FOR r IN
    SELECT archetype_family, COUNT(*) AS n
    FROM public.effect_templates
    WHERE is_active AND is_fusion = FALSE
    GROUP BY archetype_family
  LOOP
    IF r.n <> 3 THEN
      RAISE EXCEPTION 'SMOKE FAIL: family % has % single-card templates (expected 3)', r.archetype_family, r.n;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_bad FROM public.effect_templates
  WHERE is_active AND is_fusion = FALSE AND timing_type = 'triggered' AND trigger_condition IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % triggered template(s) missing trigger_condition', v_bad;
  END IF;

  RAISE NOTICE 'effect-library Wave 1 seed OK: 10 families × 3, triggers well-formed';
END $$;
