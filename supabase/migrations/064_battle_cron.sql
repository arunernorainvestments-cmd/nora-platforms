-- Migration 064: Battle Mode Phase A — pg_cron jobs
--
-- process_all_battle_turns(): wrapper so pg_cron can call process_battle_turn()
-- for every active match using the established SELECT public.fn_name() pattern.
--
-- Sub-minute scheduling uses pg_cron interval string format ('3 seconds').
-- Requires pg_cron 1.6+ (Supabase Pro/Team plan).
-- To fall back to 1-minute polling (free tier):
--   SELECT cron.unschedule('battle-turn-processor');
--   SELECT cron.schedule('battle-turn-processor', '* * * * *',
--     'SELECT public.process_all_battle_turns()');

-- ============================================================
-- Wrapper: iterate all active matches and call resolution function
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_all_battle_turns()
RETURNS void AS $$
DECLARE
  v_match_id UUID;
BEGIN
  FOR v_match_id IN
    SELECT id FROM battle_matches WHERE status = 'active'
  LOOP
    PERFORM process_battle_turn(v_match_id);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Wrapper: abandoned match cleanup
-- ============================================================
CREATE OR REPLACE FUNCTION public.cleanup_abandoned_battle_matches()
RETURNS void AS $$
BEGIN
  UPDATE battle_matches
  SET status = 'abandoned'
  WHERE
    (status = 'lobby'  AND created_at < NOW() - INTERVAL '30 minutes')
    OR
    (status = 'active' AND started_at < NOW() - INTERVAL '2 hours');
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- pg_cron: turn processor every 3 seconds
-- ============================================================
SELECT cron.schedule(
  'battle-turn-processor',
  '3 seconds',
  'SELECT public.process_all_battle_turns()'
);

-- ============================================================
-- pg_cron: abandoned match cleanup every 10 minutes
-- ============================================================
SELECT cron.schedule(
  'battle-cleanup',
  '*/10 * * * *',
  'SELECT public.cleanup_abandoned_battle_matches()'
);
