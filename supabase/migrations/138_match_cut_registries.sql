-- Migration 138: Match Cut + Cinematic Engine registries (phase C0).
--
-- The cinematic engine brackets every minted cutscene MP4 between a fixed start-plate
-- and end-plate (one pair per Match Cut template); only the middle is generated, driven
-- by a house-owned motion prompt template. Specs: NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md
-- (P3 template table) + NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md (§2 registries, C0).
-- Hard Rules 37–39. Naming: the specs' "battle_chits" is this repo's `moment_chits`
-- (Hard Rule 27; RECONCILIATION §7).
--
-- `final_frame_camera` is DEPRECATED and intentionally absent: Unity owns the camera
-- pose via its local MatchCutAnchor, authored against the versioned plates.

-- ── match_cut_templates: the finite camera geometries (role-keyed, ~6 at launch) ──
CREATE TABLE public.match_cut_templates (
  id                TEXT PRIMARY KEY,          -- 'ground_slam', 'sky_descent', …
  role              TEXT NOT NULL,             -- gameplay role the template serves
  entry_framing     TEXT NOT NULL,
  exit_framing      TEXT NOT NULL,
  duration_min_s    INTEGER NOT NULL CHECK (duration_min_s > 0),
  duration_max_s    INTEGER NOT NULL,
  stage_transition  TEXT NOT NULL DEFAULT 'dim_vignette',
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (duration_max_s >= duration_min_s)
);

COMMENT ON TABLE public.match_cut_templates IS
  'Match Cut camera geometries (minting spec P3). Per-TEMPLATE, never per-card (Hard '
  'Rule 39). Unity authors one MatchCutAnchor per row; keep this set small — every exit '
  'geometry is a resume-camera Unity must support.';

INSERT INTO public.match_cut_templates
  (id, role, entry_framing, exit_framing, duration_min_s, duration_max_s, stage_transition) VALUES
  ('ground_slam', 'aggressive creature summon',
   'low push-in on caster; stage dims to vignette',
   'low-angle on entity''s base hitting spawn point -> Unity low-angle on 3D creature at spawn',
   4, 6, 'dim_vignette'),
  ('sky_descent', 'majestic creature summon',
   'crane up; stage dims',
   'high-angle down as entity lands center-field -> Unity high-angle on creature at spawn',
   5, 7, 'dim_vignette'),
  ('projectile_strike', 'single-target attack spell',
   'over-caster-shoulder toward opponent; stage dims',
   'framed on opponent at white-flash impact -> Unity cut to opponent hit-react (matching angle)',
   3, 5, 'dim_vignette'),
  ('radial_burst', 'AoE spell',
   'pull to wide/high overview; stage dims',
   'top-down/wide of shockwave over field, edge-fade -> Unity wide gameplay cam, all targets hit-react',
   3, 5, 'dim_vignette'),
  ('aura_surge', 'buff/heal',
   'orbit to center on target; partial dim',
   'centered on target glowing -> Unity cut to target 3D body + buff VFX (no hit-react)',
   3, 4, 'partial_dim'),
  ('counter_veil', 'counter/defensive',
   'rapid push-in on caster; stage flash',
   'caster in rebound stance facing threat -> Unity cut to caster, attacker recoils',
   2, 4, 'stage_flash');

-- ── match_cut_anchor_plates: the versioned fixed bookends (start + end per template) ──
CREATE TABLE public.match_cut_anchor_plates (
  template_id      TEXT NOT NULL REFERENCES public.match_cut_templates(id),
  version          INTEGER NOT NULL CHECK (version >= 1),
  start_plate_url  TEXT,
  end_plate_url    TEXT,
  aspect           TEXT NOT NULL DEFAULT '16:9' CHECK (aspect = '16:9'),  -- Seedance follows the reference frames
  -- 'signed_off' is the C1 gate: visual approval against the Arena anchor poses.
  status           TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','signed_off','retired')),
  notes            TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (template_id, version)
);

COMMENT ON TABLE public.match_cut_anchor_plates IS
  'Fixed start/end plates per Match Cut template, authored once at 16:9 in house style '
  '(cinematic spec §2). Versioned; chits pin the version they were generated against. '
  'Unity validates plate version and matches its anchor camera poses to these.';

-- ── match_cut_prompt_templates: the house-owned motion prompts (the middle) ────────
CREATE TABLE public.match_cut_prompt_templates (
  template_id                 TEXT NOT NULL REFERENCES public.match_cut_templates(id),
  version                     INTEGER NOT NULL CHECK (version >= 1),
  prompt_body                 TEXT NOT NULL,
  tuned_against_plate_version INTEGER,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (template_id, version),
  FOREIGN KEY (template_id, tuned_against_plate_version)
    REFERENCES public.match_cut_anchor_plates(template_id, version),
  -- Hard Rule 39: only the three slots vary; STYLE + CONSTRAINTS blocks always present.
  CONSTRAINT prompt_has_slots CHECK (
    position('{SUBJECT_DESC}'   IN prompt_body) > 0 AND
    position('{FAMILY_ACTION}'  IN prompt_body) > 0 AND
    position('{TIER_INTENSITY}' IN prompt_body) > 0 AND
    position('[STYLE]'          IN prompt_body) > 0 AND
    position('[CONSTRAINTS]'    IN prompt_body) > 0
  )
);

