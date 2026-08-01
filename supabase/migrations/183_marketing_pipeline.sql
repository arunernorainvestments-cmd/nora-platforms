-- Migration 183: marketing spot pipeline — briefs, render ledger, spend cap, publish gate.
--
-- Standard Playset spec PHASE S3. The generation scripts live in tools/marketing/; this is
-- the state they write to. Three things the spec insists on, encoded as schema rather than
-- as process:
--
--   1. ANTI-SLOP IS A HARD GATE (§0.5, elevated from a marketing note). Nothing publishes
--      without a named human reviewer: marketing_spot_publish RAISEs unless the spot has an
--      approved generation carrying reviewed_by. "We meant to review it" cannot ship.
--
--   2. G-COLL LANGUAGE BAN APPLIES TO AD COPY (spec S3 "DO NOT"; CLAUDE.md governance).
--      Card-facing copy may never promise value, appreciation, or income — so the copy
--      guard trigger rejects investment / return / yield / dividend / revenue share /
--      profit / ROI / appreciate in any spot's hook, CTA, or description. A marketing
--      channel is exactly where that language leaks in, so the DB refuses it.
--
--   3. COST ATTRIBUTION IS SEPARATE FROM USER MINTS (REPO-CHECK S3.1 — RESOLVED: twin).
--      cinematic_generations is keyed on (moment_id, template_id, anchor_plate_version,
--      prompt_template_version) with FKs into the match-cut plate tables — a marketing spot
--      has no moment and no card seam, so reusing it would mean inventing fake moment rows
--      inside the mint ledger and double-counting every mint report. marketing_generations
--      is its own twin: same seed/model/mode/attempt provenance discipline (Hard Rule 39),
--      its own budget line, zero overlap with mint spend.
--
-- G-IP (spec §2) rides along: every spot is Lane-A original content. real_person_depicted
-- defaults FALSE and a spot that sets it TRUE cannot publish without a licence reference on
-- the lkn_* rail — the same line the card slate holds.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. SPOTS — the authored briefs (what we intend to say, on which channel, when)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.marketing_spots (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key                   TEXT NOT NULL UNIQUE,          -- stable slug, e.g. 'transformation-hero'
  title                 TEXT NOT NULL,
  -- What the spot is: the §S3 format list.
  format                TEXT NOT NULL CHECK (format IN (
    'transformation','starter_reveal','fusion_spectacle','mint_explainer','drop','cohort')),
  aspect                TEXT NOT NULL DEFAULT '9:16' CHECK (aspect IN ('9:16','1:1','16:9')),
  duration_s            INTEGER NOT NULL DEFAULT 10 CHECK (duration_s BETWEEN 3 AND 60),

  -- Copy (guarded — see the copy trigger).
  hook                  TEXT,
  cta                   TEXT,
  description           TEXT,

  -- Where it goes and when. Channels are advisory data, not an integration.
  channels              TEXT[] NOT NULL DEFAULT '{}'
    CHECK (channels <@ ARRAY['tiktok','instagram','youtube','x','facebook','discord','reddit','twitch']::TEXT[]),
  scheduled_for         TIMESTAMPTZ,                   -- e.g. the Nov 19 2026 drop

  -- Provenance of the subject: a starter card, or free-standing.
  chit_id               UUID REFERENCES public.moment_chits(id),

  -- G-IP: TRUE requires a licence on the lkn_* rail before publish.
  real_person_depicted  BOOLEAN NOT NULL DEFAULT FALSE,
  license_agreement_id  UUID,

  status                TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','rendering','in_review','approved','published','retired')),
  published_at          TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX marketing_spots_status_idx    ON public.marketing_spots (status);
CREATE INDEX marketing_spots_scheduled_idx ON public.marketing_spots (scheduled_for)
  WHERE scheduled_for IS NOT NULL;

COMMENT ON TABLE public.marketing_spots IS
  'Marketing spot briefs (Playset spec S3). Publishing requires a human-approved render '
  '(anti-slop hard gate) and Lane-A content (G-IP).';

-- ── copy guard: the G-COLL language ban, enforced ────────────────────────────────
CREATE OR REPLACE FUNCTION public.marketing_copy_guard()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_text TEXT := lower(COALESCE(NEW.hook,'') || ' ' || COALESCE(NEW.cta,'') || ' ' ||
                       COALESCE(NEW.description,'') || ' ' || COALESCE(NEW.title,''));
  v_banned TEXT;
BEGIN
  -- Word-boundary matched, so ordinary words are never collateral ("heroic" is not "roi").
  FOREACH v_banned IN ARRAY ARRAY[
    'investment','invest in','return on','returns','yield','dividend','dividends',
    'revenue share','profit','profits','roi','appreciate','appreciation','resale value'
  ] LOOP
    IF v_text ~ ('\y' || v_banned || '\y') THEN
      RAISE EXCEPTION
        'Marketing copy may not use financial language (%): cards are collectible game assets, never instruments',
        v_banned;
    END IF;
  END LOOP;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER marketing_spots_copy_guard
  BEFORE INSERT OR UPDATE ON public.marketing_spots
  FOR EACH ROW EXECUTE FUNCTION public.marketing_copy_guard();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. GENERATIONS — the render ledger + cost attribution (the cinematic twin)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.marketing_generations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  spot_id         UUID NOT NULL REFERENCES public.marketing_spots(id) ON DELETE CASCADE,
  attempt         INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),

  model           TEXT NOT NULL,
  mode            TEXT NOT NULL CHECK (mode IN ('sim','live')),
  render_tier     TEXT NOT NULL CHECK (render_tier IN ('fast','standard')),
  generation_seed BIGINT NOT NULL,                 -- reproducible re-runs (Hard Rule 39)
  prompt          TEXT NOT NULL,

  -- battle-media object path, never a provider URL (Hard Rule 38 posture).
  asset_path      TEXT,
  cost_cents      INTEGER NOT NULL DEFAULT 0 CHECK (cost_cents >= 0),

  -- The anti-slop gate: a render is nothing until a human signs it.
  status          TEXT NOT NULL DEFAULT 'generated'
    CHECK (status IN ('generated','approved','rejected')),
  reviewed_by     TEXT,                            -- named human (spec §4 Q13)
  reviewed_at     TIMESTAMPTZ,
  review_note     TEXT,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (spot_id, attempt)
);

