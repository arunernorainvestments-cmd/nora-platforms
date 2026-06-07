-- Migration 100: Map team_1/team_2 bets onto yes_pool/no_pool
--
-- Battle-outcome markets settle via distribute_match_revenue(), which pays
-- winners WHERE bets.position = 'team_1'/'team_2' and reads the pools as
-- team_1 = yes_pool, team_2 = no_pool. bets.position already allows
-- 'team_1'/'team_2' (migration 084), but the pool-update trigger
-- (handle_bet_pool_update, migration 004) only handled 'yes'/'no', so team
-- bets never accumulated into a pool and battle markets always voided
-- (v_total_pool = 0). Teach the trigger the team positions.
--
-- yes/no (creator display_score markets) behave exactly as before.

CREATE OR REPLACE FUNCTION public.handle_bet_pool_update()
RETURNS TRIGGER AS $$
BEGIN
  IF new.position = 'yes' OR new.position = 'team_1' THEN
    UPDATE public.markets
       SET yes_pool = yes_pool + new.amount
     WHERE id = new.market_id;
  ELSIF new.position = 'no' OR new.position = 'team_2' THEN
    UPDATE public.markets
       SET no_pool = no_pool + new.amount
     WHERE id = new.market_id;
  END IF;
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
