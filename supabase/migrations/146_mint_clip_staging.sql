-- Migration 146: minting v2 — device-clip staging (Minting_Workflow.md §1).
--
-- Hard Rule 37 (amended 2026-07-04): platform APIs cannot hand us the video file,
-- so after moment-ingest verifies OAuth ownership of the selected post, the user
-- uploads the clip from their device (trimmed in-browser to 1–15s). The upload is
-- TETHERED to that approved moment — it is not an arbitrary-upload path:
--   * the clip lands in the private `mint-staging` bucket under {uid}/{moment_id}/,
--     writable only by the owner (storage RLS below), never publicly readable;
--   * moment-clip-attach re-moderates the sampled frames of the ACTUAL upload and
--     runs a thumbnail-vs-frame similarity check (post-swap defense) before the
--     clip is accepted;
--   * generation (pipeline v2) only ever consumes clips with clip_status='attached'.
--
-- Client flow: moment-ingest (approved) → browser trim (ffmpeg.wasm) → upload
-- clip.mp4 + f0..f3.jpg → moment-clip-attach → moment_attach_clip (here).

-- ── moments: staged-clip fields ─────────────────────────────────────────────────
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS raw_clip_path        TEXT,        -- mint-staging object path
  ADD COLUMN IF NOT EXISTS clip_frame_paths     TEXT[],      -- moderation sample frames (jpg)
  ADD COLUMN IF NOT EXISTS clip_trim_start_ms   INTEGER,     -- selection in the ORIGINAL file
  ADD COLUMN IF NOT EXISTS clip_trim_end_ms     INTEGER,
  ADD COLUMN IF NOT EXISTS clip_keep_audio      BOOLEAN,
  ADD COLUMN IF NOT EXISTS clip_status          TEXT
    CHECK (clip_status IN ('attached','similarity_flagged','rejected')),
  ADD COLUMN IF NOT EXISTS clip_attached_at     TIMESTAMPTZ;

COMMENT ON COLUMN public.moments.raw_clip_path IS
  'Device-uploaded trimmed clip in the private mint-staging bucket (Hard Rule 37 as '
  'amended: upload tethered to the OAuth-verified post). Pipeline-v2 generation input; '
  'only meaningful while clip_status = attached.';
COMMENT ON COLUMN public.moments.clip_status IS
  'attached = accepted for generation; similarity_flagged = frames did not match the '
  'post thumbnail (human review via moderation_escalations); rejected = failed post-'
  'upload moderation. NULL = no clip staged yet.';

-- ── mint-staging bucket (PRIVATE — cf. battle-media which is public) ─────────────
-- 200MB cap: a 15s 1280-long-edge H.264 clip is well under this; the cap only guards
-- against abuse. jpeg allowed for the moderation sample frames.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('mint-staging', 'mint-staging', FALSE, 209715200,
        ARRAY['video/mp4','image/jpeg'])
ON CONFLICT (id) DO NOTHING;

