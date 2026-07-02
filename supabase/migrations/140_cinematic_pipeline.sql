-- Migration 140: C2 — cinematic generation pipeline backend.
--
-- The DB owns the invariants of the generation flow (cinematic spec §3 steps 2–7):
--   audit ledger per generation attempt → post-gen moderation gate → completed mint
--   (chit + cinematic fields + ownership grant) → user preview → finalize.
-- The edge function `cinematic-mint` orchestrates providers/storage; nothing here
-- trusts it: completion re-checks moderation, version FKs pin plates/prompts, and
-- the preview gate keeps the chit out of decks (is_active=false) until finalized.
-- Hard Rules 37–39.

-- ── cinematic_generations: audit + re-run ledger (one row per attempt) ────────────
CREATE TABLE public.cinematic_generations (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  moment_id                UUID NOT NULL REFERENCES public.moments(id),
  chit_id                  UUID REFERENCES public.moment_chits(id),

  template_id              TEXT NOT NULL REFERENCES public.match_cut_templates(id),
  anchor_plate_version     INTEGER NOT NULL,
  prompt_template_version  INTEGER NOT NULL,

  -- The three filled slots (everything else in the prompt is fixed — Hard Rule 39).
  subject_desc             TEXT NOT NULL,
  family_action            TEXT NOT NULL,
  tier_intensity           TEXT NOT NULL,

  generation_seed          BIGINT NOT NULL,
  render_tier              TEXT NOT NULL CHECK (render_tier IN ('fast','standard')),
  mode                     TEXT NOT NULL CHECK (mode IN ('sim','live')),
  attempt                  INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),

  -- Post-gen moderation gate on the finished MP4 — clean bookends never vouch for
  -- the middle. Reject → re-run adjusts subject_desc ONLY, seed fixed (new row).
  status                   TEXT NOT NULL DEFAULT 'generated'
    CHECK (status IN ('generated','moderation_approved','moderation_rejected','stored')),
  reject_reason            TEXT,

  illustration_path        TEXT,   -- battle-media object paths, never provider URLs
  mp4_path                 TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  FOREIGN KEY (template_id, anchor_plate_version)
    REFERENCES public.match_cut_anchor_plates(template_id, version),
  FOREIGN KEY (template_id, prompt_template_version)
    REFERENCES public.match_cut_prompt_templates(template_id, version)
);

CREATE INDEX cinematic_generations_moment_idx ON public.cinematic_generations (moment_id, created_at DESC);
CREATE INDEX cinematic_generations_status_idx ON public.cinematic_generations (status);

COMMENT ON TABLE public.cinematic_generations IS
  'One row per cutscene generation attempt (cinematic spec §3). Post-gen moderation '
  'verdict lives here; a rejected attempt re-runs with adjusted subject_desc and the '
  'SAME seed. Paths are battle-media objects — provider URLs never persist (HR 38).';

-- ── preview gate fields on the chit ────────────────────────────────────────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS previewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS finalized_at TIMESTAMPTZ;

-- Owners can see their own chits even while inactive (pending preview / retired).
CREATE POLICY "moment_chits_select_owned" ON public.moment_chits
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.chit_ownership co
      WHERE co.chit_id = moment_chits.id AND co.user_id = auth.uid() AND co.quantity > 0
    )
  );

