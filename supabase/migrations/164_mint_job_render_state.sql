-- Migration 164: survivable cutscene rendering.
--
-- Live trial 2026-07-13 (clip-referenced Seedance render): V2V renders can outlive
-- the edge-runtime background-task wall clock. The worker died mid-await on the
-- synchronous provider call, the job froze at stage 'cutscene', and the paid render
-- (which kept going provider-side) was unrecoverable because its request id lived
-- only in the dead worker's memory.
--
-- Fix (code side, cinematic-mint): live cutscenes now use Segmind's async v2 API —
-- submit → persist request_id on the job IMMEDIATELY → poll. If the worker dies, the
-- next cinematic-mint call for the moment finds the stale job with a stashed
-- request_id and RESUMES polling the same provider request — zero new spend
-- (results are retained provider-side for 1 hour).
--
-- DB side: a new non-terminal stage + the stash column.

ALTER TABLE public.mint_jobs DROP CONSTRAINT IF EXISTS mint_jobs_stage_check;
ALTER TABLE public.mint_jobs
  ADD CONSTRAINT mint_jobs_stage_check CHECK (stage IN (
    'queued','illustration','card_art_stored','cutscene','cutscene_rendering',
    'cutscene_stored','screening','completing','done'));

ALTER TABLE public.mint_jobs
  ADD COLUMN IF NOT EXISTS provider_state JSONB;

COMMENT ON COLUMN public.mint_jobs.provider_state IS
  'Render-in-flight stash (async provider request id, art paths, prompts, seed) so a '
  'killed background worker can be resumed by a later call with zero re-spend.';

DO $$
BEGIN
  RAISE NOTICE 'mint-job render-state smoke OK: cutscene_rendering stage + provider_state column in place';
END $$;