CREATE INDEX marketing_generations_spot_idx ON public.marketing_generations (spot_id, created_at DESC);

ALTER TABLE public.marketing_generations
  ADD CONSTRAINT marketing_generation_review_complete CHECK (
    status = 'generated' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL));

COMMENT ON TABLE public.marketing_generations IS
  'Marketing render ledger — the cinematic_generations TWIN (REPO-CHECK S3.1). Separate '
  'budget line from user mints; same seed/model provenance; human review is a column, not a habit.';

-- ── budget: a cap the scripts read before spending ──────────────────────────────
CREATE TABLE public.marketing_budget_config (
  id                 BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  cap_cents          INTEGER NOT NULL DEFAULT 0 CHECK (cap_cents >= 0),  -- 0 = no spend authorised
  notes              TEXT,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.marketing_budget_config (id, notes)
VALUES (TRUE, 'Segmind marketing budget — [FOUNDER] sets cap_cents; 0 means no marketing spend is authorised.')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.marketing_spend_summary()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'cap_cents',   (SELECT cap_cents FROM public.marketing_budget_config WHERE id),
    'spent_cents', (SELECT COALESCE(SUM(cost_cents), 0) FROM public.marketing_generations WHERE mode = 'live'),
    'renders',     (SELECT COUNT(*) FROM public.marketing_generations WHERE mode = 'live'),
    'approved',    (SELECT COUNT(*) FROM public.marketing_generations WHERE status = 'approved')
  );
$$;

