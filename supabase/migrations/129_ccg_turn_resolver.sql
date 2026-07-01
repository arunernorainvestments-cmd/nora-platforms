-- Migration 129: CCG match creation + turn resolver + apply-time smoke (Phase 3 — P3.1/3.3/3.4/3.7).
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 3.

-- ── instantiate a card into a match (copies the match-start snapshot; Hard Rule 36) ─
CREATE OR REPLACE FUNCTION public.ccg_instantiate_card(
  p_match_id UUID, p_seat SMALLINT, p_chit_id UUID, p_zone TEXT, p_deck_order INTEGER
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.ccg_match_cards (
    match_id, owner_seat, chit_id, zone, deck_order,
    snap_chit_type, snap_family, snap_tier, snap_aura_cost, snap_atk, snap_hp, snap_keywords,
    snap_timing, snap_vibe_gate, snap_effect_kind, snap_effect_target, snap_effect_magnitude,
    snap_trigger_condition, cur_atk, cur_hp, is_summoning_sick)
  SELECT p_match_id, p_seat, mc.id, p_zone, p_deck_order,
    mc.chit_type, mc.archetype_family, mc.tier, mc.aura_cost, mc.atk, mc.hp, mc.keywords,
    mc.timing_type, mc.vibe_gate, et.effect_kind, et.target, mc.effect_magnitude,
    et.trigger_condition, mc.atk, mc.hp, TRUE
  FROM public.moment_chits mc
  LEFT JOIN public.effect_templates et ON et.id = mc.effect_ref
  WHERE mc.id = p_chit_id
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── create a match: snapshot both decks, deal opening hands, begin turn 1 ────────
CREATE OR REPLACE FUNCTION public.ccg_create_match(
  p_seat1_user UUID, p_seat1_deck UUID,
  p_seat2_user UUID, p_seat2_deck UUID,
  p_is_test BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match UUID; v_seat SMALLINT; v_deck UUID; v_user UUID; v_ord INTEGER; v_row RECORD;
BEGIN
  IF NOT p_is_test THEN
    IF NOT public.deck_is_legal(p_seat1_deck, p_seat1_user)
       OR NOT public.deck_is_legal(p_seat2_deck, p_seat2_user) THEN
      RAISE EXCEPTION 'Both players need a legal deck to start a match';
    END IF;
  END IF;

  INSERT INTO public.ccg_matches (is_test) VALUES (p_is_test) RETURNING id INTO v_match;

  FOR v_seat IN 1..2 LOOP
    v_deck := CASE v_seat WHEN 1 THEN p_seat1_deck ELSE p_seat2_deck END;
    v_user := CASE v_seat WHEN 1 THEN p_seat1_user ELSE p_seat2_user END;
    INSERT INTO public.ccg_match_players (match_id, seat, user_id, deck_id)
    VALUES (v_match, v_seat, v_user, v_deck);

    IF v_deck IS NOT NULL THEN
      v_ord := 0;
      -- expand deck_chits × quantity, shuffled
      FOR v_row IN
        SELECT dc.chit_id
        FROM public.deck_chits dc, generate_series(1, dc.quantity)
        WHERE dc.deck_id = v_deck
        ORDER BY random()
      LOOP
        v_ord := v_ord + 1;
        PERFORM public.ccg_instantiate_card(v_match, v_seat, v_row.chit_id, 'deck', v_ord);
      END LOOP;

      -- opening hand: 3 lowest deck_order cards
      UPDATE public.ccg_match_cards SET zone = 'hand'
      WHERE id IN (
        SELECT id FROM public.ccg_match_cards
        WHERE match_id = v_match AND owner_seat = v_seat AND zone = 'deck'
        ORDER BY deck_order LIMIT 3);
    END IF;
  END LOOP;

  PERFORM public.ccg_emit_event(v_match, 1, 'match_start', 1, jsonb_build_object('is_test', p_is_test));
  PERFORM public.ccg_begin_turn(v_match);
  RETURN v_match;
END;
$$;

-- ── the turn resolver: validate + resolve an ordered action list, then advance ──
-- p_actions: [{type:'summon',card_id,position} | {type:'cast',card_id,target_card_id?}
--             | {type:'activate',card_id,target_card_id?} | {type:'attack',attacker_card_id,target_card_id?}
--             | {type:'end'}]
CREATE OR REPLACE FUNCTION public.ccg_submit_turn(p_match_id UUID, p_actions JSONB)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_m      public.ccg_matches%ROWTYPE;
  v_seat   SMALLINT;
  v_turn   INTEGER;
  v_act    JSONB;
  v_type   TEXT;
  v_card   public.ccg_match_cards%ROWTYPE;
  v_def    public.ccg_match_cards%ROWTYPE;
  v_aura   INTEGER;
  v_vibe   INTEGER;
  v_fieldn INTEGER;
  v_tgt    UUID;
BEGIN
  SELECT * INTO v_m FROM public.ccg_matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_m.status <> 'active' THEN RAISE EXCEPTION 'Match not active'; END IF;
  v_turn := v_m.turn_number;

  -- Determine acting seat (test matches: act as the active seat).
  IF v_m.is_test THEN
    v_seat := v_m.active_seat;
  ELSE
    SELECT seat INTO v_seat FROM public.ccg_match_players
    WHERE match_id = p_match_id AND user_id = auth.uid();
    IF v_seat IS NULL THEN RAISE EXCEPTION 'Not a player in this match'; END IF;
    IF v_seat <> v_m.active_seat THEN RAISE EXCEPTION 'Not your turn'; END IF;
  END IF;

  v_vibe := public.ccg_get_match_vibe(p_match_id);

  FOR v_act IN SELECT * FROM jsonb_array_elements(COALESCE(p_actions, '[]'::jsonb)) LOOP
    v_type := v_act->>'type';
    EXIT WHEN v_type = 'end';

    IF v_type = 'summon' THEN
      SELECT * INTO v_card FROM public.ccg_match_cards WHERE id = (v_act->>'card_id')::UUID;
      IF v_card.owner_seat <> v_seat OR v_card.zone <> 'hand' OR v_card.snap_chit_type <> 'creature' THEN
        RAISE EXCEPTION 'Illegal summon'; END IF;
      SELECT COUNT(*) INTO v_fieldn FROM public.ccg_match_cards
        WHERE match_id=p_match_id AND owner_seat=v_seat AND zone='field';
      IF v_fieldn >= 3 THEN RAISE EXCEPTION 'Field is full (cap 3)'; END IF;
      SELECT aura INTO v_aura FROM public.ccg_match_players WHERE match_id=p_match_id AND seat=v_seat;
      IF v_aura < v_card.snap_aura_cost THEN RAISE EXCEPTION 'Not enough Aura'; END IF;
      IF v_card.snap_vibe_gate IS NOT NULL AND v_vibe < v_card.snap_vibe_gate THEN
        RAISE EXCEPTION 'Vibe too low for this chit'; END IF;

      UPDATE public.ccg_match_players SET aura = aura - v_card.snap_aura_cost
        WHERE match_id=p_match_id AND seat=v_seat;
      UPDATE public.ccg_match_cards
        SET zone='field', field_pos=COALESCE((v_act->>'position')::SMALLINT, v_fieldn+1),
            summoned_turn=v_turn, has_attacked=FALSE,
            is_summoning_sick = NOT ('charge' = ANY(v_card.snap_keywords))
        WHERE id=v_card.id;
      PERFORM public.ccg_emit_event(p_match_id, v_turn, 'summon', v_seat,
        jsonb_build_object('card_id', v_card.id, 'chit_id', v_card.chit_id));
      IF v_card.snap_timing = 'on_summon' THEN
        PERFORM public.ccg_apply_card_effect(v_card.id, v_turn, NULLIF(v_act->>'target_card_id','')::UUID);
      END IF;

    ELSIF v_type = 'cast' THEN
      SELECT * INTO v_card FROM public.ccg_match_cards WHERE id = (v_act->>'card_id')::UUID;
      IF v_card.owner_seat <> v_seat OR v_card.zone <> 'hand' OR v_card.snap_chit_type <> 'spell_moment' THEN
        RAISE EXCEPTION 'Illegal cast'; END IF;
      SELECT aura INTO v_aura FROM public.ccg_match_players WHERE match_id=p_match_id AND seat=v_seat;
      IF v_aura < v_card.snap_aura_cost THEN RAISE EXCEPTION 'Not enough Aura'; END IF;
      IF v_card.snap_vibe_gate IS NOT NULL AND v_vibe < v_card.snap_vibe_gate THEN
        RAISE EXCEPTION 'Vibe too low for this chit'; END IF;

      UPDATE public.ccg_match_players SET aura = aura - v_card.snap_aura_cost
        WHERE match_id=p_match_id AND seat=v_seat;
      UPDATE public.ccg_match_cards SET zone='graveyard' WHERE id=v_card.id;
      PERFORM public.ccg_emit_event(p_match_id, v_turn, 'cast', v_seat,
        jsonb_build_object('card_id', v_card.id, 'chit_id', v_card.chit_id));
      PERFORM public.ccg_apply_card_effect(v_card.id, v_turn, NULLIF(v_act->>'target_card_id','')::UUID);

    ELSIF v_type = 'activate' THEN
      SELECT * INTO v_card FROM public.ccg_match_cards WHERE id = (v_act->>'card_id')::UUID;
      IF v_card.owner_seat <> v_seat OR v_card.zone <> 'field' OR v_card.snap_timing <> 'activated' THEN
        RAISE EXCEPTION 'Illegal activate'; END IF;
      SELECT aura INTO v_aura FROM public.ccg_match_players WHERE match_id=p_match_id AND seat=v_seat;
      IF v_aura < 1 THEN RAISE EXCEPTION 'Not enough Aura to activate'; END IF;
      UPDATE public.ccg_match_players SET aura = aura - 1 WHERE match_id=p_match_id AND seat=v_seat;
      PERFORM public.ccg_emit_event(p_match_id, v_turn, 'activate', v_seat,
        jsonb_build_object('card_id', v_card.id));
      PERFORM public.ccg_apply_card_effect(v_card.id, v_turn, NULLIF(v_act->>'target_card_id','')::UUID);

    ELSIF v_type = 'attack' THEN
      SELECT * INTO v_card FROM public.ccg_match_cards WHERE id = (v_act->>'attacker_card_id')::UUID;
      IF v_card.owner_seat <> v_seat OR v_card.zone <> 'field' THEN RAISE EXCEPTION 'Illegal attacker'; END IF;
      IF v_card.is_summoning_sick THEN RAISE EXCEPTION 'Creature is summoning sick'; END IF;
      IF v_card.has_attacked THEN RAISE EXCEPTION 'Creature already attacked'; END IF;
      IF COALESCE(v_card.cur_atk,0) <= 0 THEN RAISE EXCEPTION 'Attacker has no ATK'; END IF;

      v_tgt := NULLIF(v_act->>'target_card_id','')::UUID;

      -- Taunt: if the enemy has any taunt creature, the attack must target a taunt creature.
      IF EXISTS (SELECT 1 FROM public.ccg_match_cards
                 WHERE match_id=p_match_id AND owner_seat=public.ccg_other_seat(v_seat)
                   AND zone='field' AND 'taunt' = ANY(snap_keywords)) THEN
        IF v_tgt IS NULL OR NOT EXISTS (
          SELECT 1 FROM public.ccg_match_cards
          WHERE id=v_tgt AND 'taunt' = ANY(snap_keywords) AND zone='field') THEN
          RAISE EXCEPTION 'Must attack a taunt creature'; END IF;
      END IF;

      IF v_tgt IS NULL THEN
        -- face attack
        UPDATE public.ccg_match_players SET life = life - v_card.cur_atk
          WHERE match_id=p_match_id AND seat=public.ccg_other_seat(v_seat);
        PERFORM public.ccg_emit_event(p_match_id, v_turn, 'attack', v_seat,
          jsonb_build_object('attacker', v_card.id, 'target','face','damage', v_card.cur_atk));
      ELSE
        SELECT * INTO v_def FROM public.ccg_match_cards WHERE id=v_tgt;
        IF v_def.zone <> 'field' OR v_def.owner_seat = v_seat THEN RAISE EXCEPTION 'Illegal target'; END IF;
        -- defender counter (when_attacked) fires before damage
        IF v_def.snap_timing='counter' AND v_def.snap_trigger_condition='when_attacked' THEN
          PERFORM public.ccg_apply_card_effect(v_def.id, v_turn);
          SELECT * INTO v_def FROM public.ccg_match_cards WHERE id=v_tgt;  -- refresh (shield)
        END IF;
        PERFORM public.ccg_emit_event(p_match_id, v_turn, 'attack', v_seat,
          jsonb_build_object('attacker', v_card.id, 'target', v_tgt, 'damage', v_card.cur_atk));
        PERFORM public.ccg_damage_creature(v_tgt, v_card.cur_atk, v_turn);       -- attacker → defender
        PERFORM public.ccg_damage_creature(v_card.id, COALESCE(v_def.cur_atk,0), v_turn); -- defender → attacker
      END IF;

      UPDATE public.ccg_match_cards SET has_attacked=TRUE WHERE id=v_card.id;
      IF public.ccg_check_win(p_match_id, v_turn) THEN
        RETURN jsonb_build_object('status','finished','winner_seat',
          (SELECT winner_seat FROM public.ccg_matches WHERE id=p_match_id)); END IF;

    ELSE
      RAISE EXCEPTION 'Unknown action type: %', v_type;
    END IF;
  END LOOP;

  -- End-of-turn: fusion over this turn's summons, end triggers, win check.
  PERFORM public.ccg_resolve_fusions(p_match_id, v_seat, v_turn);
  PERFORM public.ccg_fire_timed_triggers(p_match_id, v_seat, 'end_of_turn', v_turn);
  PERFORM public.ccg_emit_event(p_match_id, v_turn, 'turn_end', v_seat, '{}');

  IF public.ccg_check_win(p_match_id, v_turn) THEN
    RETURN jsonb_build_object('status','finished','winner_seat',
      (SELECT winner_seat FROM public.ccg_matches WHERE id=p_match_id));
  END IF;

  -- Advance to the other seat's turn.
  UPDATE public.ccg_matches
  SET active_seat = public.ccg_other_seat(v_seat), turn_number = turn_number + 1
  WHERE id = p_match_id;
  PERFORM public.ccg_begin_turn(p_match_id);

  SELECT * INTO v_m FROM public.ccg_matches WHERE id = p_match_id;
  RETURN jsonb_build_object('status', v_m.status, 'active_seat', v_m.active_seat, 'turn', v_m.turn_number);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time engine smoke: a synthetic (is_test) match exercising summon → on_summon
-- effect → fusion detection/resolution → face damage → event stream. Raises if the
-- engine logic is wrong, so a clean push proves the resolver end-to-end.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_match UUID; v_c1 UUID; v_c2 UUID; v_life2 INTEGER; v_fusions INTEGER; v_summons INTEGER;
BEGIN
  INSERT INTO public.ccg_matches (is_test, active_seat, turn_number) VALUES (TRUE, 1, 1)
    RETURNING id INTO v_match;
  INSERT INTO public.ccg_match_players (match_id, seat, life, aura, max_aura) VALUES
    (v_match, 1, 30, 10, 10), (v_match, 2, 30, 0, 0);

  -- Two charging athletes into seat 1's hand (fuses: athlete-pair AND charge-pair).
  v_c1 := public.ccg_instantiate_card(v_match, 1::SMALLINT,
    (SELECT id FROM public.moment_chits WHERE name='Seed Sprinter'), 'hand', 1);
  v_c2 := public.ccg_instantiate_card(v_match, 1::SMALLINT,
    (SELECT id FROM public.moment_chits WHERE name='Seed Striker'), 'hand', 2);

  PERFORM public.ccg_submit_turn(v_match, jsonb_build_array(
    jsonb_build_object('type','summon','card_id',v_c1,'position',1),
    jsonb_build_object('type','summon','card_id',v_c2,'position',2),
    jsonb_build_object('type','end')));

  SELECT life INTO v_life2 FROM public.ccg_match_players WHERE match_id=v_match AND seat=2;
  SELECT COUNT(*) INTO v_fusions FROM public.ccg_events WHERE match_id=v_match AND event_type='fusion';
  SELECT COUNT(*) INTO v_summons FROM public.ccg_events WHERE match_id=v_match AND event_type='summon';

  IF v_summons < 2 THEN RAISE EXCEPTION 'SMOKE FAIL: expected 2 summon events, got %', v_summons; END IF;
  IF v_fusions < 1 THEN RAISE EXCEPTION 'SMOKE FAIL: expected ≥1 fusion event, got %', v_fusions; END IF;
  IF v_life2 >= 30 THEN RAISE EXCEPTION 'SMOKE FAIL: fusion should have damaged seat 2 face (life=%)', v_life2; END IF;

  -- Clean up the synthetic match so it never appears in prod data.
  DELETE FROM public.ccg_matches WHERE id = v_match;  -- cascades to players/cards/events
  RAISE NOTICE 'CCG engine smoke OK: 2 summons, % fusion(s), seat2 life %', v_fusions, v_life2;
END $$;