-- ── moderation verdict (service-side; sim auto-approves, live may queue a human) ──
CREATE OR REPLACE FUNCTION public.cinematic_moderation_verdict(
  p_generation_id UUID, p_approved BOOLEAN, p_reason TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.cinematic_generations
  SET status = CASE WHEN p_approved THEN 'moderation_approved' ELSE 'moderation_rejected' END,
      reject_reason = CASE WHEN p_approved THEN NULL ELSE COALESCE(p_reason, 'unspecified') END
  WHERE id = p_generation_id AND status = 'generated';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Generation % not found or not pending moderation', p_generation_id;
  END IF;
END;
$$;

-- ── complete the mint: chit + cinematic fields + ownership, gated on moderation ───
CREATE OR REPLACE FUNCTION public.cinematic_complete_mint(
  p_generation_id      UUID,
  p_family             TEXT,
  p_chit_type          TEXT,
  p_timing             TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_name               TEXT DEFAULT NULL,
  p_keywords           TEXT[] DEFAULT '{}',
  p_vibe_gate          INTEGER DEFAULT NULL,
  p_card_art_url       TEXT DEFAULT NULL,
  p_mp4_url            TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_gen  public.cinematic_generations%ROWTYPE;
  v_m    public.moments%ROWTYPE;
  v_chit UUID;
BEGIN
  SELECT * INTO v_gen FROM public.cinematic_generations WHERE id = p_generation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Generation not found: %', p_generation_id; END IF;
  -- Post-gen moderation is mandatory (Hard Rule 39) — no verdict, no chit.
  IF v_gen.status <> 'moderation_approved' THEN
    RAISE EXCEPTION 'Generation % is not moderation_approved (status: %)', p_generation_id, v_gen.status;
  END IF;
  IF v_gen.chit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Generation % already completed into chit %', p_generation_id, v_gen.chit_id;
  END IF;
  -- battle-media only (Hard Rule 38).
  IF p_mp4_url IS NULL OR position('/battle-media/' IN p_mp4_url) = 0 THEN
    RAISE EXCEPTION 'mp4 url must be a battle-media object';
  END IF;

  SELECT * INTO v_m FROM public.moments WHERE id = v_gen.moment_id;

  -- moment_mint re-checks consent + pre-gen moderation + not-already-minted (mig 135)
  -- and derives tier from CURRENT engagement (Hard Rule 34).
  v_chit := public.moment_mint(
    v_gen.moment_id, p_family, p_chit_type, p_timing, p_effect_template_id,
    p_name, p_keywords, p_vibe_gate, v_gen.mp4_path);

  -- Cinematic contract fields + preview gate (inactive until the user finalizes —
  -- deck validation (mig 118) excludes inactive chits, so a pending chit can't play).
  UPDATE public.moment_chits
  SET match_cut_template_id   = v_gen.template_id,
      anchor_plate_version    = v_gen.anchor_plate_version,
      prompt_template_version = v_gen.prompt_template_version,
      generation_seed         = v_gen.generation_seed,
      mp4_cutscene_url        = p_mp4_url,
      card_art_url            = COALESCE(p_card_art_url, card_art_url),
      original_minter_handle  = v_m.creator_handle,
      source_platform         = v_m.source_platform,
      is_active               = FALSE
  WHERE id = v_chit;

  -- Ownership: the minter gets the copy (append-only ledger → holdings).
  PERFORM public.chit_grant(v_m.owner_user_id, v_chit, 1, 'mint', v_gen.moment_id);

  UPDATE public.cinematic_generations
  SET chit_id = v_chit, status = 'stored'
  WHERE id = p_generation_id;

  RETURN v_chit;
END;
$$;

-- ── preview hook + finalize (owner-called; the chit goes live only after preview) ──
CREATE OR REPLACE FUNCTION public.chit_record_preview(p_chit_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.moment_chits mc
  SET previewed_at = COALESCE(mc.previewed_at, NOW())
  WHERE mc.id = p_chit_id
    AND mc.finalized_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.chit_ownership co
      WHERE co.chit_id = mc.id AND co.user_id = auth.uid() AND co.quantity > 0
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chit not found, not yours, or already finalized';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.chit_finalize_preview(p_chit_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.moment_chits mc
  SET is_active = TRUE, finalized_at = NOW()
  WHERE mc.id = p_chit_id
    AND mc.finalized_at IS NULL
    AND mc.previewed_at IS NOT NULL     -- the preview-battle hook: no preview, no finalize
    AND EXISTS (
      SELECT 1 FROM public.chit_ownership co
      WHERE co.chit_id = mc.id AND co.user_id = auth.uid() AND co.quantity > 0
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chit not found, not yours, not previewed yet, or already finalized';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cinematic_moderation_verdict(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cinematic_complete_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chit_record_preview(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chit_finalize_preview(UUID) TO authenticated;

-- ── RLS ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.cinematic_generations ENABLE ROW LEVEL SECURITY;

-- Owners may watch their own generation status; all writes are service-side.
CREATE POLICY "cinematic_generations_select_own" ON public.cinematic_generations
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.moments m
            WHERE m.id = cinematic_generations.moment_id AND m.owner_user_id = auth.uid())
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: moderation gate blocks completion; verdict transitions guarded.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID;
  v_moment UUID;
  v_gen UUID;
  v_err BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'C2 smoke SKIPPED (no auth user in this environment)';
    RETURN;
  END IF;

  v_moment := public.moment_record(v_user, 'youtube', 'c2-smoke-' || gen_random_uuid()::TEXT,
                                   'https://example.com/post', NULL, 1000, TRUE);
  INSERT INTO public.cinematic_generations
    (moment_id, template_id, anchor_plate_version, prompt_template_version,
     subject_desc, family_action, tier_intensity, generation_seed, render_tier, mode)
  VALUES (v_moment, 'ground_slam', 1, 1, 'smoke subject', 'smoke action', 'modest', 42, 'fast', 'sim')
  RETURNING id INTO v_gen;

  -- Completing an unmoderated generation must fail (Hard Rule 39).
  BEGIN
    PERFORM public.cinematic_complete_mint(v_gen, 'athlete', 'creature', 'on_summon',
      NULL, 'Smoke', '{}', NULL, NULL,
      'https://x.supabase.co/storage/v1/object/public/battle-media/x.mp4');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: completion without moderation must be blocked'; END IF;

  -- Reject → row is terminal for completion.
  PERFORM public.cinematic_moderation_verdict(v_gen, FALSE, 'smoke reject');
  v_err := FALSE;
  BEGIN
    PERFORM public.cinematic_moderation_verdict(v_gen, TRUE);  -- double-verdict must fail
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: double verdict must be blocked'; END IF;

  -- Clean up smoke rows (ledger-free tables; safe).
  DELETE FROM public.cinematic_generations WHERE id = v_gen;
  DELETE FROM public.moments WHERE id = v_moment;

  RAISE NOTICE 'C2 smoke OK: moderation gate + verdict transitions enforced';
END $$;
