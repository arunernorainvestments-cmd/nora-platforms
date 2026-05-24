-- Migration 071: Register pg_cron jobs for Arena and Battle tick warmers.
-- These edge functions keep the Supabase connection pool alive so the tick
-- loops (process_arena_tick, process_all_battle_turns) start immediately.
-- Edge function source: supabase/functions/arena-tick-warmer/ and battle-tick-warmer/
-- Both functions are --no-verify-jwt and accept a service-role Bearer header.
-- Uses the same app.service_role_key pattern as hot-topic cron wrappers.

CREATE OR REPLACE FUNCTION public.call_arena_tick_warmer()
RETURNS void AS $$
DECLARE
  v_key TEXT := current_setting('app.service_role_key', true);
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'app.service_role_key not set — skipping arena-tick-warmer';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/arena-tick-warmer',
    headers := json_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               )::jsonb,
    body    := '{}'::jsonb
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.call_battle_tick_warmer()
RETURNS void AS $$
DECLARE
  v_key TEXT := current_setting('app.service_role_key', true);
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'app.service_role_key not set — skipping battle-tick-warmer';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/battle-tick-warmer',
    headers := json_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key
               )::jsonb,
    body    := '{}'::jsonb
  );
END;
$$ LANGUAGE plpgsql;

-- Unschedule if already exist (idempotent).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'arena-tick-warmer') THEN
    PERFORM cron.unschedule('arena-tick-warmer');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'battle-tick-warmer') THEN
    PERFORM cron.unschedule('battle-tick-warmer');
  END IF;
END;
$$;

-- Every 30 seconds (requires pg_cron 1.6+; falls back to '* * * * *' on older).
SELECT cron.schedule('arena-tick-warmer',  '30 seconds', 'SELECT public.call_arena_tick_warmer()');
SELECT cron.schedule('battle-tick-warmer', '30 seconds', 'SELECT public.call_battle_tick_warmer()');
