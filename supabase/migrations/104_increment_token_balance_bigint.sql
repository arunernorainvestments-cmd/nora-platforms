-- ─────────────────────────────────────────────────────────────────────────────
-- 104 — increment_token_balance(uuid, bigint) overload  [BUGFIX]
--
-- distribute_match_revenue (091) declares its payout variables as BIGINT and calls
-- increment_token_balance(uuid, bigint), but the only definition is
-- increment_token_balance(uuid, integer) (008). PostgreSQL does not implicitly
-- narrow bigint→integer during function resolution, so the call raised
-- "function increment_token_balance(uuid, bigint) does not exist".
--
-- Effect of the bug: EVERY battle_outcome market settlement failed. The failure was
-- masked because process_battle_turn wraps distribute_match_revenue in
-- EXCEPTION WHEN OTHERS → RAISE WARNING, so the match resolved but winning bettors
-- were never paid and the market was left 'open'. Surfaced by
-- supabase/tests/battle_market_pipeline_smoke.sql (PASS 9 failed: market open).
--
-- Fix: add a BIGINT overload that delegates to the INTEGER version. Token balances
-- are INTEGER-bounded, so the narrowing cast is safe for the token economy's range.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.increment_token_balance(p_user_id UUID, p_amount BIGINT)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.increment_token_balance(p_user_id, p_amount::INTEGER);
$$;
