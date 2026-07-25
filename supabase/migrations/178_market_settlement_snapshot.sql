-- Migration 178: markets.settlement_snapshot — make token settlement retry-safe.
--
-- Money-path audit 2026-07-25, bug #2 (and the #3 it would otherwise create).
--
-- resolve-markets pays winners in a loop of separate calls. Two problems:
--
--   #2 A failed `increment_token_balance` was swallowed (console.error) and the
--      code STILL wrote the bet_won ledger row and marked the bet 'won'. Because
--      the per-bet status is also the double-pay guard, that bet could never be
--      retried: the user was recorded as paid and received nothing.
--
--   #3 The obvious fix — leave the bet 'active' and the market unresolved so the
--      next cron run retries — is unsafe on its own, because the pool totals are
--      recomputed from the bets still 'active'. A retry would pay the stragglers
--      out of a SMALLER losing pool than the one their odds were struck against.
--
-- This column closes both: the first settlement pass persists the pool figures it
-- computed, and every later pass reuses them verbatim instead of recomputing.
-- Settlement becomes deterministic no matter how many times it is interrupted.
--
-- Shape (written once, then read-only):
--   { "result": "above"|"below", "total_winning": int, "winning_pool": int,
--     "rake": int, "platform_fee": int, "market_maker_fee": int }

ALTER TABLE public.markets
  ADD COLUMN IF NOT EXISTS settlement_snapshot JSONB;

COMMENT ON COLUMN public.markets.settlement_snapshot IS
  'Pool figures frozen at the first settlement attempt (mig 178). resolve-markets '
  'reuses these on every retry so an interrupted payout run never re-prices the '
  'remaining winners against a shrunken pool. Written once; never recomputed.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — the column exists, accepts the documented shape, and is
-- readable back as the same integers (no JSON number coercion surprises).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_market UUID;
  v_snap   JSONB;
BEGIN
  SELECT id INTO v_market FROM public.markets ORDER BY created_at DESC LIMIT 1;
  IF v_market IS NULL THEN
    RAISE NOTICE 'mig 178 smoke: no markets on this database — column added, nothing to probe';
    RETURN;
  END IF;

  -- Probe on a real row, then put it back exactly as it was (settlement_snapshot
  -- is NULL for every existing market — nothing has settled under the new code).
  UPDATE public.markets SET settlement_snapshot = jsonb_build_object(
    'result', 'above', 'total_winning', 1234, 'winning_pool', 2345,
    'rake', 100, 'platform_fee', 50, 'market_maker_fee', 50
  ) WHERE id = v_market;

  SELECT settlement_snapshot INTO v_snap FROM public.markets WHERE id = v_market;
  IF (v_snap->>'total_winning')::INTEGER <> 1234
     OR (v_snap->>'winning_pool')::INTEGER <> 2345
     OR (v_snap->>'rake')::INTEGER <> 100
     OR v_snap->>'result' <> 'above' THEN
    RAISE EXCEPTION 'SMOKE FAIL: settlement_snapshot did not round-trip (%)', v_snap;
  END IF;

  UPDATE public.markets SET settlement_snapshot = NULL WHERE id = v_market;
  IF (SELECT settlement_snapshot FROM public.markets WHERE id = v_market) IS NOT NULL THEN
    RAISE EXCEPTION 'SMOKE FAIL: probe row was not restored';
  END IF;

  RAISE NOTICE 'mig 178 smoke OK: settlement_snapshot round-trips and the probe row is clean';
END $$;
