-- Migration 179: allow resolution_result = 'voided' on markets.
--
-- Money-path audit 2026-07-25, bug #6 — the reason the token Markets rail has
-- NEVER settled a single market.
--
-- resolve-markets voids a market with no bets (and voids on refund) by writing
--   { status: 'voided', resolution_result: 'voided' }
-- `markets_status_check` allows 'voided', but `markets_resolution_result_check`
-- only ever allowed ('above','below','refund','team_1','team_2'). So every void
-- UPDATE failed the CHECK — and because that UPDATE's error was never inspected,
-- the market silently stayed 'open' while the function counted it as resolved and
-- returned {"resolved":N,"errors":[]}.
--
-- Evidence on prod before this fix: 3 markets open and past end_at since
-- 2026-04-12, zero rows in `markets` ever reaching resolved/voided, and zero
-- 'bet_won' rows in token_transactions in the platform's history.
--
-- 'voided' is added rather than rewriting the code to reuse 'refund' because the
-- two are genuinely different outcomes: 'refund' = the market ran and tied (or
-- lost its oracle) and stakes were returned; 'voided' = the market never had a
-- real contest (no bets, or no bets on the winning side). Collapsing them would
-- lose that distinction on every historical row from here on.
--
-- Rewritten by discovered name rather than assumed name — the mig-174 pattern,
-- since several `markets` CHECKs were applied by hand and are off-ledger.

DO $$
DECLARE v_name TEXT;
BEGIN
  SELECT conname INTO v_name
  FROM pg_constraint
  WHERE conrelid = 'public.markets'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) ILIKE '%resolution_result%';

  IF v_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.markets DROP CONSTRAINT %I', v_name);
  END IF;

  ALTER TABLE public.markets
    ADD CONSTRAINT markets_resolution_result_check
    CHECK (resolution_result IS NULL OR resolution_result = ANY (ARRAY[
      'above','below','refund','team_1','team_2','voided'
    ]));
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — the exact write resolve-markets performs must now succeed,
-- and the previously-allowed values must all still be accepted.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_id UUID;
  v_prev_status TEXT; v_prev_result TEXT; v_prev_at TIMESTAMPTZ;
  v_val TEXT;
BEGIN
  SELECT id, status, resolution_result, resolved_at
    INTO v_id, v_prev_status, v_prev_result, v_prev_at
  FROM public.markets ORDER BY created_at DESC LIMIT 1;

  IF v_id IS NULL THEN
    RAISE NOTICE 'mig 179 smoke: no markets present — constraint widened, nothing to probe';
    RETURN;
  END IF;

  -- The write that used to fail silently.
  UPDATE public.markets
  SET status = 'voided', resolution_result = 'voided', resolved_at = NOW()
  WHERE id = v_id;
  IF (SELECT resolution_result FROM public.markets WHERE id = v_id) <> 'voided' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the void write still does not land';
  END IF;

  -- Every previously-legal value still accepted.
  FOREACH v_val IN ARRAY ARRAY['above','below','refund','team_1','team_2'] LOOP
    UPDATE public.markets SET resolution_result = v_val WHERE id = v_id;
    IF (SELECT resolution_result FROM public.markets WHERE id = v_id) <> v_val THEN
      RAISE EXCEPTION 'SMOKE FAIL: % is no longer accepted', v_val;
    END IF;
  END LOOP;

  -- Garbage still rejected.
  BEGIN
    UPDATE public.markets SET resolution_result = 'nonsense' WHERE id = v_id;
    RAISE EXCEPTION 'SMOKE FAIL: the constraint no longer rejects unknown values';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- Restore the probe row exactly.
  UPDATE public.markets
  SET status = v_prev_status, resolution_result = v_prev_result, resolved_at = v_prev_at
  WHERE id = v_id;
  IF (SELECT status FROM public.markets WHERE id = v_id) IS DISTINCT FROM v_prev_status THEN
    RAISE EXCEPTION 'SMOKE FAIL: probe row was not restored';
  END IF;

  RAISE NOTICE 'mig 179 smoke OK: voided now writes, legacy values intact, unknown values still rejected, probe row restored';
END $$;