ALTER TABLE public.marketing_spots        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_generations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_budget_config ENABLE ROW LEVEL SECURITY;
-- No policies at all: marketing state is operator-only (service role bypasses RLS).
-- Clients never read or write it.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. RPCs — service-only, and the publish gate that makes the review real
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.marketing_spot_upsert(
  p_key TEXT, p_title TEXT, p_format TEXT,
  p_hook TEXT DEFAULT NULL, p_cta TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_channels TEXT[] DEFAULT '{}', p_aspect TEXT DEFAULT '9:16',
  p_duration_s INTEGER DEFAULT 10, p_chit_id UUID DEFAULT NULL,
  p_scheduled_for TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.marketing_spots
    (key, title, format, hook, cta, description, channels, aspect, duration_s, chit_id, scheduled_for)
  VALUES
    (p_key, p_title, p_format, p_hook, p_cta, p_description,
     COALESCE(p_channels,'{}'), p_aspect, p_duration_s, p_chit_id, p_scheduled_for)
  ON CONFLICT (key) DO UPDATE SET
    title = EXCLUDED.title, format = EXCLUDED.format, hook = EXCLUDED.hook,
    cta = EXCLUDED.cta, description = EXCLUDED.description, channels = EXCLUDED.channels,
    aspect = EXCLUDED.aspect, duration_s = EXCLUDED.duration_s,
    chit_id = EXCLUDED.chit_id, scheduled_for = EXCLUDED.scheduled_for
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketing_generation_record(
  p_spot_id UUID, p_model TEXT, p_mode TEXT, p_render_tier TEXT,
  p_seed BIGINT, p_prompt TEXT, p_asset_path TEXT DEFAULT NULL,
  p_cost_cents INTEGER DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_attempt INTEGER; v_id UUID; v_sum JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.marketing_spots WHERE id = p_spot_id) THEN
    RAISE EXCEPTION 'Unknown marketing spot %', p_spot_id;
  END IF;

  -- Live spend is capped: the ledger refuses the render that would breach it.
  IF p_mode = 'live' THEN
    v_sum := public.marketing_spend_summary();
    IF (v_sum->>'spent_cents')::INTEGER + COALESCE(p_cost_cents,0) > (v_sum->>'cap_cents')::INTEGER THEN
      RAISE EXCEPTION 'Marketing budget cap reached (% of % cents spent) — [FOUNDER] raises cap_cents',
        v_sum->>'spent_cents', v_sum->>'cap_cents';
    END IF;
  END IF;

  SELECT COALESCE(MAX(attempt), 0) + 1 INTO v_attempt
  FROM public.marketing_generations WHERE spot_id = p_spot_id;

  INSERT INTO public.marketing_generations
    (spot_id, attempt, model, mode, render_tier, generation_seed, prompt, asset_path, cost_cents)
  VALUES
    (p_spot_id, v_attempt, p_model, p_mode, p_render_tier, p_seed, p_prompt, p_asset_path,
     COALESCE(p_cost_cents, 0))
  RETURNING id INTO v_id;

  UPDATE public.marketing_spots SET status = 'in_review' WHERE id = p_spot_id AND status IN ('draft','rendering');
  RETURN v_id;
END;
$$;

-- The human verdict. There is deliberately no "auto-approve" path.
CREATE OR REPLACE FUNCTION public.marketing_generation_verdict(
  p_generation_id UUID, p_approved BOOLEAN, p_reviewer TEXT, p_note TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF COALESCE(btrim(p_reviewer), '') = '' THEN
    RAISE EXCEPTION 'A named human reviewer is required (anti-slop gate)';
  END IF;

  UPDATE public.marketing_generations
  SET status      = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
      reviewed_by = p_reviewer,
      reviewed_at = NOW(),
      review_note = p_note
  WHERE id = p_generation_id AND status = 'generated';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Generation % not found or already reviewed', p_generation_id;
  END IF;

  UPDATE public.marketing_spots s
  SET status = CASE WHEN p_approved THEN 'approved' ELSE 'draft' END
  WHERE s.id = (SELECT spot_id FROM public.marketing_generations WHERE id = p_generation_id)
    AND s.status <> 'published';
END;
$$;

CREATE OR REPLACE FUNCTION public.marketing_spot_publish(p_spot_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_s public.marketing_spots%ROWTYPE;
BEGIN
  SELECT * INTO v_s FROM public.marketing_spots WHERE id = p_spot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown marketing spot %', p_spot_id; END IF;

  -- Anti-slop hard gate: an approved render, signed by a named human.
  IF NOT EXISTS (
    SELECT 1 FROM public.marketing_generations
    WHERE spot_id = p_spot_id AND status = 'approved' AND reviewed_by IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Spot % has no human-approved render — nothing publishes unreviewed', p_spot_id;
  END IF;

  -- G-IP: a real person on screen needs a licence on the lkn_* rail, or it is cut.
  IF v_s.real_person_depicted AND v_s.license_agreement_id IS NULL THEN
    RAISE EXCEPTION 'Spot % depicts a real person with no licence agreement (G-IP)', p_spot_id;
  END IF;

  UPDATE public.marketing_spots
  SET status = 'published', published_at = NOW()
  WHERE id = p_spot_id;
END;
$$;

REVOKE ALL ON FUNCTION public.marketing_spot_upsert(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, INTEGER, UUID, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketing_generation_record(UUID, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketing_generation_verdict(UUID, BOOLEAN, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketing_spot_publish(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketing_spend_summary() FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. THE LAUNCH SLATE — briefs only, no spend. §S3 formats, transformation first.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM public.marketing_spot_upsert(
    'transformation-hero', 'Your post becomes a playable card', 'transformation',
    'That clip you already posted? It is a card now.',
    'Mint yours free at noraplatforms.com',
    'The core pitch (rank 3, §0.5): a real post transforms into a NORA card, then the card '
    'is summoned in a battle. Human-story led, crafted cel-shaded identity, no slop.',
    ARRAY['tiktok','instagram','youtube','x']::TEXT[], '9:16', 12);

  PERFORM public.marketing_spot_upsert(
    'starter-set-reveal', 'The Standard Playset', 'starter_reveal',
    '30 cards. Free with every account. Day one.',
    'Build your first deck',
    'Fan-out of the 30 starter cards, ending on the deck-builder. Shows the free floor, '
    'sets up the personal mint as the next beat.',
    ARRAY['tiktok','instagram','youtube']::TEXT[], '9:16', 10);

  PERFORM public.marketing_spot_upsert(
    'fusion-spectacle', 'Two cards, one moment', 'fusion_spectacle',
    'Play them together and something else happens.',
    'Discover fusions with your starters',
    'Fusion detection fires on two same-family creatures. The starters alone can '
    'trigger every launch fusion rule — that is the hook.',
    ARRAY['tiktok','youtube','x','discord']::TEXT[], '9:16', 9);

  PERFORM public.marketing_spot_upsert(
    'mint-explainer', 'How minting works', 'mint_explainer',
    'Link the post you own. That is the whole gate.',
    'Mint your moment',
    'Consent-first explainer: you can only mint a post you own; tier comes from how the '
    'moment actually performed; you preview the card before it is final.',
    ARRAY['youtube','reddit','discord']::TEXT[], '9:16', 15);

  -- The Nov 19 window: prepped now, posted then (§1.3 get-ahead pick).
  PERFORM public.marketing_spot_upsert(
    'gamer-drop-nov19', 'Open-world chaos drop', 'drop',
    'Physics did something it was not supposed to do.',
    'Play the gamer cards',
    'Gamer-family starter cards in an original open-world-chaos register — original city, '
    'original characters, no third-party game footage or branding, ever (G-IP).',
    ARRAY['tiktok','youtube','x','twitch']::TEXT[], '9:16', 12,
    NULL, TIMESTAMPTZ '2026-11-19 13:00:00+00');

  PERFORM public.marketing_spot_upsert(
    'founding-cohort', 'Founding Market Makers', 'cohort',
    'The first creators to turn their moments into cards.',
    'See their cards',
    'Cohort montage built from the founding creators own mint reveals (rank 2, §0.5). '
    'Every clip is the creator posting their own card — their audience, their flex.',
    ARRAY['tiktok','instagram','youtube','x']::TEXT[], '9:16', 15);
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE: the copy ban bites, the publish gate holds, the cap holds.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_spot UUID; v_gen UUID; v_err BOOLEAN; v_msg TEXT; v_n INTEGER;
BEGIN
  BEGIN
    SELECT COUNT(*) INTO v_n FROM public.marketing_spots;
    IF v_n < 6 THEN RAISE EXCEPTION 'SMOKE FAIL: launch slate must seed 6 spots (got %)', v_n; END IF;

    -- G-COLL language ban in ad copy
    v_err := FALSE;
    BEGIN
      PERFORM public.marketing_spot_upsert('smoke-banned', 'Smoke', 'starter_reveal',
        'Your cards will appreciate in value', 'Buy now', NULL);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
    END;
    IF NOT v_err OR v_msg NOT LIKE '%financial language%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: value-promise copy must be refused (got %)', v_msg;
    END IF;

    v_spot := public.marketing_spot_upsert('smoke-ok', 'Smoke spot', 'starter_reveal',
      'Thirty cards, free, day one.', 'Build a deck', 'Smoke brief.');

    -- publish before any render → refused
    v_err := FALSE;
    BEGIN PERFORM public.marketing_spot_publish(v_spot);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%no human-approved render%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: unreviewed publish must be refused (got %)', v_msg;
    END IF;

    -- a sim render + an unnamed reviewer → still refused
    v_gen := public.marketing_generation_record(v_spot, 'sim-model', 'sim', 'fast', 42,
      'smoke prompt', 'marketing/smoke.mp4', 0);
    v_err := FALSE;
    BEGIN PERFORM public.marketing_generation_verdict(v_gen, TRUE, '   ');
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%named human reviewer%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: anonymous approval must be refused (got %)', v_msg;
    END IF;

    -- named human → publishes
    PERFORM public.marketing_generation_verdict(v_gen, TRUE, 'smoke-reviewer', 'looks crafted');
    PERFORM public.marketing_spot_publish(v_spot);
    IF (SELECT status FROM public.marketing_spots WHERE id = v_spot) <> 'published' THEN
      RAISE EXCEPTION 'SMOKE FAIL: reviewed spot must publish';
    END IF;

    -- live spend against a zero cap → refused
    v_err := FALSE;
    BEGIN
      PERFORM public.marketing_generation_record(v_spot, 'live-model', 'live', 'standard', 7,
        'smoke live prompt', NULL, 500);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM; END;
    IF NOT v_err OR v_msg NOT LIKE '%budget cap%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: live spend past the cap must be refused (got %)', v_msg;
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'S3 smoke OK: copy ban bites, publish needs a named human, budget cap holds';
      ELSE
        RAISE;
      END IF;
  END;
END $$;
