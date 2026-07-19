-- Migration 169: fix infinite RLS recursion on the ccg_* participant policies.
--
-- Found by the P7 7.5 money-round-trip smoke (2026-07-19): any AUTHENTICATED read
-- of ccg_match_players / ccg_match_cards fails with "infinite recursion detected
-- in policy for relation ccg_match_players". Cause: the mig-126 participant
-- policies are mutually recursive — ccg_matches' policy subqueries
-- ccg_match_players (RLS applies), whose policy subqueries ccg_matches (RLS
-- applies), and so on. Postgres aborts at policy expansion, so the OR'd mig-147
-- spectator policies never save the query.
--
-- Impact until now: the web play client's hand/seat reads (myHandStreamProvider,
-- mySeatProvider, myActiveCcgMatchProvider) and the crossplay smoke's RLS probe
-- all errored and were silently treated as empty. Spectate zones read through
-- the same broken table policies.
--
-- Fix (standard Supabase pattern): SECURITY DEFINER helpers read the seat table
-- WITHOUT RLS; policies call the helpers instead of subquerying each other.
-- Privacy line is unchanged: hands/decks are visible only to their owner seat;
-- field/graveyard to any authenticated viewer (mig 147 spectator contract).

-- ── 1. Helpers (definer = no RLS on the lookup; STABLE for per-query caching) ───
CREATE OR REPLACE FUNCTION public.ccg_is_participant(p_match_id UUID, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.ccg_match_players
    WHERE match_id = p_match_id AND user_id = p_user
  );
$$;

CREATE OR REPLACE FUNCTION public.ccg_participant_seat(p_match_id UUID, p_user UUID)
RETURNS SMALLINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT seat FROM public.ccg_match_players
  WHERE match_id = p_match_id AND user_id = p_user
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.ccg_match_is_test(p_match_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT is_test FROM public.ccg_matches WHERE id = p_match_id), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.ccg_is_participant(UUID, UUID) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.ccg_participant_seat(UUID, UUID) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.ccg_match_is_test(UUID) TO authenticated, anon;

-- ── 2. Recreate the participant policies without cross-table RLS recursion ──────
DROP POLICY IF EXISTS "ccg_matches_select" ON public.ccg_matches;
CREATE POLICY "ccg_matches_select" ON public.ccg_matches
  FOR SELECT USING (
    is_test OR public.ccg_is_participant(id, auth.uid())
  );

DROP POLICY IF EXISTS "ccg_players_select" ON public.ccg_match_players;
CREATE POLICY "ccg_players_select" ON public.ccg_match_players
  FOR SELECT USING (
    public.ccg_match_is_test(match_id)
    OR public.ccg_is_participant(match_id, auth.uid())
  );

DROP POLICY IF EXISTS "ccg_cards_select" ON public.ccg_match_cards;
CREATE POLICY "ccg_cards_select" ON public.ccg_match_cards
  FOR SELECT USING (
    public.ccg_match_is_test(match_id)
    OR (public.ccg_is_participant(match_id, auth.uid()) AND (
          zone IN ('field','graveyard')
          OR owner_seat = public.ccg_participant_seat(match_id, auth.uid())))
  );

DROP POLICY IF EXISTS "ccg_events_select" ON public.ccg_events;
CREATE POLICY "ccg_events_select" ON public.ccg_events
  FOR SELECT USING (
    public.ccg_match_is_test(match_id)
    OR public.ccg_is_participant(match_id, auth.uid())
  );

-- ── 3. Apply-time smoke: read the tables AS an authenticated participant ────────
-- Simulates a signed-in participant (SET LOCAL ROLE authenticated + jwt claims)
-- and proves: no recursion error, own hand visible, opponent hand invisible.
DO $$
DECLARE
  v_user UUID; v_match UUID; v_chit UUID; v_n INTEGER;
BEGIN
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'mig 169 smoke SKIPPED (no auth user)';
    RETURN;
  END IF;

  v_chit := public.create_moment_chit('__mig169_smoke__', 'athlete', 'creature', 'F');

  INSERT INTO public.ccg_matches (is_test, active_seat, turn_number)
  VALUES (FALSE, 1, 1) RETURNING id INTO v_match;
  INSERT INTO public.ccg_match_players (match_id, seat, user_id, life)
  VALUES (v_match, 1, v_user, 30), (v_match, 2, NULL, 30);
  -- Instantiate through the engine helper so every snapshot column is filled.
  PERFORM public.ccg_instantiate_card(v_match, 1::SMALLINT, v_chit, 'hand', 1);  -- own hand: visible
  PERFORM public.ccg_instantiate_card(v_match, 2::SMALLINT, v_chit, 'hand', 1);  -- opp hand: hidden
  PERFORM public.ccg_instantiate_card(v_match, 2::SMALLINT, v_chit, 'field', 2); -- board: visible

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  SELECT COUNT(*) INTO v_n FROM public.ccg_match_players WHERE match_id = v_match;
  IF v_n <> 2 THEN RAISE EXCEPTION 'SMOKE FAIL: participant must read both seats (got %)', v_n; END IF;

  SELECT COUNT(*) INTO v_n FROM public.ccg_match_cards
  WHERE match_id = v_match AND zone = 'hand' AND owner_seat = 1;
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: own hand must be visible (got %)', v_n; END IF;

  SELECT COUNT(*) INTO v_n FROM public.ccg_match_cards
  WHERE match_id = v_match AND zone = 'hand' AND owner_seat = 2;
  IF v_n <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: opponent hand must stay hidden (got %)', v_n; END IF;

  SELECT COUNT(*) INTO v_n FROM public.ccg_match_cards
  WHERE match_id = v_match AND zone = 'field';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: field must be visible (got %)', v_n; END IF;

  RESET ROLE;
  DELETE FROM public.ccg_matches WHERE id = v_match;  -- cascades players/cards
  DELETE FROM public.moment_chits WHERE id = v_chit;
  RAISE NOTICE 'ccg-rls-recursion smoke OK: participant reads work, hand privacy holds';
END $$;
