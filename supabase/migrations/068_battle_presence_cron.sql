-- Migration 068: Battle Mode Phase B — Presence detection pg_cron
--
-- Wrapper function avoids $$ quoting conflicts inside cron.schedule.
-- Pattern matches established project convention (process_all_battle_turns, etc.).
--
-- Players are considered disconnected if last_seen_at > 90 seconds ago.
-- Flip is_automated = TRUE → turn engine auto-selects their moves.
-- Client calls battle_reconnect() to flip back to FALSE.

-- ============================================================
-- Wrapper: mark stale players as automated
-- ============================================================
CREATE OR REPLACE FUNCTION public.battle_check_presence()
RETURNS void AS $$
BEGIN
  UPDATE battle_participants
  SET is_automated = TRUE
  WHERE is_fainted  = FALSE
    AND is_automated = FALSE
    AND last_seen_at < NOW() - INTERVAL '90 seconds'
    AND match_id IN (
      SELECT id FROM battle_matches WHERE status = 'active'
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- pg_cron: presence check every 60 seconds
-- ============================================================
SELECT cron.schedule(
  'battle-presence-check',
  '* * * * *',
  'SELECT public.battle_check_presence()'
);
