-- Migration 148: card-face display fields — rules_text, flavor_text, card_serial.
--
-- Populates the three optional CardFace slots (flutter_app .../core/widgets/card_face.dart)
-- that the mint-preview + /collection screens already render but nothing was filling.
--
--   rules_text  — the printed ability line, COMPOSED DETERMINISTICALLY from the chit's
--                 own effect fields (timing + effect template kind/target + magnitude +
--                 keywords + vibe gate). Never authored, never AI, never user-set, so the
--                 printed rules ALWAYS match the mechanics the resolver runs (the same
--                 snap_* fields ccg_apply_effect reads). Recomputed on every write, so
--                 tier ascension (mig 136 re-derives effect_magnitude) reprints correctly.
--   flavor_text — a short evocative line. Deterministic sim default here; live minting may
--                 overwrite with an AI line (the trigger only fills it when NULL).
--   card_serial — a stable collectible serial 'NORA-####' from a dedicated sequence,
--                 assigned once at first write and never reissued.
--
-- Enforcement note (Hard Rule 34): these are cosmetic/derived. rules_text is a projection
-- of already-server-set power, so exposing it does not let users set power. Writes still go
-- only through the SECURITY DEFINER mint/ascension/seed paths; this trigger runs inside them.

-- ── columns ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS rules_text  TEXT,
  ADD COLUMN IF NOT EXISTS flavor_text TEXT,
  ADD COLUMN IF NOT EXISTS card_serial TEXT;

-- Serial is a stable identity once assigned; unique across the catalog.
CREATE SEQUENCE IF NOT EXISTS public.moment_chit_serial_seq;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'moment_chits_card_serial_key'
  ) THEN
    ALTER TABLE public.moment_chits
      ADD CONSTRAINT moment_chits_card_serial_key UNIQUE (card_serial);
  END IF;
END $$;

