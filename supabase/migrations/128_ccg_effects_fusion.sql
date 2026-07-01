-- Migration 128: CCG effects, triggers, fusion, start-of-turn (Phase 3 — P3.2/3.3/3.5/3.6).
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 3.

-- ── damage a creature (shield absorb → HP → KO) ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_damage_creature(p_card_id UUID, p_amount INTEGER, p_turn INTEGER)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_c public.ccg_match_cards%ROWTYPE; v_absorb INTEGER; v_rem INTEGER;
BEGIN
  SELECT * INTO v_c FROM public.ccg_match_cards WHERE id = p_card_id;
  IF NOT FOUND OR v_c.zone <> 'field' OR p_amount <= 0 THEN RETURN; END IF;

  v_absorb := LEAST(v_c.shield, p_amount);
  v_rem    := p_amount - v_absorb;
  UPDATE public.ccg_match_cards
  SET shield = shield - v_absorb, cur_hp = cur_hp - v_rem
  WHERE id = p_card_id;

  IF (SELECT cur_hp FROM public.ccg_match_cards WHERE id = p_card_id) <= 0 THEN
    PERFORM public.ccg_kill_card(p_card_id, p_turn);
  END IF;
END;
$$;

-- ── apply a resolved effect (kind × target × magnitude) ─────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_apply_effect(
  p_match_id       UUID,
  p_source_card_id UUID,
  p_kind           TEXT,
  p_target         TEXT,
  p_magnitude      INTEGER,
  p_turn           INTEGER,
  p_target_card_id UUID DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src   public.ccg_match_cards%ROWTYPE;
  v_seat  SMALLINT;
  v_foe   SMALLINT;
  v_mag   INTEGER := GREATEST(COALESCE(p_magnitude,0),0);
  v_ids   UUID[];
  v_id    UUID;
BEGIN
  SELECT * INTO v_src FROM public.ccg_match_cards WHERE id = p_source_card_id;
  v_seat := v_src.owner_seat;
  v_foe  := public.ccg_other_seat(v_seat);

  -- Resolve the target card set (face handled inline).
  v_ids := CASE p_target
    WHEN 'self'         THEN ARRAY[p_source_card_id]
    WHEN 'ally_target'  THEN ARRAY[p_target_card_id]
    WHEN 'enemy_target' THEN ARRAY[p_target_card_id]
    WHEN 'all_allies'   THEN ARRAY(SELECT id FROM public.ccg_match_cards
                                    WHERE match_id=p_match_id AND zone='field' AND owner_seat=v_seat)
    WHEN 'all_enemies'  THEN ARRAY(SELECT id FROM public.ccg_match_cards
                                    WHERE match_id=p_match_id AND zone='field' AND owner_seat=v_foe)
    WHEN 'random_enemy' THEN ARRAY(SELECT id FROM public.ccg_match_cards
                                    WHERE match_id=p_match_id AND zone='field' AND owner_seat=v_foe
                                    ORDER BY random() LIMIT 1)
    ELSE ARRAY[]::UUID[]
  END;

  CASE p_kind
    WHEN 'direct_damage', 'aoe_damage' THEN
      IF p_target = 'enemy_face' THEN
        UPDATE public.ccg_match_players SET life = life - v_mag
        WHERE match_id=p_match_id AND seat=v_foe;
      ELSE
        FOREACH v_id IN ARRAY v_ids LOOP PERFORM public.ccg_damage_creature(v_id, v_mag, p_turn); END LOOP;
      END IF;

    WHEN 'buff_atk' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET cur_atk = cur_atk + v_mag WHERE id=v_id; END LOOP;
    WHEN 'buff_hp' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET cur_hp = cur_hp + v_mag WHERE id=v_id; END LOOP;
    WHEN 'buff_atk_hp' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET cur_atk = cur_atk + v_mag, cur_hp = cur_hp + v_mag WHERE id=v_id; END LOOP;
    WHEN 'debuff_atk' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET cur_atk = GREATEST(cur_atk - v_mag,0) WHERE id=v_id; END LOOP;
    WHEN 'debuff_hp' THEN
      FOREACH v_id IN ARRAY v_ids LOOP PERFORM public.ccg_damage_creature(v_id, v_mag, p_turn); END LOOP;
    WHEN 'heal' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET cur_hp = LEAST(cur_hp + v_mag, snap_hp) WHERE id=v_id AND snap_hp IS NOT NULL; END LOOP;
    WHEN 'shield_grant' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards SET shield = shield + v_mag WHERE id=v_id; END LOOP;
    WHEN 'taunt_grant' THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        UPDATE public.ccg_match_cards
        SET snap_keywords = (SELECT ARRAY(SELECT DISTINCT unnest(snap_keywords || ARRAY['taunt'])))
        WHERE id=v_id; END LOOP;
    WHEN 'removal' THEN
      FOREACH v_id IN ARRAY v_ids LOOP PERFORM public.ccg_kill_card(v_id, p_turn); END LOOP;
    WHEN 'heal_face' THEN
      UPDATE public.ccg_match_players SET life = life + v_mag WHERE match_id=p_match_id AND seat=v_seat;
    WHEN 'draw_card' THEN
      FOR v_id IN SELECT g FROM generate_series(1, GREATEST(v_mag,1)) g LOOP
        PERFORM public.ccg_draw_card(p_match_id, v_seat, p_turn); END LOOP;
    WHEN 'disrupt_discard' THEN
      FOR v_id IN (SELECT id FROM public.ccg_match_cards
                   WHERE match_id=p_match_id AND owner_seat=v_foe AND zone='hand'
                   ORDER BY random() LIMIT GREATEST(v_mag,1)) LOOP
        UPDATE public.ccg_match_cards SET zone='graveyard' WHERE id=v_id; END LOOP;
    WHEN 'aura_refund' THEN
      UPDATE public.ccg_match_players
      SET aura = LEAST(aura + v_mag, 10) WHERE match_id=p_match_id AND seat=v_seat;
    WHEN 'summon_token' THEN
      NULL;  -- token generation deferred (needs token chit defs); emitted as effect only
    ELSE
      NULL;
  END CASE;

  PERFORM public.ccg_emit_event(p_match_id, p_turn, 'effect', v_seat, jsonb_build_object(
    'source_card_id', p_source_card_id, 'kind', p_kind, 'target', p_target,
    'magnitude', v_mag, 'target_card_id', p_target_card_id));
END;
$$;

-- ── apply a card's own snap effect ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_apply_card_effect(p_card_id UUID, p_turn INTEGER, p_target_card_id UUID DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_c public.ccg_match_cards%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM public.ccg_match_cards WHERE id = p_card_id;
  IF v_c.snap_effect_kind IS NULL THEN RETURN; END IF;
  PERFORM public.ccg_apply_effect(v_c.match_id, p_card_id, v_c.snap_effect_kind,
    COALESCE(v_c.snap_effect_target,'self'), v_c.snap_effect_magnitude, p_turn, p_target_card_id);
END;
$$;

-- ── fire timed triggers for a seat (start_of_turn / end_of_turn) ─────────────────
CREATE OR REPLACE FUNCTION public.ccg_fire_timed_triggers(p_match_id UUID, p_seat SMALLINT, p_condition TEXT, p_turn INTEGER)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  FOR v_id IN
    SELECT id FROM public.ccg_match_cards
    WHERE match_id=p_match_id AND owner_seat=p_seat AND zone='field'
      AND snap_timing='triggered' AND snap_trigger_condition=p_condition
      AND snap_effect_kind IS NOT NULL
    ORDER BY field_pos
  LOOP
    PERFORM public.ccg_apply_card_effect(v_id, p_turn);
  END LOOP;
END;
$$;

-- ── fusion detection + resolution over this-turn summons ─────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_resolve_fusions(p_match_id UUID, p_seat SMALLINT, p_turn INTEGER)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rule   public.fusion_rules%ROWTYPE;
  v_tmpl   public.effect_templates%ROWTYPE;
  v_count  INTEGER;
  v_scale  NUMERIC;
  v_mag    INTEGER;
  v_src    UUID;
  v_tgt    UUID;
BEGIN
  FOR v_rule IN SELECT * FROM public.fusion_rules WHERE is_active LOOP
    -- Matched components: creatures summoned THIS turn on this seat's field matching the pattern.
    SELECT COUNT(*) INTO v_count
    FROM public.ccg_match_cards c
    WHERE c.match_id=p_match_id AND c.owner_seat=p_seat AND c.zone='field'
      AND c.summoned_turn=p_turn AND c.snap_chit_type='creature'
      AND (v_rule.match_family  IS NULL OR c.snap_family = v_rule.match_family)
      AND (v_rule.match_keyword IS NULL OR v_rule.match_keyword = ANY(c.snap_keywords));

    IF v_count < v_rule.min_count THEN CONTINUE; END IF;

    -- Fusion magnitude: template base scaled by components' tier effect_power.
    SELECT * INTO v_tmpl FROM public.effect_templates WHERE id = v_rule.fusion_effect_template_id;
    SELECT CASE v_rule.power_scaling
             WHEN 'sum' THEN SUM(tl.effect_power)
             WHEN 'max' THEN MAX(tl.effect_power)
             ELSE AVG(tl.effect_power)
           END
      INTO v_scale
    FROM public.ccg_match_cards c
    JOIN public.tier_ladder tl ON tl.tier = c.snap_tier
    WHERE c.match_id=p_match_id AND c.owner_seat=p_seat AND c.zone='field'
      AND c.summoned_turn=p_turn AND c.snap_chit_type='creature'
      AND (v_rule.match_family  IS NULL OR c.snap_family = v_rule.match_family)
      AND (v_rule.match_keyword IS NULL OR v_rule.match_keyword = ANY(c.snap_keywords));

    v_mag := ROUND(v_tmpl.base_magnitude * COALESCE(v_scale,1))::INTEGER;

    -- Source = a matched component (for side determination); target per template.
    SELECT id INTO v_src FROM public.ccg_match_cards c
    WHERE c.match_id=p_match_id AND c.owner_seat=p_seat AND c.zone='field' AND c.summoned_turn=p_turn
    LIMIT 1;

    IF v_tmpl.target = 'enemy_target' THEN
      SELECT id INTO v_tgt FROM public.ccg_match_cards
      WHERE match_id=p_match_id AND owner_seat=public.ccg_other_seat(p_seat) AND zone='field'
      ORDER BY field_pos LIMIT 1;
    END IF;

    PERFORM public.ccg_emit_event(p_match_id, p_turn, 'fusion', p_seat, jsonb_build_object(
      'rule', v_rule.key, 'components', v_count, 'magnitude', v_mag, 'template', v_tmpl.key));
    PERFORM public.ccg_apply_effect(p_match_id, v_src, v_tmpl.effect_kind, v_tmpl.target, v_mag, p_turn, v_tgt);
  END LOOP;
END;
$$;

-- ── begin a turn for the active seat (ramp, refill, unsick, draw, triggers) ──────
CREATE OR REPLACE FUNCTION public.ccg_begin_turn(p_match_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_seat SMALLINT; v_turn INTEGER; v_newmax INTEGER;
BEGIN
  SELECT active_seat, turn_number INTO v_seat, v_turn FROM public.ccg_matches WHERE id=p_match_id;

  UPDATE public.ccg_match_players
  SET max_aura = LEAST(max_aura + 1, 10)
  WHERE match_id=p_match_id AND seat=v_seat
  RETURNING max_aura INTO v_newmax;

  UPDATE public.ccg_match_players SET aura = v_newmax
  WHERE match_id=p_match_id AND seat=v_seat;

  -- This seat's creatures can now act.
  UPDATE public.ccg_match_cards
  SET is_summoning_sick = FALSE, has_attacked = FALSE
  WHERE match_id=p_match_id AND owner_seat=v_seat AND zone='field';

  PERFORM public.ccg_emit_event(p_match_id, v_turn, 'turn_start', v_seat,
    jsonb_build_object('max_aura', v_newmax));

  PERFORM public.ccg_fire_timed_triggers(p_match_id, v_seat, 'start_of_turn', v_turn);
  PERFORM public.ccg_draw_card(p_match_id, v_seat, v_turn);
  PERFORM public.ccg_check_win(p_match_id, v_turn);   -- fatigue may end the game
END;
$$;
