-- Migration 143: fix a latent P3 bug in ccg_create_match (mig 129).
--
-- Its match_start emit passed the actor seat as an INTEGER literal, but
-- ccg_emit_event takes SMALLINT — int4→int2 is an assignment-context cast, which
-- function resolution does NOT apply, so every real call raised
-- "function ccg_emit_event(uuid, integer, unknown, integer, jsonb) does not exist".
-- Undetected until now because the mig-129 apply-time smoke built its synthetic
-- match manually (and ccg_submit_turn paths all pass SMALLINT variables); the M-P4
-- wager entry point (mig 142) is the first caller to execute ccg_create_match.
-- One-token fix: 1::SMALLINT. Body otherwise identical to mig 129.

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

  PERFORM public.ccg_emit_event(v_match, 1, 'match_start', 1::SMALLINT,
    jsonb_build_object('is_test', p_is_test));
  PERFORM public.ccg_begin_turn(v_match);
  RETURN v_match;
END;
$$;

-- ── apply-time smoke: the fixed entry point actually runs now ─────────────────────
DO $$
DECLARE v_match UUID; v_n INTEGER;
BEGIN
  v_match := public.ccg_create_match(NULL, NULL, NULL, NULL, TRUE);
  SELECT COUNT(*) INTO v_n FROM public.ccg_events
  WHERE match_id = v_match AND event_type = 'match_start';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: match_start event missing'; END IF;
  DELETE FROM public.ccg_matches WHERE id = v_match;  -- cascades players/cards/events
  RAISE NOTICE 'ccg_create_match fix smoke OK: entry point executes end-to-end';
END $$;