-- ── compose_chit_rules: effect fields → printed ability line ─────────────────────
-- Pure text projection of the mechanics. p_kind/p_target/p_trigger come from the
-- attached effect_templates row (NULL for a vanilla creature).
CREATE OR REPLACE FUNCTION public.compose_chit_rules(
  p_chit_type  TEXT,
  p_timing     TEXT,
  p_kind       TEXT,
  p_target     TEXT,
  p_magnitude  INTEGER,
  p_trigger    TEXT,
  p_keywords   TEXT[],
  p_vibe_gate  INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_mag    INTEGER := GREATEST(COALESCE(p_magnitude, 0), 0);
  v_effect TEXT;
  v_target TEXT;
  v_prefix TEXT;
  v_needs_target BOOLEAN := TRUE;
  v_lines  TEXT[] := ARRAY[]::TEXT[];
  v_kw     TEXT;
  v_out    TEXT;
BEGIN
  -- Keyword sentences first (mechanical, capitalized). CardFace also shows icons.
  FOREACH v_kw IN ARRAY COALESCE(p_keywords, '{}'::TEXT[]) LOOP
    v_lines := v_lines || (initcap(v_kw) || '.');
  END LOOP;

  IF p_kind IS NOT NULL THEN
    -- Effect verb phrase.
    v_effect := CASE p_kind
      WHEN 'direct_damage'   THEN 'Deal ' || v_mag || ' damage to'
      WHEN 'aoe_damage'      THEN 'Deal ' || v_mag || ' damage to'
      WHEN 'debuff_hp'       THEN 'Deal ' || v_mag || ' damage to'
      WHEN 'buff_atk'        THEN 'Give +' || v_mag || ' ATK to'
      WHEN 'buff_hp'         THEN 'Give +' || v_mag || ' HP to'
      WHEN 'buff_atk_hp'     THEN 'Give +' || v_mag || '/+' || v_mag || ' to'
      WHEN 'debuff_atk'      THEN 'Reduce ATK by ' || v_mag || ' on'
      WHEN 'heal'            THEN 'Restore ' || v_mag || ' HP to'
      WHEN 'shield_grant'    THEN 'Grant a ' || v_mag || '-point shield to'
      WHEN 'taunt_grant'     THEN 'Grant Taunt to'
      WHEN 'removal'         THEN 'Destroy'
      WHEN 'heal_face'       THEN 'Restore ' || v_mag || ' Life to your hero'
      WHEN 'draw_card'       THEN 'Draw ' || GREATEST(v_mag, 1) || ' card' ||
                                   CASE WHEN GREATEST(v_mag, 1) = 1 THEN '' ELSE 's' END
      WHEN 'disrupt_discard' THEN 'Force the enemy to discard ' || GREATEST(v_mag, 1) || ' card' ||
                                   CASE WHEN GREATEST(v_mag, 1) = 1 THEN '' ELSE 's' END
      WHEN 'aura_refund'     THEN 'Refund ' || v_mag || ' Aura'
      WHEN 'summon_token'    THEN 'Summon a token'
      ELSE NULL
    END;

    -- Which kinds address a target creature/hero vs. resolve on their own.
    v_needs_target := p_kind NOT IN
      ('heal_face', 'draw_card', 'disrupt_discard', 'aura_refund', 'summon_token');

    IF v_needs_target THEN
      v_target := CASE p_target
        WHEN 'self'         THEN 'this creature'
        WHEN 'ally_target'  THEN 'a friendly creature'
        WHEN 'all_allies'   THEN 'all your creatures'
        WHEN 'enemy_target' THEN 'an enemy creature'
        WHEN 'all_enemies'  THEN 'all enemy creatures'
        WHEN 'enemy_face'   THEN 'the enemy hero'
        WHEN 'random_enemy' THEN 'a random enemy creature'
        ELSE NULL
      END;
    END IF;

    -- Timing prefix (triggered uses its condition).
    v_prefix := CASE p_timing
      WHEN 'on_summon' THEN 'Battlecry: '
      WHEN 'activated' THEN 'Activate: '
      WHEN 'counter'   THEN 'Counter: '
      WHEN 'triggered' THEN CASE p_trigger
        WHEN 'when_attacked' THEN 'When attacked, '
        WHEN 'start_of_turn' THEN 'At the start of your turn, '
        WHEN 'end_of_turn'   THEN 'At the end of your turn, '
        WHEN 'on_ally_ko'    THEN 'When a friendly creature is destroyed, '
        WHEN 'on_death'      THEN 'When this is destroyed, '
        WHEN 'on_summon'     THEN 'When summoned, '
        ELSE ''
      END
      ELSE ''
    END;

    IF v_effect IS NOT NULL THEN
      -- Lowercase the verb for mid-sentence triggered prefixes.
      IF v_prefix <> '' AND right(v_prefix, 1) IN (' ') AND v_prefix NOT LIKE '%: ' THEN
        v_effect := lower(left(v_effect, 1)) || substr(v_effect, 2);
      END IF;
      v_out := v_prefix || v_effect ||
               CASE WHEN v_needs_target AND v_target IS NOT NULL THEN ' ' || v_target ELSE '' END ||
               '.';
      v_lines := v_lines || v_out;
    END IF;
  END IF;

  IF p_vibe_gate IS NOT NULL THEN
    v_lines := v_lines || ('Requires ' || p_vibe_gate || ' Vibe to play.');
  END IF;

  IF array_length(v_lines, 1) IS NULL THEN
    -- Vanilla creature with no effect/keywords/gate: no printed rules (flavor carries it).
    RETURN NULL;
  END IF;
  RETURN array_to_string(v_lines, ' ');
END;
$$;

-- ── compose_chit_flavor: deterministic sim flavor line ──────────────────────────
CREATE OR REPLACE FUNCTION public.compose_chit_flavor(
  p_family   TEXT,
  p_handle   TEXT,
  p_platform TEXT
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_line TEXT;
  v_src  TEXT;
BEGIN
  v_line := CASE p_family
    WHEN 'athlete'    THEN 'The moment the whole arena rose to its feet.'
    WHEN 'musician'   THEN 'One take. No autotune. Pure chills.'
    WHEN 'artist'     THEN 'Where a blank canvas met the algorithm.'
    WHEN 'scientist'  THEN 'The experiment that broke containment — of the feed.'
    WHEN 'comedian'   THEN 'You had to be there. Now you can be.'
    WHEN 'influencer' THEN 'The post that ate the timeline whole.'
    WHEN 'politician' THEN 'The soundbite that would not die.'
    WHEN 'business'   THEN 'The pitch that closed the whole room.'
    WHEN 'gamer'      THEN 'Clutched with the whole lobby watching.'
    WHEN 'actor'      THEN 'One line. Take after take, unforgettable.'
    ELSE 'A viral moment, crystallized into a BattleChit.'
  END;

  IF p_handle IS NOT NULL AND btrim(p_handle) <> '' THEN
    v_src := btrim(p_handle);
    IF p_platform IS NOT NULL AND btrim(p_platform) <> '' THEN
      v_src := v_src || ' on ' || initcap(p_platform);
    END IF;
    v_line := v_line || ' — ' || v_src;
  END IF;
  RETURN v_line;
END;
$$;

-- ── trigger: keep display fields correct on every server-side write ──────────────
-- rules_text is ALWAYS recomputed (so ascension reprints); flavor_text only filled when
-- NULL (an AI line survives); card_serial assigned once and never changed.
CREATE OR REPLACE FUNCTION public.moment_chit_fill_display()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_kind    TEXT;
  v_target  TEXT;
  v_trigger TEXT;
BEGIN
  IF NEW.effect_ref IS NOT NULL THEN
    SELECT effect_kind, target, trigger_condition
      INTO v_kind, v_target, v_trigger
    FROM public.effect_templates WHERE id = NEW.effect_ref;
  END IF;

  NEW.rules_text := public.compose_chit_rules(
    NEW.chit_type, NEW.timing_type, v_kind, v_target,
    NEW.effect_magnitude, v_trigger, NEW.keywords, NEW.vibe_gate);

  IF NEW.flavor_text IS NULL OR btrim(NEW.flavor_text) = '' THEN
    NEW.flavor_text := public.compose_chit_flavor(
      NEW.archetype_family, NEW.original_minter_handle, NEW.source_platform);
  END IF;

  IF NEW.card_serial IS NULL THEN
    NEW.card_serial := 'NORA-' || lpad(nextval('public.moment_chit_serial_seq')::TEXT, 4, '0');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS moment_chits_fill_display ON public.moment_chits;
CREATE TRIGGER moment_chits_fill_display
  BEFORE INSERT OR UPDATE ON public.moment_chits
  FOR EACH ROW EXECUTE FUNCTION public.moment_chit_fill_display();

-- ── backfill existing rows (fires the trigger for each) ─────────────────────────
UPDATE public.moment_chits SET updated_at = updated_at;

-- ── apply-time smoke: every row now has a serial + (composed) rules where expected ─
DO $$
DECLARE v_missing INTEGER; v_bad_serial INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_bad_serial FROM public.moment_chits WHERE card_serial IS NULL;
  IF v_bad_serial > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % chit(s) missing card_serial after backfill', v_bad_serial;
  END IF;
  -- Seed chits carry effects, so they must all have printed rules.
  SELECT COUNT(*) INTO v_missing
  FROM public.moment_chits WHERE effect_ref IS NOT NULL AND rules_text IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: % effect-bearing chit(s) have no rules_text', v_missing;
  END IF;
END $$;
