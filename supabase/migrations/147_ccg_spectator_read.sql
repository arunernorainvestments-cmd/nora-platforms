-- Migration 147: CCG spectator read path (two-app structure).
--
-- The card-battler is PLAYED in the NORA Arena mobile app; the web app is the
-- companion (mint, collect, spectate — RECONCILIATION contract). Until now the
-- ccg_* RLS only let PARTICIPANTS read a match, so the web Battle page could not
-- show live Arena matches. This adds additive spectator SELECT policies:
--
--   * ccg_matches / ccg_match_players / ccg_events: any authenticated user may
--     read — events are already authored symmetric-visible (both seats see every
--     event; draws carry only opaque card_ids), so spectators learn nothing a
--     participant's opponent doesn't already know.
--   * ccg_match_cards: spectators see the BOARD only (field/graveyard zones);
--     hands and decks stay participant-scoped exactly as before.
--
-- Spectating is read-only — Hard Rules 26 (one role per match) and 17 are
-- untouched; the bet path stays ccg_place_bet/battle_place_spectator_bet_usd
-- with its existing KYC + integrity triggers.
--
-- Also adds ccg_matches + ccg_match_players to the realtime publication so the
-- web spectate view updates live (ccg_events + match_vibe were added in mig 130).

-- ── spectator SELECT policies (additive; participant policies unchanged) ─────────
CREATE POLICY "ccg_matches_spectate" ON public.ccg_matches
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "ccg_players_spectate" ON public.ccg_match_players
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "ccg_events_spectate" ON public.ccg_events
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "ccg_cards_spectate" ON public.ccg_match_cards
  FOR SELECT TO authenticated USING (zone IN ('field','graveyard'));

-- ── realtime publication for the live list + life/aura updates ───────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='ccg_matches') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ccg_matches;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='ccg_match_players') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ccg_match_players;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='ccg_match_cards') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ccg_match_cards;
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: policies present; publication carries the live tables;
-- hand/deck zones are NOT spectator-visible via the new card policy.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_n INT;
BEGIN
  SELECT COUNT(*) INTO v_n FROM pg_policies
  WHERE schemaname = 'public'
    AND policyname IN ('ccg_matches_spectate','ccg_players_spectate',
                       'ccg_events_spectate','ccg_cards_spectate');
  IF v_n <> 4 THEN RAISE EXCEPTION 'SMOKE FAIL: expected 4 spectator policies, found %', v_n; END IF;

  SELECT COUNT(*) INTO v_n FROM pg_publication_tables
  WHERE pubname = 'supabase_realtime'
    AND tablename IN ('ccg_matches','ccg_match_players','ccg_match_cards','ccg_events');
  IF v_n <> 4 THEN RAISE EXCEPTION 'SMOKE FAIL: realtime publication missing ccg tables (%)', v_n; END IF;

  -- The card policy's zone guard is the hand/deck privacy line — assert its shape.
  SELECT COUNT(*) INTO v_n FROM pg_policies
  WHERE policyname = 'ccg_cards_spectate' AND qual LIKE '%field%graveyard%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: ccg_cards_spectate must be zone-guarded'; END IF;

  RAISE NOTICE 'ccg-spectate smoke OK: 4 policies + realtime publication + zone guard';
END $$;
