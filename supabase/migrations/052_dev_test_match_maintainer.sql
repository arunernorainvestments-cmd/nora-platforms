-- Migration 052: Dev test match maintainer
--
-- Creates a pg_cron job that fires every 2 minutes. If no test creator match
-- is currently pre_match or live, it picks a random same-category pair and
-- creates one with simulated backing. The tick loop (every 3s) then flips
-- pre_match → live automatically.
--
-- Requires migration 051 (dev_arena_back helper).
-- PRE-LAUNCH CLEANUP: SELECT cron.unschedule('dev-test-match-maintainer');
--                     DROP FUNCTION IF EXISTS public.dev_maintain_test_match();

CREATE OR REPLACE FUNCTION public.dev_maintain_test_match()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category   text;
  v_p1_id      uuid;
  v_p2_id      uuid;
  v_p1_sub     text;
  v_p2_sub     text;
  v_p1_mom     numeric := 0;
  v_p2_mom     numeric := 0;
  v_match_id   uuid;
  v_live_count int;
  v_backer1    uuid;
  v_backer2    uuid;
BEGIN
  -- Skip if any test match is already active (pre_match or live)
  SELECT COUNT(*) INTO v_live_count
  FROM public.arena_matches am
  JOIN public.profiles p ON p.id = am.player_1_id
  WHERE p.is_test_account = true
    AND am.state IN ('pre_match', 'live');

  IF v_live_count > 0 THEN RETURN; END IF;

  -- Top up test creator balances before backing so tokens never run dry
  UPDATE public.token_balances
  SET available_tokens = 1000,
      lifetime_earned  = GREATEST(lifetime_earned, 1000)
  WHERE user_id IN (SELECT id FROM public.profiles WHERE is_test_account = true)
    AND available_tokens < 200;

  -- Pick a random category that has 2+ free test creators
  SELECT p.category_1 INTO v_category
  FROM public.profiles p
  WHERE p.is_test_account = true
    AND p.is_market_maker = true
    AND p.category_1 IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.arena_matches am
      WHERE am.state IN ('pending', 'pre_match', 'live')
        AND (am.player_1_id = p.id OR am.player_2_id = p.id)
    )
  GROUP BY p.category_1 HAVING COUNT(*) >= 2
  ORDER BY random() LIMIT 1;

  IF v_category IS NULL THEN RETURN; END IF; -- all pairs busy

  -- Player 1
  SELECT p.id, p.subcategory INTO v_p1_id, v_p1_sub
  FROM public.profiles p
  WHERE p.category_1 = v_category
    AND p.is_test_account = true
    AND p.is_market_maker = true
    AND NOT EXISTS (
      SELECT 1 FROM public.arena_matches am
      WHERE am.state IN ('pending', 'pre_match', 'live')
        AND (am.player_1_id = p.id OR am.player_2_id = p.id)
    )
  ORDER BY random() LIMIT 1;
  IF v_p1_id IS NULL THEN RETURN; END IF;

  SELECT COALESCE(MAX(momentum_score), 0) INTO v_p1_mom
  FROM public.platform_metrics WHERE user_id = v_p1_id;

  -- Player 2 (same category, different creator)
  SELECT p.id, p.subcategory INTO v_p2_id, v_p2_sub
  FROM public.profiles p
  WHERE p.category_1 = v_category
    AND p.is_test_account = true
    AND p.is_market_maker = true
    AND p.id != v_p1_id
    AND NOT EXISTS (
      SELECT 1 FROM public.arena_matches am
      WHERE am.state IN ('pending', 'pre_match', 'live')
        AND (am.player_1_id = p.id OR am.player_2_id = p.id)
    )
  ORDER BY random() LIMIT 1;
  IF v_p2_id IS NULL THEN RETURN; END IF;

  SELECT COALESCE(MAX(momentum_score), 0) INTO v_p2_mom
  FROM public.platform_metrics WHERE user_id = v_p2_id;

  -- Create match in pre_match with scheduled_start in the past
  -- The tick loop (every 3s) will flip it to live on its next run
  INSERT INTO public.arena_matches (
    round, state,
    player_1_id, player_2_id,
    player_1_archetype, player_2_archetype,
    subcategory_p1, subcategory_p2,
    momentum_score_p1_at_start, momentum_score_p2_at_start,
    scheduled_start
  ) VALUES (
    1, 'pre_match',
    v_p1_id, v_p2_id,
    v_category, v_category,
    v_p1_sub, v_p2_sub,
    v_p1_mom, v_p2_mom,
    now() - INTERVAL '5 seconds'
  ) RETURNING id INTO v_match_id;

  INSERT INTO public.arena_state (
    match_id, tick,
    score_p1, score_p2,
    flow_rate_p1, flow_rate_p2,
    heat_influence_p1, heat_influence_p2,
    active_effects, expired_effects,
    suppression_p1, suppression_p2,
    momentum_window_p1, momentum_window_p2,
    total_pool_p1, total_pool_p2
  ) VALUES (
    v_match_id, 0,
    0, 0, 0, 0, 0, 0,
    '[]'::jsonb, '[]'::jsonb,
    0, 0, false, false, 0, 0
  );

  -- Simulated backing: two random non-player test creators, ~60/40 split
  SELECT p.id INTO v_backer1
  FROM public.profiles p
  WHERE p.is_test_account = true AND p.id != v_p1_id AND p.id != v_p2_id
  ORDER BY random() LIMIT 1;

  SELECT p.id INTO v_backer2
  FROM public.profiles p
  WHERE p.is_test_account = true
    AND p.id != v_p1_id AND p.id != v_p2_id AND p.id != v_backer1
  ORDER BY random() LIMIT 1;

  BEGIN
    IF v_backer1 IS NOT NULL THEN
      PERFORM public.dev_arena_back(v_backer1, v_match_id, v_p1_id, 40);
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    IF v_backer2 IS NOT NULL THEN
      PERFORM public.dev_arena_back(v_backer2, v_match_id, v_p2_id, 30);
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RAISE NOTICE 'dev_maintain_test_match: created % (% vs % in %)',
    v_match_id, v_p1_id, v_p2_id, v_category;
END;
$$;

-- Schedule: every 2 minutes. Idempotent — unschedule first if already exists.
DO $$ BEGIN
  PERFORM cron.unschedule('dev-test-match-maintainer');
EXCEPTION WHEN OTHERS THEN NULL; END; $$;

SELECT cron.schedule(
  'dev-test-match-maintainer',
  '*/2 * * * *',
  'SELECT public.dev_maintain_test_match()'
);