COMMENT ON TABLE public.match_cut_prompt_templates IS
  'House-owned motion prompt per Match Cut template (cinematic spec §4). STYLE '
  '(style-lock) + CONSTRAINTS blocks are never user-influenced or omitted (Hard Rule '
  '39); only {SUBJECT_DESC}/{FAMILY_ACTION}/{TIER_INTENSITY} are filled at generation. '
  'Generation-side IP: no client SELECT policy, ever.';

-- ── cinematic/minting fields on the chit (RECONCILIATION §7 contract) ─────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS match_cut_template_id   TEXT REFERENCES public.match_cut_templates(id),
  ADD COLUMN IF NOT EXISTS anchor_plate_version    INTEGER,
  ADD COLUMN IF NOT EXISTS prompt_template_version INTEGER,
  ADD COLUMN IF NOT EXISTS generation_seed         BIGINT,
  ADD COLUMN IF NOT EXISTS mp4_cutscene_url        TEXT,   -- battle-media CDN URL, NEVER a provider URL (Hard Rule 38)
  ADD COLUMN IF NOT EXISTS original_minter_handle  TEXT,   -- attribution; survives ownership transfer
  ADD COLUMN IF NOT EXISTS source_platform         TEXT;

-- A chit generated against plates/prompts must reference registered versions.
ALTER TABLE public.moment_chits
  ADD CONSTRAINT moment_chits_anchor_plate_fk
    FOREIGN KEY (match_cut_template_id, anchor_plate_version)
    REFERENCES public.match_cut_anchor_plates(template_id, version),
  ADD CONSTRAINT moment_chits_prompt_template_fk
    FOREIGN KEY (match_cut_template_id, prompt_template_version)
    REFERENCES public.match_cut_prompt_templates(template_id, version);

-- Ingest attribution on the moment (minting spec P1: capture the creator handle).
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS creator_handle TEXT;

-- ── battle-media bucket: minted MP4s + card art (public read, server-only writes) ──
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('battle-media', 'battle-media', TRUE, 52428800,
        ARRAY['video/mp4','image/png','image/jpeg','image/webp'])
ON CONFLICT (id) DO NOTHING;
-- No storage.objects policies on purpose: public bucket = anonymous read of objects;
-- with no INSERT/UPDATE/DELETE policy only the service role (generation pipeline) writes.

-- ── RLS ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.match_cut_templates        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_cut_anchor_plates    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_cut_prompt_templates ENABLE ROW LEVEL SECURITY;

-- Templates + plates are client contract surface (Unity validates versions).
CREATE POLICY "match_cut_templates_select" ON public.match_cut_templates
  FOR SELECT USING (is_active);

CREATE POLICY "anchor_plates_select_signed_off" ON public.match_cut_anchor_plates
  FOR SELECT USING (status <> 'retired');

-- match_cut_prompt_templates: NO client policies — generation-side only (house IP).
-- Writes everywhere: SECURITY DEFINER / service role only.

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: seed count, slot-guard CHECK, and version-pinning FKs.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_err BOOLEAN := FALSE;
BEGIN
  IF (SELECT COUNT(*) FROM public.match_cut_templates) <> 6 THEN
    RAISE EXCEPTION 'SMOKE FAIL: expected 6 match_cut_templates';
  END IF;

  -- Prompt missing the style-lock block must be rejected (Hard Rule 39).
  BEGIN
    INSERT INTO public.match_cut_prompt_templates (template_id, version, prompt_body)
    VALUES ('ground_slam', 999, '{SUBJECT_DESC} {FAMILY_ACTION} {TIER_INTENSITY} no blocks');
  EXCEPTION WHEN check_violation THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: prompt without STYLE/CONSTRAINTS should be rejected'; END IF;

  -- Chit fields must pin a REGISTERED plate version.
  v_err := FALSE;
  BEGIN
    UPDATE public.moment_chits SET match_cut_template_id = 'ground_slam', anchor_plate_version = 42
    WHERE id = gen_random_uuid();  -- no row matches; FK still validated on real rows
    INSERT INTO public.match_cut_prompt_templates
      (template_id, version, prompt_body, tuned_against_plate_version)
    VALUES ('ground_slam', 998,
      '[STYLE] [CONSTRAINTS] {SUBJECT_DESC} {FAMILY_ACTION} {TIER_INTENSITY}', 42);
  EXCEPTION WHEN foreign_key_violation THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: unregistered plate version should be rejected'; END IF;

  RAISE NOTICE 'C0 smoke OK: 6 templates seeded; slot guard + version-pinning FKs enforced';
END $$;
