-- Migration 163: generation-quality audit (PLAN 2026-07-13) items 5+6 — DB side.
--
-- (a) Ledger transparency: cinematic_generations stored only the SLOT VALUES, so the
--     "DBZ card" trace had to re-derive what was actually sent to the provider. Store
--     the FULL assembled prompts + the provider request ids + whether the uploaded
--     clip was passed as a reference video.
--
-- (b) Prompt template v2 (all six match_cut templates): the v1 [SUBJECT] line claimed
--     "the stylized subject from the reference illustration, kept exactly on-model",
--     but the illustration was never delivered — the old call sent a wrong param name
--     (reference_image_url) that Seedance silently dropped, and the REAL param
--     (reference_images) is mutually exclusive with first/last-frame conditioning,
--     which the anchor-plate bookends require (Hard Rule 39). v2 therefore:
--       * carries subject identity in the prompt text itself, and
--       * adds a {CLIP_REF} slot — reference_videos[] IS combinable with frame
--         conditioning, so the user's actual uploaded clip finally reaches the
--         generation ("recreate the action of reference video 1"). The slot is filled
--         with house-owned constant text (+ the sanitized clip_video_desc) only when
--         a moderated clip is attached; otherwise it collapses, exactly like
--         {VIDEO_DESC} (mig 149).
--       * hardens [CONSTRAINTS]: original character design, never an existing
--         anime/manga/game/comic character, no celebrity likeness (audit cause #5 —
--         also the fix for the generic-anime-hero default).
--     STYLE + CONSTRAINTS remain constant blocks (Hard Rule 39); the CHECK from mig
--     138 still enforces all three classic slots + both blocks.

-- ── (a) ledger columns ─────────────────────────────────────────────────────────────
ALTER TABLE public.cinematic_generations
  ADD COLUMN IF NOT EXISTS illustration_prompt     TEXT,
  ADD COLUMN IF NOT EXISTS motion_prompt           TEXT,
  ADD COLUMN IF NOT EXISTS illustration_request_id TEXT,
  ADD COLUMN IF NOT EXISTS cutscene_request_id     TEXT,
  ADD COLUMN IF NOT EXISTS clip_reference_used     BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.cinematic_generations.illustration_prompt IS
  'The FULL prompt sent to the image model (audit item 6) — slots already filled.';
COMMENT ON COLUMN public.cinematic_generations.motion_prompt IS
  'The FULL assembled motion prompt sent to Seedance — slots already filled.';
COMMENT ON COLUMN public.cinematic_generations.clip_reference_used IS
  'TRUE when the user''s moderated uploaded clip was passed as reference_videos[0].';

-- ── (b) motion prompt templates v2 ─────────────────────────────────────────────────
INSERT INTO public.match_cut_prompt_templates
  (template_id, version, tuned_against_plate_version, prompt_body) VALUES

('ground_slam', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, building to the entity slamming down onto the spawn point with ground-cracking force.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed to a vignette.
[CAMERA] locked low push-in on the summoner, tilting down to the spawn point as the entity lands; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the landing impact settles and resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.'),

('sky_descent', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, as the entity descends majestically from above and lands at center field.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed, a soft column of light following the descent.
[CAMERA] slow crane up, then tilt down following the entity to its landing at center field; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the landing resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.'),

('projectile_strike', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, launched from behind the caster and streaking toward the opponent to strike.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed to a vignette.
[CAMERA] locked over-the-shoulder toward the opponent, slow push-in; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the impact whites out and resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.'),

('radial_burst', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, erupting outward as a radial shockwave that sweeps across the whole field.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed to a vignette.
[CAMERA] pull back to a wide, high overview of the field as the shockwave expands; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the shockwave fades at the edges and resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.'),

('aura_surge', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, channeling a protective surge that wraps the ally in light.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed, warm glow rising around the target.
[CAMERA] slow orbital drift around the caster as the surge builds; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the glow steadies and resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.'),

('counter_veil', 2, 1,
'[SUBJECT] {SUBJECT_DESC} — an original stylized character unique to this card, consistent throughout the shot.
{CLIP_REF}
[ACTION] {FAMILY_ACTION}, performed with {TIER_INTENSITY}, snapping into a defensive stance that rebounds the incoming threat.
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed, a hard rim-light on the caster.
[CAMERA] quick push-in to a low hero angle as the veil flares; no cuts.
[STYLE] cel-shaded anime, bold ink outlines, house palette (#6C63FF and #03DAC6 accents), flat shadows.
[CONSTRAINTS] open exactly on the first frame; the caster holds the rebound stance and resolves exactly to the last frame; smooth motion; stable framing; an original character design — never any existing anime, manga, game, or comic character, no celebrity likeness; no text, no logos, no real-world photographic look.')

ON CONFLICT (template_id, version) DO NOTHING;

-- ── apply-time smoke: v2 present for all six + CHECK slots intact ──────────────────
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.match_cut_prompt_templates
  WHERE version = 2 AND position('{CLIP_REF}' IN prompt_body) > 0;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'SMOKE FAIL: expected 6 v2 prompt templates with a CLIP_REF slot, got %', v_count;
  END IF;
  RAISE NOTICE 'prompt-ledger smoke OK: 6 v2 templates + ledger columns in place';
END $$;
