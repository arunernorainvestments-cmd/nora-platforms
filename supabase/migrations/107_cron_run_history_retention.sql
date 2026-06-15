-- Migration 107: Retention for pg_cron run history.
-- cron.job_run_details has no built-in cleanup. With ~22 jobs (several firing
-- every few seconds) it grew to 1.5M rows / 344 MB in ~2 months — 74% of the
-- database and the reason we crossed the storage limit. The live table was
-- TRUNCATEd during cleanup; this job keeps it from ballooning again.
--
-- Keeps a 2-day rolling window; runs daily at 04:00 UTC.
-- (net._http_response is auto-purged by pg_net's own TTL, so no job needed there.)

-- Unschedule if already exists (idempotent).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-cron-run-history') THEN
    PERFORM cron.unschedule('purge-cron-run-history');
  END IF;
END;
$$;

SELECT cron.schedule(
  'purge-cron-run-history',
  '0 4 * * *',
  $$ DELETE FROM cron.job_run_details WHERE end_time < now() - interval '2 days' $$
);
