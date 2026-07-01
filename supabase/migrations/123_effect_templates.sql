-- Migration 123: effect templates (Phase 2 — P2.2).
--
-- A finite, balanceable effect library keyed by (archetype_family × timing_type),
-- parameterized by the tier's effect_power. A chit references a template; its concrete
-- magnitude = template.base_magnitude × tier.effect_power (computed by the derivation
-- function in mig 125). Fusion effect templates (is_fusion) are family/timing-agnostic.
--
-- Vocabulary enumerated here (families / timing types / keywords are the canonical sets;
-- P3 engine resolves them):
--   timing_type : on_summon | activated | triggered | counter
--   keywords    : taunt | charge | shield | stealth   (persistent, on the chit itself)
--   families    : athlete musician artist scientist comedian influencer politician
--                 business gamer actor
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 2.2.

CREATE TABLE public.effect_templates (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key               TEXT NOT NULL UNIQUE,          -- stable human key
  name              TEXT NOT NULL,
  is_fusion         BOOLEAN NOT NULL DEFAULT FALSE, -- fusion templates are family/timing-agnostic

  archetype_family  TEXT CHECK (archetype_family IN (
    'athlete','musician','artist','scientist','comedian',
    'influencer','politician','business','gamer','actor'
  )),
  timing_type       TEXT CHECK (timing_type IN ('on_summon','activated','triggered','counter')),

  effect_kind       TEXT NOT NULL CHECK (effect_kind IN (
    'direct_damage','aoe_damage','buff_atk','buff_hp','buff_atk_hp',
    'debuff_atk','debuff_hp','heal','shield_grant','taunt_grant',
    'draw_card','removal','disrupt_discard','aura_refund','summon_token'
  )),
  target            TEXT NOT NULL CHECK (target IN (
    'self','ally_target','all_allies','enemy_target','all_enemies','enemy_face','random_enemy'
  )),

  -- Magnitude at effect_power = 1. Concrete magnitude = round(base_magnitude * tier.effect_power).
  base_magnitude    NUMERIC NOT NULL DEFAULT 1 CHECK (base_magnitude >= 0),

  -- For triggered effects (nullable otherwise).
  trigger_condition TEXT CHECK (trigger_condition IN (
    'when_attacked','start_of_turn','end_of_turn','on_ally_ko','on_summon','on_death'
  )),

  description       TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Non-fusion templates are keyed by family × timing; fusion templates need neither.
  CONSTRAINT effect_template_shape CHECK (
    (is_fusion = FALSE AND archetype_family IS NOT NULL AND timing_type IS NOT NULL) OR
    (is_fusion = TRUE)
  )
);

CREATE INDEX effect_templates_family_idx ON public.effect_templates (archetype_family, timing_type)
  WHERE is_fusion = FALSE;
CREATE INDEX effect_templates_fusion_idx ON public.effect_templates (is_fusion) WHERE is_fusion = TRUE;

-- ── starter library: one signature effect per family (the family flavor of §1) ──
-- (Expandable — P7 adds more; magnitudes scale with tier effect_power at derivation.)
INSERT INTO public.effect_templates
  (key, name, archetype_family, timing_type, effect_kind, target, base_magnitude, trigger_condition, description) VALUES
  ('athlete_on_summon_rush',    'Adrenaline Rush',   'athlete',    'on_summon', 'buff_atk',       'self',        2, NULL,
     'Aggressive body: gains ATK on summon.'),
  ('musician_on_summon_encore', 'Encore',            'musician',   'on_summon', 'debuff_atk',     'all_enemies', 1, NULL,
     'AoE debuff: lowers all enemy creatures'' ATK.'),
  ('artist_on_summon_inspire',  'Inspire',           'artist',     'on_summon', 'buff_hp',        'all_allies',  1, NULL,
     'Rallies allies with extra HP.'),
  ('scientist_activated_purge', 'Purge',             'scientist',  'activated', 'removal',        'enemy_target',1, NULL,
     'Control/removal: destroy a target enemy creature (pay Aura).'),
  ('comedian_on_summon_heckle', 'Heckle',            'comedian',   'on_summon', 'disrupt_discard','enemy_target',1, NULL,
     'Disruption: opponent discards a card.'),
  ('influencer_on_summon_viral','Go Viral',          'influencer', 'on_summon', 'draw_card',      'self',        1, NULL,
     'Card advantage: draw on summon.'),
  ('politician_trig_rally',     'Rally',             'politician', 'triggered', 'buff_atk',       'all_allies',  1, 'start_of_turn',
     'Start of turn: buff allied ATK.'),
  ('business_on_summon_dividend','Dividend',         'business',   'on_summon', 'aura_refund',    'self',        1, NULL,
     'Economy: refund some Aura on summon.'),
  ('gamer_activated_snipe',     'Snipe',             'gamer',      'activated', 'direct_damage',  'enemy_target',2, NULL,
     'Precision: deal direct damage to a target (pay Aura).'),
  ('actor_counter_understudy',  'Understudy',        'actor',      'counter',   'shield_grant',   'self',        1, 'when_attacked',
     'Reactive: gains a shield when attacked.');

-- ── RLS: public-read reference; no client writes ────────────────────────────────
ALTER TABLE public.effect_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "effect_templates_public_read" ON public.effect_templates
  FOR SELECT USING (is_active);
