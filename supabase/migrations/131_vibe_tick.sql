-- Migration 131: Vibe tick + cron + smoke (Phase 4 — P4).
--
-- process_battle_vibe_tick() mirrors the retired arena tick's COMMIT-per-tick pattern:
-- each scheduled invocation is one tick / one transaction. Multi-factor target =
-- passive floor + recent activity (market bets + spectator presence + token reactions),
-- and the live vibe SLEWS toward the target (slow rise / slower decay) — so thin matches
-- still climb to the floor and hype matches build gradually. Realtime broadcast is via the
-- match_vibe publication (mig 130). Depends on ZERO legacy tables.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 4.

CREATE OR REPLACE FUNCTION public.process_battle_vibe_tick()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id     UUID;
  v_cur    SMALLINT;
  v_floor  SMALLINT;
  v_act    INTEGER;
  v_target INTEGER;
  v_new    INTEGER;
BEGIN
  FOR v_id IN SELECT id FROM public.ccg_matches WHERE status = 'active' LOOP
    INSERT INTO public.match_vibe (match_id) VALUES (v_id) ON CONFLICT DO NOTHING;

    SELECT vibe, vibe_floor INTO v_cur, v_floor FROM public.match_vibe WHERE match_id = v_id;

    -- Recent activity (last 60s), weighted.
    SELECT COALESCE(SUM(weight), 0) INTO v_act
    FROM public.ccg_vibe_events
    WHERE match_id = v_id AND created_at > NOW() - INTERVAL '60 seconds';

    -- Multi-factor target: passive floor + scaled activity, capped at 100.
    v_target := LEAST(100, v_floor + v_act * 5);

    -- Slew toward target: rise up to +5/tick, decay up to -3/tick (never below 0).
    v_new := v_cur + CASE
      WHEN v_target > v_cur THEN LEAST(5, v_target - v_cur)
      WHEN v_target < v_cur THEN -LEAST(3, v_cur - v_target)
      ELSE 0 END;
    v_new := GREATEST(0, LEAST(100, v_new));

    UPDATE public.match_vibe SET vibe = v_new, updated_at = NOW() WHERE match_id = v_id;
  END LOOP;
END;
$$;

-- ── schedule the tick every 30s (idempotent) ────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ccg-vibe-tick') THEN
    PERFORM cron.unschedule('ccg-vibe-tick');
  END IF;
END $$;

SELECT cron.schedule('ccg-vibe-tick', '30 seconds', 'SELECT public.process_battle_vibe_tick()');

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: activity pulse → vibe rises off 0 → round-boundary latch →
-- engine reads the latched value. Raises on failure; clean push proves the Vibe loop.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_match UUID; v_vibe SMALLINT; v_avail SMALLINT;
BEGIN
  INSERT INTO public.ccg_matches (is_test, active_seat, turn_number) VALUES (TRUE, 1, 1)
    RETURNING id INTO v_match;
  INSERT INTO public.ccg_match_players (match_id, seat, life) VALUES (v_match,1,30),(v_match,2,30);

  PERFORM public.ccg_record_vibe_signal(v_match, 'market_bet', 3);
  PERFORM public.ccg_record_vibe_signal(v_match, 'spectator', 2);

  PERFORM public.process_battle_vibe_tick();
  PERFORM public.process_battle_vibe_tick();
  PERFORM public.process_battle_vibe_tick();

  SELECT vibe INTO v_vibe FROM public.match_vibe WHERE match_id = v_match;
  IF v_vibe <= 0 THEN RAISE EXCEPTION 'SMOKE FAIL: vibe should have risen off 0 (got %)', v_vibe; END IF;

  -- Round boundary → latch available_vibe to the live vibe.
  UPDATE public.ccg_matches SET turn_number = 2, active_seat = 2 WHERE id = v_match;
  SELECT available_vibe INTO v_avail FROM public.match_vibe WHERE match_id = v_match;
  IF v_avail <> v_vibe THEN
    RAISE EXCEPTION 'SMOKE FAIL: available_vibe (%) should latch to vibe (%)', v_avail, v_vibe; END IF;
  IF public.ccg_get_match_vibe(v_match) <> v_avail THEN
    RAISE EXCEPTION 'SMOKE FAIL: ccg_get_match_vibe should return latched available_vibe'; END IF;

  DELETE FROM public.ccg_matches WHERE id = v_match;   -- cascades
  RAISE NOTICE 'Vibe tick smoke OK: vibe %, latched available %', v_vibe, v_avail;
END $$;
