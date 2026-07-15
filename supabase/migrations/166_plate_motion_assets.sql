-- 166: animated plate bookends (founder 2026-07-15, Phase 1b).
-- One-time-generated UNIVERSAL intro/outro transition clips that live alongside the
-- still anchor plates: the intro animates the start plate into a full-frame white
-- flash; the outro opens on that flash and settles into the end plate's impact VFX.
-- House-owned + versioned with the plates (Hard Rule 39) — never per card. NULL =
-- cinematic-mint falls back to animating the stills (zoompan) at compose time.
ALTER TABLE public.match_cut_anchor_plates
  ADD COLUMN IF NOT EXISTS start_motion_url TEXT,
  ADD COLUMN IF NOT EXISTS end_motion_url TEXT;
