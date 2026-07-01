-- Migration 132: real-money rail config + currency model (Phase 5 — P5).
--
-- Built "like live" but SIMULATED behind one switch: platform_integrity_settings
-- .battle_payments_mode ('sim'|'live', default 'sim'). In sim, USD flows against
-- sim_usd_balances (mig 073); flipping to 'live' routes to Stripe Treasury (stub — the
-- live branch RAISEs until the two P5 prereqs land: merge doc6-mobile-iap-confirm/mig 115
-- + rotate NORA_SIGNING_PRIVATE_KEY). All USD is integer cents.
--
-- Hard Rule 33: Battle markets settle USD, Markets settle tokens — never cross.
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 5.

-- ── the switch ──────────────────────────────────────────────────────────────────
ALTER TABLE public.platform_integrity_settings
  ADD COLUMN IF NOT EXISTS battle_payments_mode TEXT NOT NULL DEFAULT 'sim'
    CHECK (battle_payments_mode IN ('sim','live'));

CREATE OR REPLACE FUNCTION public.battle_payments_mode()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT battle_payments_mode FROM public.platform_integrity_settings WHERE id = TRUE;
$$;

-- ── currency model on markets + bets ────────────────────────────────────────────
ALTER TABLE public.markets
  ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'token' CHECK (currency IN ('token','usd')),
  ADD COLUMN IF NOT EXISTS ccg_match_id UUID REFERENCES public.ccg_matches(id),
  ADD COLUMN IF NOT EXISTS usd_yes_pool_cents BIGINT NOT NULL DEFAULT 0,  -- team_1
  ADD COLUMN IF NOT EXISTS usd_no_pool_cents  BIGINT NOT NULL DEFAULT 0;  -- team_2

ALTER TABLE public.bets
  ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'token' CHECK (currency IN ('token','usd'));

CREATE INDEX IF NOT EXISTS markets_ccg_match_idx ON public.markets (ccg_match_id);

-- ── real-money eligibility (KYC always; age+jurisdiction at live) ────────────────
CREATE OR REPLACE FUNCTION public.is_eligible_for_real_money(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.is_kyc_verified(p_user_id) THEN RETURN FALSE; END IF;
  IF public.battle_payments_mode() = 'sim' THEN RETURN TRUE; END IF;
  -- live: 18+ and a known jurisdiction on the verified KYC row.
  RETURN EXISTS (
    SELECT 1 FROM public.kyc_verifications
    WHERE user_id = p_user_id AND status = 'approved'
      AND date_of_birth IS NOT NULL AND date_of_birth <= (NOW() - INTERVAL '18 years')
      AND verified_address_country IS NOT NULL);
END;
$$;

-- ── USD rail: sim (sim_usd_balances) now; live (Treasury) behind the switch ───────
CREATE OR REPLACE FUNCTION public.ccg_usd_debit(p_user UUID, p_cents BIGINT, p_ref UUID, p_desc TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_cents <= 0 THEN RETURN; END IF;
  IF public.battle_payments_mode() = 'live' THEN
    RAISE EXCEPTION 'Live Treasury payments are not enabled yet (flip battle_payments_mode once prereqs land)';
  END IF;
  PERFORM public.sim_seed_balance(p_user);
  UPDATE public.sim_usd_balances
    SET balance_usd_cents = balance_usd_cents - p_cents,
        lifetime_invested_cents = lifetime_invested_cents + p_cents, updated_at = NOW()
    WHERE user_id = p_user AND balance_usd_cents >= p_cents;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient simulated USD balance'; END IF;
  INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, reference_id, description)
    VALUES (p_user, 'investment', -p_cents, p_ref, p_desc);
END;
$$;

CREATE OR REPLACE FUNCTION public.ccg_usd_credit(p_user UUID, p_cents BIGINT, p_ref UUID, p_desc TEXT, p_type TEXT DEFAULT 'distribution')
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_cents <= 0 OR p_user IS NULL THEN RETURN; END IF;
  IF public.battle_payments_mode() = 'live' THEN
    RAISE EXCEPTION 'Live Treasury payouts are not enabled yet (flip battle_payments_mode once prereqs land)';
  END IF;
  PERFORM public.sim_seed_balance(p_user);
  UPDATE public.sim_usd_balances
    SET balance_usd_cents = balance_usd_cents + p_cents,
        lifetime_returned_cents = lifetime_returned_cents + p_cents, updated_at = NOW()
    WHERE user_id = p_user;
  INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, reference_id, description)
    VALUES (p_user, p_type, p_cents, p_ref, p_desc);
END;
$$;

-- ── payout split keys (ccg_-namespaced so legacy distribute_match_revenue is untouched) ─
INSERT INTO public.match_revenue_config (config_key, config_value, description) VALUES
  ('ccg_predictors_pct',      0.8000, 'CCG: winning bettors, proportional to stake'),
  ('ccg_winner_players_pct',  0.0600, 'CCG: the winning player'),
  ('ccg_loser_players_pct',   0.0200, 'CCG: the losing player'),
  ('ccg_creator_pct',         0.0200, 'CCG: moment-owners of chits PLAYED (summon your friend, your friend earns)'),
  ('ccg_passive_holders_pct', 0.0500, 'CCG: holders of the played chits, proportional'),
  ('ccg_platform_pct',        0.0500, 'CCG: platform fee')
ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value, description = EXCLUDED.description;
