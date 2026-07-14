-- 165: V2V core provenance on the generation ledger (PLAN 2026-07-14 item 1c + 2).
--
-- cinematic-mint can now produce the cutscene core by RESTYLING the user's trimmed
-- clip through a video-to-video provider (CINEMATIC_V2V_PROVIDER: kling-o3 |
-- runway-aleph) instead of riding it as a Seedance reference video. The ledger
-- records which pipeline produced each generation and what its audio actually is,
-- so the founder's provider/audio trials stay traceable (audit item 6 discipline).
--
--   v2v_provider  NULL = Seedance path (reference-video or prompt-only)
--   audio_source  'original'  = the clip's own soundtrack (Kling keep_audio, or the
--                               stitch-worker overlay on a silent Aleph core)
--                 'generated' = Seedance native audio co-generation (generate_audio)
--                 'none'      = silent cutscene

ALTER TABLE cinematic_generations
  ADD COLUMN IF NOT EXISTS v2v_provider TEXT
    CHECK (v2v_provider IS NULL OR v2v_provider IN ('kling-o3', 'runway-aleph')),
  ADD COLUMN IF NOT EXISTS audio_source TEXT
    CHECK (audio_source IS NULL OR audio_source IN ('original', 'generated', 'none'));

COMMENT ON COLUMN cinematic_generations.v2v_provider IS
  'V2V restyle provider that produced the cutscene core; NULL = Seedance path';
COMMENT ON COLUMN cinematic_generations.audio_source IS
  'Cutscene audio provenance: original clip soundtrack / provider-generated SFX / none';
