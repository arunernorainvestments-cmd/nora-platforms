-- Migration 055: Dev bot backer
--
-- Creates dev_bot_backer() — called by pg_cron every minute.
-- Finds all live test matches and places randomised backs on both sides,
-- creating realistic pool sizes and score movement without any real user action.
--
-- Design:
--   - 2–4 backs per live test match per minute
--   - 5–25 tokens per back, slight p1 bias (55%) for non-trivial score dynamics
--   - Tops up test account balances before backing so tokens never run dry
--   - Silently skips if a back fails (match resolved mid-run, etc.)
--   - Only operates on matches where at least one player is a test account
--
-- PRE-LAUNCH CLEANUP:
--   SELECT cron.unschedule('dev-bot-backer');
--   DROP FUNCTION IF EXISTS public.dev_bot_backer();

CREATE OR REPLACE FUNCTION public.dev_bot_backer() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $body$
DECLARE
  v_match     record;
  v_backer_id uuid;
  v_target_id uuid;
  v_amount    int;
  v_backs     int;
  v_i         int;
BEGIN
  -- Top up all test account balances so bots never run dry
  UPDATE public.token_balances
  SET available_tokens = 500,
      lifetime_earned  = GREATEST(lifetime_earned, 500)
  WHERE user_id IN (SELECT id FROM public.profiles WHERE is_test_account = true)
    AND available_tokens < 100;

  -- Iterate over every live match involving at least one test account player
  FOR v_match IN
    SELECT am.id          AS match_id,
           am.player_1_id AS p1_id,
           am.player_2_id AS p2_id
    FROM   public.arena_matches am
    WHERE  am.state = 'live'
      AND  EXISTS (
             SELECT 1 FROM public.profiles p
             WHERE  p.id = am.player_1_id
               AND  p.is_test_account = true
           )
  LOOP
    -- Place 2–4 backs this minute
    v_backs := 2 + floor(random() * 3)::int;

    FOR v_i IN 1..v_backs LOOP
      -- Pick a random test-account backer that is not playing in this match
      SELECT id INTO v_backer_id
      FROM   public.profiles
      WHERE  is_test_account = true
        AND  id != v_match.p1_id
        AND  id != v_match.p2_id
      ORDER BY random()
      LIMIT 1;

      CONTINUE WHEN v_backer_id IS NULL;

      -- 55% backs go to p1, 45% to p2
      v_target_id := CASE WHEN random() < 0.55
                          THEN v_match.p1_id
                          ELSE v_match.p2_id
                     END;

      -- Random amount 5–25 tokens
      v_amount := 5 + floor(random() * 21)::int;

      BEGIN
        PERFORM public.dev_arena_back(v_backer_id, v_match.match_id, v_target_id, v_amount);
      EXCEPTION WHEN OTHERS THEN
        NULL; -- match may have resolved mid-loop; skip silently
      END;
    END LOOP;
  END LOOP;
END;
$body$;

-- Schedule: every minute. Idempotent — unschedule first if already exists.
DO $$ BEGIN
  PERFORM cron.unschedule('dev-bot-backer');
EXCEPTION WHEN OTHERS THEN NULL; END; $$;

SELECT cron.schedule(
  'dev-bot-backer',
  '* * * * *',
  'SELECT public.dev_bot_backer()'
);
