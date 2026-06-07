-- Migration 098: Add ubi_pool_balance_cache to Realtime publication
--
-- The Emergency Fund pool balance is shown live on the Home Community card
-- and on EmergencyFundScreen via Flutter .stream(). Without the table in the
-- supabase_realtime publication, .stream() only delivers the initial snapshot
-- and never reflects increment_ubi_sim_balance / decrement_ubi_sim_balance
-- updates (contributions, disbursements). Add it so the balance updates live.
--
-- Public SELECT is already allowed (migration 093 "ubi_pool_balance_public_read"),
-- so no individual votes or private data are exposed by this change.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'ubi_pool_balance_cache'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ubi_pool_balance_cache;
  END IF;
END $$;
