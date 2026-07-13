-- 161: mint_jobs — async cinematic-mint job tracking (fix for edge-runtime 546).
--
-- cinematic-mint used to hold the HTTP request open through illustration →
-- cutscene → post-gen screening (minutes of provider calls) and the edge runtime
-- killed it at the resource/wall-clock limit (HTTP 546). The function now
-- validates synchronously, inserts a mint_jobs row, runs the pipeline in a
-- background task (EdgeRuntime.waitUntil) and returns 202 { job_id } at once.
-- The web client polls its own row (owner-scoped RLS SELECT) to drive the
-- progressive percentage loader; all writes stay service-side.

CREATE TABLE public.mint_jobs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  moment_id      UUID NOT NULL REFERENCES public.moments(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- pipeline position (drives the client progress bar)
  stage          TEXT NOT NULL DEFAULT 'queued' CHECK (stage IN (
                   'queued','illustration','card_art_stored','cutscene',
                   'cutscene_stored','screening','completing','done')),
  -- outcome
  status         TEXT NOT NULL DEFAULT 'running' CHECK (status IN (
                   'running','succeeded','held_moderation','rejected_moderation','failed')),
  generation_id  UUID REFERENCES public.cinematic_generations(id),
  chit_id        UUID,
  error          TEXT,          -- machine reason (generation_unavailable, ...)
  detail         TEXT,          -- human-readable detail for the client
  result         JSONB,         -- terminal payload (mirrors the old sync response)
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX mint_jobs_moment_idx ON public.mint_jobs (moment_id, created_at DESC);
CREATE INDEX mint_jobs_user_idx   ON public.mint_jobs (user_id, created_at DESC);

ALTER TABLE public.mint_jobs ENABLE ROW LEVEL SECURITY;

-- Owners may watch their own job; every write is service-role only (no
-- INSERT/UPDATE/DELETE policies on purpose).
CREATE POLICY mint_jobs_owner_select ON public.mint_jobs
  FOR SELECT USING (user_id = auth.uid());
