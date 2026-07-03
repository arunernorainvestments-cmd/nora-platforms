-- Migration 144: fix a latent P1 bug in apply_chit_ledger_to_holdings (mig 117).
--
-- The holdings maintainer used INSERT ... ON CONFLICT DO UPDATE. PostgreSQL
-- evaluates CHECK constraints on the PROPOSED insert row before conflict
-- resolution, so any negative quantity_delta (barter_out, and now wager_escrow /
-- swap_retired from mig 142) violated chit_ownership_quantity_check even when the
-- existing row had ample quantity. Undetected until now: nothing had exercised a
-- disposal end-to-end (the M-P4 wager smoke is the first).
--
-- Fix: UPDATE first, INSERT only when no row exists. Semantics preserved:
--   - disposal from a sufficient balance → row decremented;
--   - disposal below zero → blocked (the column CHECK fires on the updated row);
--   - disposal with no row at all → blocked (CHECK fires on the fresh insert).

CREATE OR REPLACE FUNCTION public.apply_chit_ledger_to_holdings()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.chit_ownership
  SET quantity   = quantity + NEW.quantity_delta,
      updated_at = NOW()
  WHERE user_id = NEW.user_id AND chit_id = NEW.chit_id;

  IF NOT FOUND THEN
    -- Fresh row: a negative delta here is a disposal of nothing — the column
    -- CHECK (quantity >= 0) rejects it.
    INSERT INTO public.chit_ownership (user_id, chit_id, quantity, updated_at)
    VALUES (NEW.user_id, NEW.chit_id, NEW.quantity_delta, NOW());
  END IF;

  RETURN NEW;
END;
$$;

-- ── apply-time smoke (smoke users only; SKIPs elsewhere) ─────────────────────────
DO $$
DECLARE v_u UUID; v_c UUID; v_q INTEGER; v_err BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'cinematic-smoke@noraplatforms.com';
  IF v_u IS NULL THEN
    RAISE NOTICE 'mig 144 smoke SKIPPED (no smoke user)';
    RETURN;
  END IF;

  v_c := public.create_moment_chit('mig144 smoke', 'athlete', 'creature', 'F');

  PERFORM public.chit_grant(v_u, v_c, 2, 'event');
  PERFORM public.chit_grant(v_u, v_c, -1, 'platform_correction');   -- the previously-broken path
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u AND chit_id = v_c;
  IF v_q <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: disposal must decrement (got %)', v_q; END IF;

  BEGIN
    PERFORM public.chit_grant(v_u, v_c, -5, 'platform_correction'); -- over-disposal still blocked
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: over-disposal must be blocked'; END IF;

  PERFORM public.chit_grant(v_u, v_c, -1, 'platform_correction');   -- zero out
  UPDATE public.moment_chits SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id = v_c;

  RAISE NOTICE 'mig 144 smoke OK: negative ledger deltas apply; over-disposal blocked';
END $$;
