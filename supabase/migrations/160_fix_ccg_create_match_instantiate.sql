-- Migration 160: fix the second latent int4→int2 bug in ccg_create_match.
--
-- Mig 143 fixed the match_start emit (INTEGER literal vs SMALLINT param), but the
-- DECK path has the identical bug one call down: `FOR v_seat IN 1..2` implicitly
-- redeclares v_seat as INTEGER (shadowing the SMALLINT DECLARE), and
-- ccg_instantiate_card takes SMALLINT — int4→int2 is assignment-context only, so
-- function resolution raises "ccg_instantiate_card(uuid, integer, …) does not
-- exist" on ANY match created with real decks. Undetected until now because every
-- caller so far (mig 143 smoke, wager smoke) passed NULL decks; the crossplay
-- matchmaking queue (mig 159) is the first real deck-path caller.
-- One-token fix: v_seat::SMALLINT on the instantiate call. Body otherwise mig 143.

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
        PERFORM public.ccg_instantiate_card(v_match, v_seat::SMALLINT, v_row.chit_id, 'deck', v_ord);
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

-- Mig 159 locked ccg_create_match away from client roles; CREATE OR REPLACE
-- preserves the ACL, but re-assert for safety.
REVOKE ALL ON FUNCTION public.ccg_create_match(UUID, UUID, UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: a REAL deck-path match (the path every earlier smoke skipped):
-- 10 catalog chits × 2 copies → legal 20-card deck → ccg_create_match deals 40
-- cards + two 3-card opening hands. Subtransaction-rollback pattern: no residue.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID; v_deck UUID; v_chit UUID; v_match UUID; v_n INTEGER; i INTEGER;
BEGIN
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'mig 160 smoke SKIPPED (no auth user)';
    RETURN;
  END IF;

  BEGIN  -- subtransaction: everything below rolls back at the sentinel
    INSERT INTO public.decks (user_id, name) VALUES (v_user, '__mig160_smoke__')
    RETURNING id INTO v_deck;
    FOR i IN 1..10 LOOP
      v_chit := public.create_moment_chit('Mig160 Smoke ' || i, 'athlete', 'creature', 'F');
      PERFORM public.chit_grant(v_user, v_chit, 2, 'event');
      INSERT INTO public.deck_chits (deck_id, chit_id, quantity) VALUES (v_deck, v_chit, 2);
    END LOOP;
    UPDATE public.decks SET is_legal = TRUE, validated_at = NOW() WHERE id = v_deck;

    v_match := public.ccg_create_match(v_user, v_deck, v_user, v_deck, FALSE);

    SELECT COUNT(*) INTO v_n FROM public.ccg_match_cards WHERE match_id = v_match;
    IF v_n <> 40 THEN RAISE EXCEPTION 'SMOKE FAIL: expected 40 dealt cards, got %', v_n; END IF;
    -- 3 + 3 opening hands, +1 from the turn-1 draw (ccg_begin_turn).
    SELECT COUNT(*) INTO v_n FROM public.ccg_match_cards
    WHERE match_id = v_match AND zone = 'hand';
    IF v_n <> 7 THEN RAISE EXCEPTION 'SMOKE FAIL: expected 7 hand cards (3+3+draw), got %', v_n; END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'mig 160 smoke OK: deck-path match creation deals 40 cards + opening hands';
      ELSE
        RAISE;
      END IF;
  END;
END $$;
