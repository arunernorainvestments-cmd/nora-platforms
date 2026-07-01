-- Migration 127: CCG engine helpers (Phase 3 — P3.2/3.4/3.8).
-- Event emission (with *_after reconciliation), draw + fatigue, KO, win-check, Vibe read.
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 3.

-- ── Vibe read (stub; P4 repoints to match_vibe) ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_get_match_vibe(p_match_id UUID)
RETURNS SMALLINT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT current_vibe FROM public.ccg_matches WHERE id = p_match_id;
$$;

-- ── emit an ordered event, stamping the reconciliation snapshot ─────────────────
CREATE OR REPLACE FUNCTION public.ccg_emit_event(
  p_match_id   UUID,
  p_turn       INTEGER,
  p_type       TEXT,
  p_actor_seat SMALLINT,
  p_payload    JSONB DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seq  INTEGER;
  v_l1   INTEGER;
  v_l2   INTEGER;
  v_aura INTEGER;
  v_active SMALLINT;
BEGIN
  SELECT COALESCE(MAX(sequence_in_turn),0)+1 INTO v_seq
  FROM public.ccg_events WHERE match_id = p_match_id AND turn_number = p_turn;

  SELECT active_seat INTO v_active FROM public.ccg_matches WHERE id = p_match_id;
  SELECT life INTO v_l1 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 1;
  SELECT life INTO v_l2 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 2;
  SELECT aura INTO v_aura FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = v_active;

  INSERT INTO public.ccg_events
    (match_id, turn_number, sequence_in_turn, event_type, actor_seat, payload,
     life_p1_after, life_p2_after, aura_active_after, vibe_after)
  VALUES (p_match_id, p_turn, v_seq, p_type, p_actor_seat, COALESCE(p_payload,'{}'),
     v_l1, v_l2, v_aura, public.ccg_get_match_vibe(p_match_id));
END;
$$;

-- ── opposite seat helper ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_other_seat(p_seat SMALLINT)
RETURNS SMALLINT LANGUAGE sql IMMUTABLE AS $$ SELECT (CASE WHEN p_seat = 1 THEN 2 ELSE 1 END)::SMALLINT $$;

-- ── draw a card (lowest deck_order) into hand; fatigue 1 dmg on empty deck ───────
CREATE OR REPLACE FUNCTION public.ccg_draw_card(p_match_id UUID, p_seat SMALLINT, p_turn INTEGER)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_card UUID;
BEGIN
  SELECT id INTO v_card
  FROM public.ccg_match_cards
  WHERE match_id = p_match_id AND owner_seat = p_seat AND zone = 'deck'
  ORDER BY deck_order
  LIMIT 1;

  IF v_card IS NULL THEN
    -- Fatigue: empty deck costs 1 Life.
    UPDATE public.ccg_match_players SET life = life - 1
    WHERE match_id = p_match_id AND seat = p_seat;
    PERFORM public.ccg_emit_event(p_match_id, p_turn, 'life_change', p_seat,
      jsonb_build_object('reason','fatigue','amount',-1));
    RETURN NULL;
  END IF;

  UPDATE public.ccg_match_cards SET zone = 'hand' WHERE id = v_card;
  PERFORM public.ccg_emit_event(p_match_id, p_turn, 'draw', p_seat,
    jsonb_build_object('card_id', v_card));
  RETURN v_card;
END;
$$;

-- ── send a creature to the graveyard (KO) ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_kill_card(p_card_id UUID, p_turn INTEGER)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_c public.ccg_match_cards%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM public.ccg_match_cards WHERE id = p_card_id;
  IF NOT FOUND OR v_c.zone = 'graveyard' THEN RETURN; END IF;

  UPDATE public.ccg_match_cards
  SET zone = 'graveyard', field_pos = NULL, cur_hp = 0
  WHERE id = p_card_id;

  PERFORM public.ccg_emit_event(v_c.match_id, p_turn, 'ko', v_c.owner_seat,
    jsonb_build_object('card_id', p_card_id, 'chit_id', v_c.chit_id));
END;
$$;

-- ── win check: a player at ≤0 Life loses; emits match_end. Returns TRUE if finished ─
CREATE OR REPLACE FUNCTION public.ccg_check_win(p_match_id UUID, p_turn INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_l1 INTEGER; v_l2 INTEGER; v_winner SMALLINT;
BEGIN
  IF (SELECT status FROM public.ccg_matches WHERE id = p_match_id) <> 'active' THEN
    RETURN TRUE;
  END IF;

  SELECT life INTO v_l1 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 1;
  SELECT life INTO v_l2 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 2;

  IF v_l1 > 0 AND v_l2 > 0 THEN RETURN FALSE; END IF;

  -- Both ≤0 (simultaneous): the active player is considered to have struck last → wins.
  IF v_l1 <= 0 AND v_l2 <= 0 THEN
    v_winner := (SELECT active_seat FROM public.ccg_matches WHERE id = p_match_id);
  ELSIF v_l1 <= 0 THEN
    v_winner := 2;
  ELSE
    v_winner := 1;
  END IF;

  UPDATE public.ccg_matches
  SET status = 'finished', winner_seat = v_winner, finished_at = NOW()
  WHERE id = p_match_id;

  PERFORM public.ccg_emit_event(p_match_id, p_turn, 'match_end', v_winner,
    jsonb_build_object('winner_seat', v_winner));
  RETURN TRUE;
END;
$$;
