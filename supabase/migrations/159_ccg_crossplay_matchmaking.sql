-- Migration 159: cross-platform CCG matchmaking + forfeit + engine grants lockdown.
--
-- CROSSPLAY (spec: NORA_PLATFORMS_CROSSPLAY_SPEC.md): web and the NORA Arena mobile
-- app share ONE matchmaking queue over the same backend — a web player and an Arena
-- player pair into the same ccg_match and play via the same ccg_submit_turn resolver.
-- The client platform is recorded for telemetry only; it never affects pairing.
--
--   ccg_queue_join(deck, platform)  → matched (with match_id) | queued | in_match | deck_illegal
--   ccg_queue_poll()                → heartbeat + matched | queued (position) | in_match | idle
--   ccg_queue_leave()               → left | matched (too late — match already exists)
--   ccg_forfeit_match(match)        → concede: winner = other seat (settle triggers fire)
--
-- A queued client learns it was matched EITHER by realtime (own ccg_queue row UPDATE
-- carries matched_match_id — the table is added to the publication; RLS scopes it to
-- the owner) OR by polling ccg_queue_poll (the fallback). The player who completes the
-- pair gets the match_id synchronously from ccg_queue_join.
--
-- Also locks down the engine internals: every ccg_* helper that must only run inside
-- the resolver (emit/draw/damage/settle/create_match/…) loses the default PUBLIC
-- EXECUTE — before this, any authenticated user could call ccg_create_match or forge
-- ccg_emit_event directly. Client-facing RPCs (ccg_submit_turn, ccg_place_bet,
-- ccg_record_vibe_signal, ccg_get_match_vibe, ccg_match_is_monetized) are unchanged —
-- they do their own auth internally.

-- ── the queue ──────────────────────────────────────────────────────────────────────
CREATE TABLE public.ccg_queue (
  user_id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  deck_id          UUID NOT NULL REFERENCES public.decks(id) ON DELETE CASCADE,
  platform         TEXT NOT NULL DEFAULT 'web' CHECK (platform IN ('web','arena')),
  enqueued_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  heartbeat_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  matched_match_id UUID REFERENCES public.ccg_matches(id) ON DELETE SET NULL
);

CREATE INDEX ccg_queue_wait_idx ON public.ccg_queue (enqueued_at)
  WHERE matched_match_id IS NULL;

COMMENT ON TABLE public.ccg_queue IS
  'Cross-platform CCG matchmaking queue (web + NORA Arena app, one pool). One row per '
  'user; writes only via the ccg_queue_* SECURITY DEFINER RPCs. matched_match_id is '
  'set on the waiting player''s row when an opponent pairs with them.';

ALTER TABLE public.ccg_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ccg_queue_select_own" ON public.ccg_queue
  FOR SELECT USING (auth.uid() = user_id);
-- No client INSERT/UPDATE/DELETE policies — RPCs only.

-- Realtime: the queued client subscribes to its own row (RLS-scoped) to hear the
-- matched_match_id UPDATE the moment an opponent pairs with it.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='ccg_queue') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ccg_queue;
  END IF;
END $$;

