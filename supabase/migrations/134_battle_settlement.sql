-- Migration 134: battle market settlement + payout to moment-owners (Phase 5 — P5).
--
-- On match finish, split the USD pool (integer cents) per the ccg_* config keys:
--   predictors .80 (winning bettors, pro-rata) · winner_player .06 · loser_player .02
--   creator .02 → moment-OWNERS of chits actually PLAYED ("summon your friend, your friend
--   earns") · passive_holders .05 → holders of those played chits (pro-rata) · platform .05.
-- Idempotent (guards on market status). Runs via the settle trigger when a match finishes.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 5.

CREATE OR REPLACE FUNCTION public.ccg_settle_market(p_match_id UUID, p_winner_seat SMALLINT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_mkt        public.markets%ROWTYPE;
  v_pool       BIGINT;
  v_win_pos    TEXT;
  v_pred_pct   DECIMAL; v_winp_pct DECIMAL; v_losep_pct DECIMAL;
  v_cre_pct    DECIMAL; v_pas_pct DECIMAL;
  v_pred BIGINT; v_winp BIGINT; v_losep BIGINT; v_cre BIGINT; v_pas BIGINT; v_plat BIGINT;
  v_winner_user UUID; v_loser_user UUID;
  v_total_stake BIGINT;
  b RECORD; o RECORD;
  v_chits UUID[];
  v_owner_ct INTEGER; v_hold_total BIGINT;
BEGIN
  SELECT * INTO v_mkt FROM public.markets
   WHERE ccg_match_id = p_match_id AND resolution_type = 'battle_outcome' LIMIT 1;
  IF v_mkt.id IS NULL THEN RETURN; END IF;            -- non-monetized match
  IF v_mkt.status = 'resolved' THEN RETURN; END IF;   -- idempotent

  v_win_pos := CASE p_winner_seat WHEN 1 THEN 'team_1' ELSE 'team_2' END;
  v_pool := COALESCE(v_mkt.usd_yes_pool_cents,0) + COALESCE(v_mkt.usd_no_pool_cents,0);

  SELECT config_value INTO v_pred_pct  FROM public.match_revenue_config WHERE config_key='ccg_predictors_pct';
  SELECT config_value INTO v_winp_pct  FROM public.match_revenue_config WHERE config_key='ccg_winner_players_pct';
  SELECT config_value INTO v_losep_pct FROM public.match_revenue_config WHERE config_key='ccg_loser_players_pct';
  SELECT config_value INTO v_cre_pct   FROM public.match_revenue_config WHERE config_key='ccg_creator_pct';
  SELECT config_value INTO v_pas_pct   FROM public.match_revenue_config WHERE config_key='ccg_passive_holders_pct';

  v_pred  := FLOOR(v_pool * v_pred_pct)::BIGINT;
  v_winp  := FLOOR(v_pool * v_winp_pct)::BIGINT;
  v_losep := FLOOR(v_pool * v_losep_pct)::BIGINT;
  v_cre   := FLOOR(v_pool * v_cre_pct)::BIGINT;
  v_pas   := FLOOR(v_pool * v_pas_pct)::BIGINT;
  v_plat  := v_pool - v_pred - v_winp - v_losep - v_cre - v_pas;  -- remainder (rounding) → platform

  SELECT user_id INTO v_winner_user FROM public.ccg_match_players WHERE match_id=p_match_id AND seat=p_winner_seat;
  SELECT user_id INTO v_loser_user  FROM public.ccg_match_players WHERE match_id=p_match_id AND seat=public.ccg_other_seat(p_winner_seat);

  -- Predictors: winning bettors pro-rata by stake.
  SELECT COALESCE(SUM(ROUND(amount*100)),0) INTO v_total_stake
  FROM public.bets WHERE market_id=v_mkt.id AND currency='usd' AND position=v_win_pos AND status='active';

  IF v_total_stake > 0 THEN
    FOR b IN SELECT id, user_id, ROUND(amount*100)::BIGINT AS stake FROM public.bets
             WHERE market_id=v_mkt.id AND currency='usd' AND position=v_win_pos AND status='active' LOOP
      PERFORM public.ccg_usd_credit(b.user_id, FLOOR(v_pred * b.stake / v_total_stake)::BIGINT,
        v_mkt.id, 'CCG bet won', 'distribution');
      UPDATE public.bets SET status='won' WHERE id=b.id;
    END LOOP;
  ELSE
    v_plat := v_plat + v_pred;   -- no winners → predictors slice retained
  END IF;
  UPDATE public.bets SET status='lost'
    WHERE market_id=v_mkt.id AND currency='usd' AND position<>v_win_pos AND status='active';

  -- The two players.
  PERFORM public.ccg_usd_credit(v_winner_user, v_winp, v_mkt.id, 'CCG winner player', 'distribution');
  PERFORM public.ccg_usd_credit(v_loser_user,  v_losep, v_mkt.id, 'CCG loser player', 'distribution');

  -- Chits actually PLAYED (left hand → field/graveyard).
  v_chits := ARRAY(SELECT DISTINCT chit_id FROM public.ccg_match_cards
                   WHERE match_id=p_match_id AND zone NOT IN ('deck','hand'));

  -- Creator slice → distinct moment-owners of the played chits, split equally.
  SELECT COUNT(*) INTO v_owner_ct FROM (
    SELECT DISTINCT m.owner_user_id FROM public.moment_chits mc
    JOIN public.moments m ON m.id = mc.moment_id
    WHERE mc.id = ANY(v_chits) AND m.owner_user_id IS NOT NULL) s;
  IF v_owner_ct > 0 THEN
    FOR o IN SELECT DISTINCT m.owner_user_id AS uid FROM public.moment_chits mc
             JOIN public.moments m ON m.id = mc.moment_id
             WHERE mc.id = ANY(v_chits) AND m.owner_user_id IS NOT NULL LOOP
      PERFORM public.ccg_usd_credit(o.uid, FLOOR(v_cre / v_owner_ct)::BIGINT, v_mkt.id,
        'CCG creator royalty (moment owner)', 'distribution');
    END LOOP;
  ELSE
    v_plat := v_plat + v_cre;    -- no moment owners → retained
  END IF;

  -- Passive slice → holders of the played chits, pro-rata by quantity held.
  SELECT COALESCE(SUM(quantity),0) INTO v_hold_total FROM public.chit_ownership
   WHERE chit_id = ANY(v_chits) AND quantity > 0;
  IF v_hold_total > 0 THEN
    FOR o IN SELECT user_id AS uid, SUM(quantity) AS q FROM public.chit_ownership
             WHERE chit_id = ANY(v_chits) AND quantity > 0 GROUP BY user_id LOOP
      PERFORM public.ccg_usd_credit(o.uid, FLOOR(v_pas * o.q / v_hold_total)::BIGINT, v_mkt.id,
        'CCG passive holder', 'distribution');
    END LOOP;
  ELSE
    v_plat := v_plat + v_pas;    -- no holders → retained
  END IF;

  -- Platform slice: retained (burned) — no user credit, matching legacy behavior.

  UPDATE public.markets
    SET status='resolved', resolved_outcome=(p_winner_seat=1), resolution_result=v_win_pos
    WHERE id=v_mkt.id;
END;
$$;

-- ── settle when a match finishes ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ccg_settle_on_finish()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'finished' AND NEW.winner_seat IS NOT NULL THEN
    -- Never let a settlement error roll back the match result (mirrors the legacy
    -- distribute_match_revenue guard). Market stays unresolved → safe to re-settle.
    BEGIN
      PERFORM public.ccg_settle_market(NEW.id, NEW.winner_seat);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'ccg_settle_market failed for match %: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ccg_matches_settle ON public.ccg_matches;
CREATE TRIGGER ccg_matches_settle
  AFTER UPDATE ON public.ccg_matches
  FOR EACH ROW WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.ccg_settle_on_finish();

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: config keys sum to 1.0; battle_payments_mode defaults sim; the
-- G-MON gate returns NULL (non-monetized) for a match whose seats aren't both KYC'd.
-- (Full payout round-trip needs 2 KYC'd users + sim USD — a test-account pass.)
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_sum NUMERIC; v_mode TEXT; v_match UUID; v_mkt UUID;
BEGIN
  SELECT SUM(config_value) INTO v_sum FROM public.match_revenue_config WHERE config_key LIKE 'ccg_%';
  IF v_sum <> 1.0 THEN RAISE EXCEPTION 'SMOKE FAIL: ccg payout split must sum to 1.0 (got %)', v_sum; END IF;

  SELECT public.battle_payments_mode() INTO v_mode;
  IF v_mode <> 'sim' THEN RAISE EXCEPTION 'SMOKE FAIL: expected sim mode, got %', v_mode; END IF;

  INSERT INTO public.ccg_matches (is_test, active_seat, turn_number) VALUES (TRUE,1,1) RETURNING id INTO v_match;
  INSERT INTO public.ccg_match_players (match_id, seat, life) VALUES (v_match,1,30),(v_match,2,30);  -- null users
  v_mkt := public.ccg_create_outcome_market(v_match);
  IF v_mkt IS NOT NULL THEN RAISE EXCEPTION 'SMOKE FAIL: G-MON should return NULL for non-KYC match'; END IF;

  DELETE FROM public.ccg_matches WHERE id = v_match;
  RAISE NOTICE 'P5 smoke OK: split sums 1.0, mode sim, G-MON gated non-KYC match to non-monetized';
END $$;
