-- Migration 133: currency-branched betting + G-MON market gating (Phase 5 — P5).
--
-- The three bet AFTER-INSERT triggers (mig 004) and the notify trigger are branched on
-- `currency`. Token path is preserved BYTE-FOR-BYTE (currency defaults 'token'); the usd
-- branch routes to the USD rail (mig 132). A new BEFORE-INSERT ccg integrity trigger
-- enforces one-role-per-match + eligibility for USD bets WITHOUT weakening the mig-102
-- trigger (Hard Rule 26). USD bet.amount is dollars (numeric) → cents = ROUND(amount*100).
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 5.

-- ── pool update: add the usd branch (preserve token/team logic from mig 100) ────
CREATE OR REPLACE FUNCTION public.handle_bet_pool_update()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF new.currency = 'usd' THEN
    IF new.position IN ('yes','team_1') THEN
      UPDATE public.markets SET usd_yes_pool_cents = usd_yes_pool_cents + ROUND(new.amount*100)::BIGINT
        WHERE id = new.market_id;
    ELSIF new.position IN ('no','team_2') THEN
      UPDATE public.markets SET usd_no_pool_cents = usd_no_pool_cents + ROUND(new.amount*100)::BIGINT
        WHERE id = new.market_id;
    END IF;
    RETURN new;
  END IF;

  -- token (unchanged, mig 100)
  IF new.position = 'yes' OR new.position = 'team_1' THEN
    UPDATE public.markets SET yes_pool = yes_pool + new.amount WHERE id = new.market_id;
  ELSIF new.position = 'no' OR new.position = 'team_2' THEN
    UPDATE public.markets SET no_pool = no_pool + new.amount WHERE id = new.market_id;
  END IF;
  RETURN new;
END;
$$;

-- ── deduction: usd debits the USD rail; token unchanged ─────────────────────────
CREATE OR REPLACE FUNCTION public.handle_bet_token_deduction()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF new.currency = 'usd' THEN
    PERFORM public.ccg_usd_debit(new.user_id, ROUND(new.amount*100)::BIGINT, new.id, 'CCG battle bet');
    RETURN new;
  END IF;

  -- token (unchanged, mig 004)
  UPDATE public.token_balances
     SET available_tokens = available_tokens - new.amount::integer,
         lifetime_spent   = lifetime_spent   + new.amount::integer, updated_at = now()
   WHERE user_id = new.user_id AND available_tokens >= new.amount::integer;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient token balance'; END IF;
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (new.user_id, 'bet_placed', new.amount::integer, new.id, 'Bet placed on market');
  RETURN new;
END;
$$;

-- ── notify: skip for usd / null creator (ccg markets have no creator) ────────────
CREATE OR REPLACE FUNCTION public.handle_bet_notify_creator()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_creator_id UUID; v_timeframe TEXT; v_bettor_name TEXT;
BEGIN
  SELECT creator_id, timeframe INTO v_creator_id, v_timeframe FROM public.markets WHERE id = new.market_id;
  IF new.currency = 'usd' OR v_creator_id IS NULL OR v_creator_id = new.user_id THEN RETURN new; END IF;
  SELECT COALESCE(username,'someone') INTO v_bettor_name FROM public.profiles WHERE id = new.user_id;
  INSERT INTO public.notifications (user_id, type, title, body, reference_id)
  VALUES (v_creator_id, 'market_opened', 'New market on your profile',
    '@' || v_bettor_name || ' opened a ' || v_timeframe || ' market on your popularity', new.market_id);
  RETURN new;
END;
$$;

-- ── ccg bet integrity (one-role + eligibility) — additive, never weakens mig 102 ─
CREATE OR REPLACE FUNCTION public.enforce_ccg_bet_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_match UUID; v_status TEXT;
BEGIN
  IF NEW.currency <> 'usd' THEN RETURN NEW; END IF;
  SELECT ccg_match_id, status INTO v_match, v_status FROM public.markets WHERE id = NEW.market_id;
  IF v_match IS NULL THEN RAISE EXCEPTION 'USD bets are only allowed on battle markets'; END IF;
  IF v_status <> 'open' THEN RAISE EXCEPTION 'Market is not open'; END IF;
  IF EXISTS (SELECT 1 FROM public.ccg_match_players WHERE match_id = v_match AND user_id = NEW.user_id) THEN
    RAISE EXCEPTION 'Combatants cannot bet on their own match (one role per match — Hard Rule 26)';
  END IF;
  IF NOT public.is_eligible_for_real_money(NEW.user_id) THEN
    RAISE EXCEPTION 'Not eligible for real-money betting (KYC / age / jurisdiction)';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_ccg_bet_integrity ON public.bets;
CREATE TRIGGER trg_enforce_ccg_bet_integrity
  BEFORE INSERT ON public.bets
  FOR EACH ROW EXECUTE FUNCTION public.enforce_ccg_bet_integrity();

-- ── G-MON: create a real-money market IFF both players are KYC-verified ──────────
CREATE OR REPLACE FUNCTION public.ccg_create_outcome_market(p_match_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_s1 UUID; v_s2 UUID; v_mkt UUID;
BEGIN
  SELECT user_id INTO v_s1 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 1;
  SELECT user_id INTO v_s2 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 2;

  -- G-MON gate (decision gate — confirm before live): both must be KYC'd, else non-monetized.
  IF v_s1 IS NULL OR v_s2 IS NULL
     OR NOT public.is_kyc_verified(v_s1) OR NOT public.is_kyc_verified(v_s2) THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_mkt FROM public.markets WHERE ccg_match_id = p_match_id LIMIT 1;
  IF v_mkt IS NOT NULL THEN RETURN v_mkt; END IF;

  INSERT INTO public.markets (title, market_type, target_metric, timeframe, end_at,
    resolution_type, currency, ccg_match_id, status)
  VALUES ('Battle outcome', 'battle_outcome', 'battle_outcome', '24h', NOW() + INTERVAL '1 day',
    'battle_outcome', 'usd', p_match_id, 'open')
  RETURNING id INTO v_mkt;
  RETURN v_mkt;
END;
$$;

-- ── place a USD battle bet (thin wrapper; triggers do the money work) ────────────
-- p_position: 'team_1' (seat 1) | 'team_2' (seat 2). p_amount_dollars: numeric USD.
CREATE OR REPLACE FUNCTION public.ccg_place_bet(p_market_id UUID, p_position TEXT, p_amount_dollars NUMERIC)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bet UUID; v_match UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_position NOT IN ('team_1','team_2') THEN RAISE EXCEPTION 'position must be team_1 or team_2'; END IF;
  IF p_amount_dollars <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;

  INSERT INTO public.bets (market_id, user_id, position, amount, currency, status)
  VALUES (p_market_id, auth.uid(), p_position, p_amount_dollars, 'usd', 'active')
  RETURNING id INTO v_bet;

  SELECT ccg_match_id INTO v_match FROM public.markets WHERE id = p_market_id;
  PERFORM public.ccg_record_vibe_signal(v_match, 'market_bet', GREATEST(ROUND(p_amount_dollars)::INTEGER,1));
  RETURN v_bet;
END;
$$;