-- ── internal: the caller's live (non-test) match, if any ───────────────────────────
CREATE FUNCTION public.ccg_active_match_of(p_user UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT m.id
  FROM public.ccg_matches m
  JOIN public.ccg_match_players p ON p.match_id = m.id
  WHERE p.user_id = p_user AND m.status = 'active' AND m.is_test = FALSE
  ORDER BY m.created_at DESC
  LIMIT 1;
$$;

-- ── internal: sweep abandoned queue rows (no heartbeat for 90s) ─────────────────────
CREATE FUNCTION public.ccg_queue_sweep()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_n INTEGER;
BEGIN
  DELETE FROM public.ccg_queue
  WHERE matched_match_id IS NULL
    AND heartbeat_at < NOW() - INTERVAL '90 seconds';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

-- ── join: validate deck → pair with the oldest waiting player, or wait ──────────────
CREATE FUNCTION public.ccg_queue_join(p_deck_id UUID, p_platform TEXT DEFAULT 'web')
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user  UUID := auth.uid();
  v_match UUID;
  v_val   JSONB;
  v_opp   public.ccg_queue%ROWTYPE;
  v_size  INTEGER;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  IF p_platform NOT IN ('web','arena') THEN RAISE EXCEPTION 'Unknown platform: %', p_platform; END IF;

  -- Already seated in a live match → resume it, don't queue.
  v_match := public.ccg_active_match_of(v_user);
  IF v_match IS NOT NULL THEN
    RETURN jsonb_build_object('status','in_match','match_id',v_match);
  END IF;

  -- A pending pairing from an earlier queue session → hand it over.
  SELECT matched_match_id INTO v_match FROM public.ccg_queue WHERE user_id = v_user;
  IF v_match IS NOT NULL THEN
    DELETE FROM public.ccg_queue WHERE user_id = v_user;
    RETURN jsonb_build_object('status','matched','match_id',v_match);
  END IF;

  -- Deck must be the caller's and LIVE-legal (revalidate — is_legal can go stale
  -- when a chit in it is retired/listed after the last validation).
  IF NOT EXISTS (SELECT 1 FROM public.decks WHERE id = p_deck_id AND user_id = v_user) THEN
    RAISE EXCEPTION 'Not your deck';
  END IF;
  v_val := public.deck_validate(p_deck_id);
  IF NOT (v_val->>'is_valid')::BOOLEAN THEN
    RETURN jsonb_build_object('status','deck_illegal','errors',v_val->'errors');
  END IF;
  UPDATE public.decks SET is_legal = TRUE, validated_at = NOW() WHERE id = p_deck_id;

  PERFORM public.ccg_queue_sweep();

  -- Pair with the oldest fresh candidate whose deck still validates; skip (and
  -- drop) entries whose deck went illegal while they waited.
  FOR v_opp IN
    SELECT * FROM public.ccg_queue
    WHERE user_id <> v_user AND matched_match_id IS NULL
    ORDER BY enqueued_at
    FOR UPDATE SKIP LOCKED
  LOOP
    IF (public.deck_validate(v_opp.deck_id)->>'is_valid')::BOOLEAN THEN
      -- Seat 1 = the player who waited; seat 2 = the joiner.
      v_match := public.ccg_create_match(v_opp.user_id, v_opp.deck_id, v_user, p_deck_id, FALSE);
      UPDATE public.ccg_queue SET matched_match_id = v_match WHERE user_id = v_opp.user_id;
      -- Drop any leftover unmatched row of the joiner's (an earlier queue session)
      -- so nobody can pair with a player who just entered a match.
      DELETE FROM public.ccg_queue WHERE user_id = v_user;
      RETURN jsonb_build_object('status','matched','match_id',v_match,'seat',2);
    ELSE
      DELETE FROM public.ccg_queue WHERE user_id = v_opp.user_id;
    END IF;
  END LOOP;

  -- Nobody waiting → wait (idempotent re-join refreshes deck/platform/heartbeat).
  INSERT INTO public.ccg_queue (user_id, deck_id, platform)
  VALUES (v_user, p_deck_id, p_platform)
  ON CONFLICT (user_id) DO UPDATE
    SET deck_id = EXCLUDED.deck_id, platform = EXCLUDED.platform, heartbeat_at = NOW();

  SELECT COUNT(*) INTO v_size FROM public.ccg_queue WHERE matched_match_id IS NULL;
  RETURN jsonb_build_object('status','queued','queue_size',v_size);
END;
$$;

-- ── poll: heartbeat + current state (the realtime-less fallback) ────────────────────
CREATE FUNCTION public.ccg_queue_poll()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_row  public.ccg_queue%ROWTYPE;
  v_match UUID;
  v_pos  INTEGER;
  v_size INTEGER;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;

  UPDATE public.ccg_queue SET heartbeat_at = NOW()
  WHERE user_id = v_user
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    v_match := public.ccg_active_match_of(v_user);
    IF v_match IS NOT NULL THEN
      RETURN jsonb_build_object('status','in_match','match_id',v_match);
    END IF;
    RETURN jsonb_build_object('status','idle');
  END IF;

  IF v_row.matched_match_id IS NOT NULL THEN
    DELETE FROM public.ccg_queue WHERE user_id = v_user;
    RETURN jsonb_build_object('status','matched','match_id',v_row.matched_match_id,'seat',1);
  END IF;

  SELECT COUNT(*) + 1 INTO v_pos FROM public.ccg_queue
  WHERE matched_match_id IS NULL AND enqueued_at < v_row.enqueued_at;
  SELECT COUNT(*) INTO v_size FROM public.ccg_queue WHERE matched_match_id IS NULL;
  RETURN jsonb_build_object(
    'status','queued','position',v_pos,'queue_size',v_size,
    'queued_for_seconds', EXTRACT(EPOCH FROM (NOW() - v_row.enqueued_at))::INTEGER);
END;
$$;

-- ── leave: only an unmatched entry can back out ─────────────────────────────────────
CREATE FUNCTION public.ccg_queue_leave()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_match UUID;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;

  SELECT matched_match_id INTO v_match FROM public.ccg_queue WHERE user_id = v_user;
  IF v_match IS NOT NULL THEN
    -- Too late: an opponent already built the match. Hand it over instead.
    DELETE FROM public.ccg_queue WHERE user_id = v_user;
    RETURN jsonb_build_object('status','matched','match_id',v_match,'seat',1);
  END IF;

  DELETE FROM public.ccg_queue WHERE user_id = v_user;
  RETURN jsonb_build_object('status','left');
