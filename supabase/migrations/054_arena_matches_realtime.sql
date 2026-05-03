-- Migration 054: Add arena_matches to Realtime publication
--
-- arena_state and arena_events were published in migration 029.
-- arena_matches was omitted, so Flutter .stream() only got the initial row
-- and never received state transitions (pre_match → live → resolved).
-- ArenaMatchScreen action buttons, banners, and timers were permanently
-- frozen at the match state captured at navigation time.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'arena_matches'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.arena_matches;
  END IF;
END $$;
