-- Migration 027: Teardown test accounts
-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
-- DO NOT RUN until the pre-launch full reset. See CLAUDE.md — Pre-Launch Full Reset.
-- This file is committed for version control but must be applied manually.
-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--
-- Deletes all rows linked to test accounts in correct FK order.
-- Wrapped in a transaction — either all deletes succeed or none do.
-- Idempotent: safe to run more than once.

BEGIN;

-- ── Collect test account IDs ──────────────────────────────────────────────────
DO $$
DECLARE
  test_ids uuid[];
BEGIN
  SELECT ARRAY_AGG(id) INTO test_ids
  FROM public.profiles
  WHERE is_test_account = true;

  IF test_ids IS NULL OR array_length(test_ids, 1) = 0 THEN
    RAISE NOTICE 'No test accounts found — teardown is a no-op.';
    RETURN;
  END IF;

  RAISE NOTICE 'Tearing down % test account(s)...', array_length(test_ids, 1);

  -- ── Arena tables (when they exist) ─────────────────────────────────────────
  -- Wrapped in individual DO blocks so missing tables don't abort the transaction.
  BEGIN
    DELETE FROM public.arena_events WHERE user_id = ANY(test_ids);
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN
    DELETE FROM public.arena_state  WHERE player_1_id = ANY(test_ids)
                                       OR player_2_id = ANY(test_ids);
  EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN
    DELETE FROM public.arena_matches WHERE player_1_id = ANY(test_ids)
                                        OR player_2_id = ANY(test_ids);
  EXCEPTION WHEN undefined_table THEN NULL; END;

  -- ── Challenge and badge state ───────────────────────────────────────────────
  DELETE FROM public.user_challenge_progress WHERE user_id = ANY(test_ids);
  DELETE FROM public.user_badges             WHERE user_id = ANY(test_ids);
  DELETE FROM public.user_streaks            WHERE user_id = ANY(test_ids);

  -- ── Score history ───────────────────────────────────────────────────────────
  DELETE FROM public.score_history WHERE user_id = ANY(test_ids);

  -- ── Promotions ──────────────────────────────────────────────────────────────
  DELETE FROM public.promotion_banners
    WHERE target_user_id = ANY(test_ids);

  DELETE FROM public.active_boosts
    WHERE target_user_id    = ANY(test_ids)
       OR activated_by_user_id = ANY(test_ids);

  -- ── Markets and bets ────────────────────────────────────────────────────────
  -- Delete bets on test-account markets first (FK: bets → markets)
  DELETE FROM public.bets
    WHERE market_id IN (
      SELECT id FROM public.markets WHERE creator_id = ANY(test_ids)
    );

  -- Delete bets placed BY test accounts on any market
  DELETE FROM public.bets WHERE user_id = ANY(test_ids);

  DELETE FROM public.markets WHERE creator_id = ANY(test_ids);

  -- ── Token ledger ─────────────────────────────────────────────────────────────
  DELETE FROM public.token_transactions WHERE user_id = ANY(test_ids);
  DELETE FROM public.token_balances     WHERE user_id = ANY(test_ids);
  DELETE FROM public.token_purchases    WHERE user_id = ANY(test_ids);

  -- ── Platform data ───────────────────────────────────────────────────────────
  -- platform_metrics CASCADE deletes when platform_connections is deleted,
  -- but delete explicitly to be safe.
  DELETE FROM public.platform_metrics    WHERE user_id = ANY(test_ids);
  DELETE FROM public.platform_connections WHERE user_id = ANY(test_ids);

  -- ── Spotlight scores ────────────────────────────────────────────────────────
  DELETE FROM public.spotlight_scores WHERE user_id = ANY(test_ids);

  -- ── Notifications ───────────────────────────────────────────────────────────
  DELETE FROM public.notifications WHERE user_id = ANY(test_ids);

  -- ── Balances ────────────────────────────────────────────────────────────────
  DELETE FROM public.balances WHERE user_id = ANY(test_ids);

  -- ── Profiles ────────────────────────────────────────────────────────────────
  DELETE FROM public.profiles WHERE id = ANY(test_ids);

  -- ── Auth users ──────────────────────────────────────────────────────────────
  DELETE FROM auth.users WHERE id = ANY(test_ids);

  RAISE NOTICE 'Teardown complete.';
END;
$$;

COMMIT;