END;
$$;

-- ── forfeit: a seated player concedes; the finish UPDATE fires the settle triggers ──
-- (wager transfer mig 142, market settlement mig 134) exactly as a played-out win.
CREATE FUNCTION public.ccg_forfeit_match(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_m    public.ccg_matches%ROWTYPE;
  v_seat SMALLINT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;

  SELECT * INTO v_m FROM public.ccg_matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Match not found'; END IF;
  IF v_m.status <> 'active' THEN
    RETURN jsonb_build_object('status',v_m.status,'winner_seat',v_m.winner_seat);
  END IF;
  IF v_m.is_test THEN RAISE EXCEPTION 'Test matches cannot be forfeited'; END IF;

  SELECT seat INTO v_seat FROM public.ccg_match_players
  WHERE match_id = p_match_id AND user_id = v_user;
  IF v_seat IS NULL THEN RAISE EXCEPTION 'Not a player in this match'; END IF;

  PERFORM public.ccg_emit_event(p_match_id, v_m.turn_number, 'match_end',
    v_seat, jsonb_build_object('reason','forfeit','forfeited_by',v_seat,
                               'winner_seat',public.ccg_other_seat(v_seat)));

  UPDATE public.ccg_matches
  SET status = 'finished', winner_seat = public.ccg_other_seat(v_seat), finished_at = NOW()
  WHERE id = p_match_id;

  RETURN jsonb_build_object('status','finished',
                            'winner_seat',public.ccg_other_seat(v_seat));
END;
$$;

-- ── grants: queue + forfeit are the client surface; engine internals are locked ─────
GRANT EXECUTE ON FUNCTION public.ccg_queue_join(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ccg_queue_poll() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ccg_queue_leave() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ccg_forfeit_match(UUID) TO authenticated;

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'ccg_create_match','ccg_instantiate_card','ccg_emit_event','ccg_begin_turn',
      'ccg_draw_card','ccg_apply_effect','ccg_apply_card_effect','ccg_damage_creature',
      'ccg_kill_card','ccg_check_win','ccg_other_seat','ccg_resolve_fusions',
      'ccg_fire_timed_triggers','ccg_latch_vibe_on_turn','ccg_settle_market',
      'ccg_settle_wager','ccg_settle_on_finish','ccg_wager_on_finish',
      'ccg_usd_credit','ccg_usd_debit','ccg_create_outcome_market',
      'ccg_active_match_of','ccg_queue_sweep')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: policy + publication + grant surface + stale sweep. (The full
-- two-player pair/play/forfeit loop needs two authed users with legal 20-card decks
-- — proven live from the web client; the resolver path itself is mig 129's smoke.)
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_n INTEGER; v_user UUID; v_deck UUID;
BEGIN
  -- policy + publication
  SELECT COUNT(*) INTO v_n FROM pg_policies
  WHERE schemaname='public' AND policyname='ccg_queue_select_own';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: ccg_queue RLS policy missing'; END IF;
  SELECT COUNT(*) INTO v_n FROM pg_publication_tables
  WHERE pubname='supabase_realtime' AND tablename='ccg_queue';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: ccg_queue not in realtime publication'; END IF;

  -- grant surface: clients may queue, may NOT create matches / forge events
  IF NOT has_function_privilege('authenticated','public.ccg_queue_join(uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'SMOKE FAIL: ccg_queue_join must be client-callable'; END IF;
  IF has_function_privilege('authenticated','public.ccg_create_match(uuid,uuid,uuid,uuid,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'SMOKE FAIL: ccg_create_match must not be client-callable'; END IF;
  IF has_function_privilege('authenticated','public.ccg_emit_event(uuid,integer,text,smallint,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'SMOKE FAIL: ccg_emit_event must not be client-callable'; END IF;
  IF NOT has_function_privilege('authenticated','public.ccg_submit_turn(uuid,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'SMOKE FAIL: ccg_submit_turn must stay client-callable'; END IF;

  -- stale sweep (needs any auth user to satisfy the FK; skip silently if none)
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NOT NULL THEN
    INSERT INTO public.decks (user_id, name) VALUES (v_user, '__mm_smoke__')
    RETURNING id INTO v_deck;
    INSERT INTO public.ccg_queue (user_id, deck_id, heartbeat_at)
    VALUES (v_user, v_deck, NOW() - INTERVAL '5 minutes');
    IF public.ccg_queue_sweep() < 1 THEN
      RAISE EXCEPTION 'SMOKE FAIL: stale queue row must be swept'; END IF;
    DELETE FROM public.decks WHERE id = v_deck;
  END IF;

  RAISE NOTICE 'mig 159 smoke OK: queue RLS/realtime + grant lockdown + stale sweep';
END $$;
