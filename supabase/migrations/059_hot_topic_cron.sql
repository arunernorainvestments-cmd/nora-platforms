-- Hot Topic: pg_cron schedule entries
--
-- PREREQUISITE: pg_net extension must be enabled.
--   Supabase Dashboard → Database → Extensions → pg_net → Enable
--
-- SETUP: Store your service role key in a db setting so these wrappers can read it:
--   ALTER DATABASE postgres SET app.service_role_key TO 'your-service-role-key-here';
--
-- TIMEZONE NOTE: all times are UTC. Scoring targets are ET (EDT = UTC-4 in summer).
--   Scoring   7 AM ET  = 11:00 UTC
--   Scoring   6 PM ET  = 22:00 UTC
--   Reset     Monday 7 AM ET = Monday 11:00 UTC
--   Resolve   Friday 8 PM ET = Saturday 00:00 UTC

-- PL/pgSQL wrappers so pg_cron can call these the same way it calls all other cron jobs
-- (SELECT public.fn_name() pattern — consistent with arena-matchmaker, arena-monday-rollover, etc.)

CREATE OR REPLACE FUNCTION public.call_hot_topic_fetch_and_score()
RETURNS void AS $$
DECLARE
  v_key TEXT := current_setting('app.service_role_key', true);
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'app.service_role_key not set — skipping hot-topic-fetch-and-score. Run: ALTER DATABASE postgres SET app.service_role_key TO ''your-key'';';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/hot-topic-fetch-and-score',
    headers := json_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               )::jsonb,
    body    := '{}'::jsonb
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.call_hot_topic_reset_week()
RETURNS void AS $$
DECLARE
  v_key TEXT := current_setting('app.service_role_key', true);
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'app.service_role_key not set — skipping hot-topic-reset-week.';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/hot-topic-reset-week',
    headers := json_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               )::jsonb,
    body    := '{}'::jsonb
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.call_hot_topic_resolve_week()
RETURNS void AS $$
DECLARE
  v_key TEXT := current_setting('app.service_role_key', true);
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'app.service_role_key not set — skipping hot-topic-resolve-week.';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/hot-topic-resolve-week',
    headers := json_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               )::jsonb,
    body    := '{}'::jsonb
  );
END;
$$ LANGUAGE plpgsql;

-- Scoring runs twice daily: 7 AM ET (11:00 UTC) and 6 PM ET (22:00 UTC)
SELECT cron.schedule('hot-topic-morning', '0 11 * * *', 'SELECT public.call_hot_topic_fetch_and_score()');
SELECT cron.schedule('hot-topic-evening', '0 22 * * *', 'SELECT public.call_hot_topic_fetch_and_score()');

-- Weekly reset: Monday 7 AM ET (Monday 11:00 UTC) — initializes new week at 1,000 pts each
SELECT cron.schedule('hot-topic-weekly-reset', '0 11 * * 1', 'SELECT public.call_hot_topic_reset_week()');

-- Weekly resolution: Friday 8 PM ET (Saturday 00:00 UTC) — finalizes standings + resolves weekly bets
SELECT cron.schedule('hot-topic-resolve', '0 0 * * 6', 'SELECT public.call_hot_topic_resolve_week()');
