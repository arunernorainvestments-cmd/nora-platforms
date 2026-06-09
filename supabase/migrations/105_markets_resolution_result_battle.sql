-- ─────────────────────────────────────────────────────────────────────────────
-- 105 — markets_resolution_result_check allow battle outcomes  [BUGFIX]
--
-- distribute_match_revenue (091) settles a battle_outcome market with
-- resolution_result = 'team_1' | 'team_2', but markets_resolution_result_check
-- (009) only allowed 'above' | 'below' | 'refund' (display-score outcomes). The
-- final UPDATE in distribute_match_revenue therefore violated the check and the
-- whole settlement rolled back — masked by process_battle_turn's
-- EXCEPTION WHEN OTHERS (match resolved, market left 'open', bettors unpaid).
--
-- Surfaced by supabase/tests/battle_market_pipeline_smoke.sql after the 104 fix.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.markets DROP CONSTRAINT IF EXISTS markets_resolution_result_check;

ALTER TABLE public.markets ADD CONSTRAINT markets_resolution_result_check
  CHECK (resolution_result = ANY (ARRAY[
    'above'::text, 'below'::text, 'refund'::text,  -- display_score markets
    'team_1'::text, 'team_2'::text                  -- battle_outcome markets
  ]));