-- Owner-prefix RLS on storage.objects: authenticated users manage ONLY their own
-- {uid}/... prefix. No public read; the pipeline reads with the service role.
CREATE POLICY "mint_staging_insert_own" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'mint-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "mint_staging_update_own" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'mint-staging' AND (storage.foldername(name))[1] = auth.uid()::text)
  WITH CHECK (bucket_id = 'mint-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "mint_staging_select_own" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'mint-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "mint_staging_delete_own" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'mint-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

-- ── moment_attach_clip: the single write path (service-only) ─────────────────────
-- Called by the moment-clip-attach edge function AFTER it has (a) verified the
-- storage objects exist under the caller's prefix, (b) re-run pre-gen moderation on
-- the sampled frames, (c) run the thumbnail-similarity check. p_verdict carries the
-- outcome; a non-'attached' verdict still records the paths so review/cleanup can
-- find the objects.
CREATE FUNCTION public.moment_attach_clip(
  p_moment_id     UUID,
  p_owner         UUID,
  p_clip_path     TEXT,
  p_frame_paths   TEXT[],
  p_trim_start_ms INTEGER,
  p_trim_end_ms   INTEGER,
  p_keep_audio    BOOLEAN,
  p_verdict       TEXT,                 -- 'attached' | 'similarity_flagged' | 'rejected'
  p_labels        JSONB DEFAULT NULL    -- moderation/similarity detail for escalations
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_status TEXT;
BEGIN
  IF p_verdict NOT IN ('attached','similarity_flagged','rejected') THEN
    RAISE EXCEPTION 'Invalid clip verdict: %', p_verdict;
  END IF;
  IF p_trim_end_ms - p_trim_start_ms NOT BETWEEN 1000 AND 15000
     OR p_trim_start_ms < 0 THEN
    RAISE EXCEPTION 'Clip selection must be 1–15 seconds';
  END IF;

  SELECT moderation_status INTO v_status
  FROM public.moments WHERE id = p_moment_id AND owner_user_id = p_owner;
  IF NOT FOUND THEN RAISE EXCEPTION 'Moment not found for owner: %', p_moment_id; END IF;
  -- Pre-gen moderation of the SOURCE must already have approved (mig 141); the clip
  -- is an addition to an approved moment, never a bypass of that gate.
  IF v_status <> 'approved' THEN
    RAISE EXCEPTION 'Moment % is not moderation-approved', p_moment_id;
  END IF;

  UPDATE public.moments
  SET raw_clip_path      = p_clip_path,
      clip_frame_paths   = p_frame_paths,
      clip_trim_start_ms = p_trim_start_ms,
      clip_trim_end_ms   = p_trim_end_ms,
      clip_keep_audio    = COALESCE(p_keep_audio, TRUE),
      clip_status        = p_verdict,
      clip_attached_at   = NOW()
  WHERE id = p_moment_id;

  -- Flagged clips queue for human review (same queue as mig 141; 'other' reason —
  -- the labels carry the similarity/moderation detail).
  IF p_verdict = 'similarity_flagged' THEN
    INSERT INTO public.moderation_escalations (moment_id, reason, labels)
    VALUES (p_moment_id, 'other', COALESCE(p_labels, '{"clip_similarity_mismatch": true}'::JSONB));
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.moment_attach_clip(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, BOOLEAN, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: bucket exists + is private; attach requires approved moment;
-- window bounds enforced; similarity flag queues review.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID;
  v_moment UUID;
  v_err BOOLEAN := FALSE;
  v_public BOOLEAN;
  v_status TEXT;
  v_n INT;
BEGIN
  SELECT public INTO v_public FROM storage.buckets WHERE id = 'mint-staging';
  IF v_public IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'SMOKE FAIL: mint-staging must exist and be private';
  END IF;

  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'mint-clip smoke SKIPPED (no auth user in this environment)';
    RETURN;
  END IF;

  v_moment := public.moment_record(v_user, 'youtube', 'clip-smoke-' || gen_random_uuid()::TEXT,
                                   'https://example.com/post', NULL, 1000, TRUE, '@smoke');

  -- Attach before moderation approval must raise.
  BEGIN
    PERFORM public.moment_attach_clip(v_moment, v_user, v_user::text || '/' || v_moment::text || '/clip.mp4',
      ARRAY[]::TEXT[], 0, 5000, TRUE, 'attached');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: attach must require approved moment'; END IF;

  PERFORM public.moment_pre_gen_moderate(v_moment, 'approved', NULL, FALSE, 'sim');

  -- 16s selection must raise.
  v_err := FALSE;
  BEGIN
    PERFORM public.moment_attach_clip(v_moment, v_user, 'p', ARRAY[]::TEXT[], 0, 16000, TRUE, 'attached');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: >15s selection must be rejected'; END IF;

  -- Happy path + similarity flag queues review.
  PERFORM public.moment_attach_clip(v_moment, v_user, v_user::text || '/' || v_moment::text || '/clip.mp4',
    ARRAY[v_user::text || '/' || v_moment::text || '/f0.jpg'], 2000, 9000, FALSE, 'similarity_flagged',
    '{"clip_similarity_mismatch": true, "distance": 24}'::JSONB);
  SELECT clip_status INTO v_status FROM public.moments WHERE id = v_moment;
  IF v_status <> 'similarity_flagged' THEN RAISE EXCEPTION 'SMOKE FAIL: clip_status not recorded'; END IF;
  SELECT COUNT(*) INTO v_n FROM public.moderation_escalations
  WHERE moment_id = v_moment AND reason = 'other' AND status = 'open';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: similarity flag must queue review'; END IF;

  DELETE FROM public.moments WHERE id = v_moment;

  RAISE NOTICE 'mint-clip smoke OK: private bucket + approval gate + window bounds + review queue';
END $$;
