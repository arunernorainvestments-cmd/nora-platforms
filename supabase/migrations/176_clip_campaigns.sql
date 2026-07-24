-- Migration 176: Clip Campaigns — bounty marketplace for raw clips (Collections N7).
--
-- Collections spec Phase N7 + §1.6. A Market Maker posts what clips they want and
-- what they pay; clippers submit; EVERY submission passes platform moderation
-- BEFORE the Market Maker can ever see it; the Market Maker accepts winners;
-- payment settles from escrow on the USD rail (sim in beta).
--
-- NEW NAMESPACE (spec §0.5): everything here is clip_campaign*. The archived
-- mig-089 `campaigns` tables are NOT touched, extended, or renamed.
--
-- ═══ REPO-CHECK 1.6 — the consent chain (the load-bearing decision) ═══
-- Hard Rule 37 says a chit is minted only from a post the MINTER owns (OAuth-
-- verified), and the device-clip leg must be tethered to an already-approved owned
-- moment. A clipper-sourced clip cannot satisfy that on its own — the clipper is
-- not the post owner. Resolution, per the spec's stated default, WITHOUT weakening
-- HR37:
--
--   clip_campaigns.source_moment_id — OPTIONAL tether to a moment the Market Maker
--   ALREADY owns (OAuth-verified through moment-ingest, moderation-approved).
--     * SET   → the campaign is mint-eligible: the clipper is cutting a highlight
--               FROM the Market Maker's own content, so an accepted clip is exactly
--               the device-clip leg of HR37 for a post its owner already proved.
--               The campaign still NEVER mints: it hands the accepted clip to the
--               existing pipeline (moment_attach_clip), which owns consent and
--               re-moderates the actual upload.
--     * NULL  → LICENSING-ONLY campaign: payment + profile display, no mint feed.
--               This is the spec's fallback and the default for any campaign whose
--               clip did not come from the Market Maker's own post.
--   clip_campaign_mint_eligible() is the single reader of that distinction, and
--   accepting a clip never sets a mint in motion by itself.
--
-- ═══ REPO-CHECK N7.1 [FOUNDER — surfaced, not self-answered] ═══
-- Payout structure. Default taken: PER-ACCEPTED-CLIP rate with a max_accepted count,
-- so budget math is closed-form (budget = payout_per_clip * max_accepted, escrowed
-- in full at creation). The contest/winner-takes-budget model is NOT built. Founder
-- to confirm whether both should exist.
--
-- ═══ REPO-CHECK N7.2 — clipper eligibility ═══
-- RESOLVED to the spec default: clippers SUBMIT freely (no KYC — maximizes funnel),
-- and KYC is required at ACCEPTANCE, because that is when money moves
-- (is_eligible_for_real_money, §1.3 money gate). A clip accepted for an unverified
-- clipper is refused, not silently held.
--
-- ═══ Moderation posture ═══
-- The mint stack's SEMANTICS verbatim: minor-safety is absolute and first, a
-- rejected clip is never visible to the Market Maker, escalations go to a
-- service-only human-review queue with the same reason/status vocabulary as
-- moderation_escalations (mig 141). A SEPARATE queue table is used rather than
-- reusing moderation_escalations because that table's moment_id is NOT NULL and
-- FK'd to moments — campaign clips have no moment — and widening it would
-- destabilize the live mint + admin-review paths. The admin console needs a second
-- queue view; that is a tracked follow-up, not a silent gap.

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONFIG — platform fee on campaign payouts (§1.1 config, founder-tunable)
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO public.platform_fee_config (config_key, value_int, description) VALUES
  ('clip_campaign_fee_bps', 1000,
   'Platform fee withheld from a clip-campaign payout, basis points (10%). Founder to confirm.')
ON CONFLICT (config_key) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════════
-- clip-staging bucket — PRIVATE, owner-prefix only (the mig-146 pattern)
-- ═══════════════════════════════════════════════════════════════════════════════
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('clip-staging', 'clip-staging', FALSE, 209715200,
        ARRAY['video/mp4','image/jpeg'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "clip_staging_insert_own" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'clip-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "clip_staging_update_own" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'clip-staging' AND (storage.foldername(name))[1] = auth.uid()::text)
  WITH CHECK (bucket_id = 'clip-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "clip_staging_select_own" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'clip-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "clip_staging_delete_own" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'clip-staging' AND (storage.foldername(name))[1] = auth.uid()::text);

-- NOTE: no public read and no Market-Maker read policy on purpose. A Market Maker
-- never reads the raw object directly — the review surface gets a service-issued
-- signed URL, and only for an APPROVED submission.

-- ═══════════════════════════════════════════════════════════════════════════════
-- clip_campaigns
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.clip_campaigns (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  market_maker_user_id   UUID NOT NULL REFERENCES auth.users(id),
  title                  TEXT NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  brief                  TEXT NOT NULL CHECK (length(btrim(brief)) BETWEEN 1 AND 4000),
  -- REPO-CHECK 1.6: the HR37 tether. NULL = licensing-only campaign.
  source_moment_id       UUID REFERENCES public.moments(id),
  payout_per_clip_cents  INTEGER NOT NULL CHECK (payout_per_clip_cents > 0),
  max_accepted           INTEGER NOT NULL CHECK (max_accepted BETWEEN 1 AND 500),
  budget_cents           INTEGER NOT NULL CHECK (budget_cents > 0),
  escrow_remaining_cents INTEGER NOT NULL CHECK (escrow_remaining_cents >= 0),
  accepted_count         INTEGER NOT NULL DEFAULT 0 CHECK (accepted_count >= 0),
  status                 TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','reviewing','closed','cancelled')),
  deadline               TIMESTAMPTZ NOT NULL,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (accepted_count <= max_accepted),
  CHECK (budget_cents = payout_per_clip_cents * max_accepted)
);

CREATE INDEX clip_campaigns_mm_idx     ON public.clip_campaigns (market_maker_user_id, status);
CREATE INDEX clip_campaigns_browse_idx ON public.clip_campaigns (deadline)
  WHERE status IN ('open','reviewing');

COMMENT ON TABLE public.clip_campaigns IS
  'Clip bounty campaigns (Collections N7). NEW namespace — the archived mig-089 '
  'campaigns tables are untouched. budget_cents is escrowed in full at creation; '
  'escrow leaves ONLY via clip_campaign_accept (payout) or the refund paths.';
COMMENT ON COLUMN public.clip_campaigns.source_moment_id IS
  'REPO-CHECK 1.6 / Hard Rule 37 tether. When set, this campaign''s clips are cut '
  'from a post the Market Maker already proved they own, so an accepted clip may '
  'feed the mint pipeline as its device-clip leg. NULL = licensing-only.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- clip_campaign_submissions — moderation-first by construction
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.clip_campaign_submissions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id       UUID NOT NULL REFERENCES public.clip_campaigns(id),
  clipper_user_id   UUID NOT NULL REFERENCES auth.users(id),
  clip_path         TEXT NOT NULL,          -- clip-staging object path
  frame_paths       TEXT[],                 -- moderation sample frames
  trim_start_ms     INTEGER,
  trim_end_ms       INTEGER,
  note              TEXT CHECK (note IS NULL OR length(note) <= 500),
  status            TEXT NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted','in_moderation','rejected','approved','accepted','paid')),
  moderation_labels JSONB,
  moderation_model  TEXT,
  moderated_at      TIMESTAMPTZ,
  accepted_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX clip_submissions_campaign_idx ON public.clip_campaign_submissions (campaign_id, status);
CREATE INDEX clip_submissions_clipper_idx  ON public.clip_campaign_submissions (clipper_user_id, created_at DESC);

COMMENT ON TABLE public.clip_campaign_submissions IS
  'Clipper submissions. A row is invisible to the Market Maker until moderation '
  'sets status to approved — enforced in RLS, not in application code.';

-- ═══════════════════════════════════════════════════════════════════════════════
-- clip_campaign_moderation — service-only human-review queue (mig-141 vocabulary)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.clip_campaign_moderation (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id   UUID NOT NULL REFERENCES public.clip_campaign_submissions(id) ON DELETE CASCADE,
  reason          TEXT NOT NULL CHECK (reason IN ('minor_safety','third_party_likeness','other')),
  labels          JSONB,
  status          TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','resolved_blocked','resolved_cleared')),
  resolution_note TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at     TIMESTAMPTZ
);

CREATE INDEX clip_moderation_open_idx ON public.clip_campaign_moderation (status, created_at)
  WHERE status = 'open';

COMMENT ON TABLE public.clip_campaign_moderation IS
  'Campaign-clip human-review queue — the moderation_escalations (mig 141) posture '
  'verbatim: service-only, NO client RLS policies. Moderation labels are sensitive '
  'and minor-safety cases must never be visible to, or influenced by, either the '
  'clipper or the Market Maker. Clearing a case never auto-approves a clip.';

ALTER TABLE public.clip_campaign_moderation ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: service_role bypasses RLS; clients see nothing.

-- ═══════════════════════════════════════════════════════════════════════════════
-- clip_campaign_payments — append-only money ledger (governance: INSERT-only)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.clip_campaign_payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id     UUID NOT NULL REFERENCES public.clip_campaigns(id),
  -- UNIQUE: one payment per submission, ever. This is the idempotency anchor —
  -- a replayed accept cannot double-pay even under a race.
  submission_id   UUID NOT NULL UNIQUE REFERENCES public.clip_campaign_submissions(id),
  clipper_user_id UUID NOT NULL REFERENCES auth.users(id),
  gross_cents     INTEGER NOT NULL CHECK (gross_cents > 0),
  fee_cents       INTEGER NOT NULL CHECK (fee_cents >= 0),
  net_cents       INTEGER NOT NULL CHECK (net_cents > 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX clip_payments_campaign_idx ON public.clip_campaign_payments (campaign_id);
CREATE INDEX clip_payments_clipper_idx  ON public.clip_campaign_payments (clipper_user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.clip_campaign_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only (no UPDATE/DELETE)', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER clip_campaign_payments_no_mutation
  BEFORE UPDATE OR DELETE ON public.clip_campaign_payments
  FOR EACH ROW EXECUTE FUNCTION public.clip_campaign_block_mutation();

-- ═══════════════════════════════════════════════════════════════════════════════
-- RLS — the moderation wall lives HERE, not in application code
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.clip_campaigns            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clip_campaign_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clip_campaign_payments    ENABLE ROW LEVEL SECURITY;

-- Campaigns are a public board (that is the point) once they are live.
CREATE POLICY "clip_campaigns_select_public" ON public.clip_campaigns
  FOR SELECT USING (status IN ('open','reviewing','closed') OR auth.uid() = market_maker_user_id);

-- THE WALL: a clipper sees their own submissions in any state; the Market Maker
-- sees a submission ONLY once moderation has approved it. 'submitted',
-- 'in_moderation' and 'rejected' rows are structurally invisible to them.
CREATE POLICY "clip_submissions_select_clipper_or_moderated_mm"
  ON public.clip_campaign_submissions
  FOR SELECT USING (
    auth.uid() = clipper_user_id
    OR (
      status IN ('approved','accepted','paid')
      AND EXISTS (
        SELECT 1 FROM public.clip_campaigns c
        WHERE c.id = campaign_id AND c.market_maker_user_id = auth.uid()
      )
    )
  );

CREATE POLICY "clip_payments_select_party" ON public.clip_campaign_payments
  FOR SELECT USING (
    auth.uid() = clipper_user_id
    OR EXISTS (
      SELECT 1 FROM public.clip_campaigns c
      WHERE c.id = campaign_id AND c.market_maker_user_id = auth.uid()
    )
  );

-- No client INSERT/UPDATE/DELETE policies anywhere: every write goes through the
-- SECURITY DEFINER RPCs below.

-- ═══════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_campaign_mint_eligible(p_campaign UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT source_moment_id IS NOT NULL FROM public.clip_campaigns WHERE id = p_campaign;
$$;

COMMENT ON FUNCTION public.clip_campaign_mint_eligible(UUID) IS
  'REPO-CHECK 1.6: TRUE only when the campaign is tethered to a moment the Market '
  'Maker owns. Even then the campaign never mints — it hands the clip to the '
  'existing pipeline, which owns consent (Hard Rule 37).';

-- ═══════════════════════════════════════════════════════════════════════════════
-- CREATE — Market Maker only; the full budget is escrowed up front
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_campaign_create_internal(
  p_user UUID, p_title TEXT, p_brief TEXT,
  p_payout_per_clip_cents INTEGER, p_max_accepted INTEGER,
  p_deadline TIMESTAMPTZ, p_source_moment_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_budget INTEGER;
  v_moment public.moments%ROWTYPE;
  v_id     UUID;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  -- Market Maker role (N2): KYC + a linked social. Campaigns move real money out.
  IF NOT public.is_collection_minter(p_user) THEN
    RAISE EXCEPTION 'Clip campaigns require KYC verification and a linked social profile';
  END IF;
  IF p_payout_per_clip_cents <= 0 THEN RAISE EXCEPTION 'payout must be > 0'; END IF;
  IF p_max_accepted < 1 OR p_max_accepted > 500 THEN
    RAISE EXCEPTION 'max_accepted must be 1..500';
  END IF;
  IF p_deadline <= NOW() THEN RAISE EXCEPTION 'deadline must be in the future'; END IF;

  -- REPO-CHECK 1.6: a tether must be a moment this Market Maker actually owns and
  -- that already cleared pre-gen moderation. Anything else is licensing-only.
  IF p_source_moment_id IS NOT NULL THEN
    SELECT * INTO v_moment FROM public.moments WHERE id = p_source_moment_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Source moment % not found', p_source_moment_id; END IF;
    IF v_moment.owner_user_id <> p_user THEN
      RAISE EXCEPTION 'A campaign may only be tethered to your own verified post (Hard Rule 37)';
    END IF;
    IF v_moment.moderation_status IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION 'The tethered post has not cleared moderation';
    END IF;
  END IF;

  v_budget := p_payout_per_clip_cents * p_max_accepted;

  INSERT INTO public.clip_campaigns
    (market_maker_user_id, title, brief, source_moment_id, payout_per_clip_cents,
     max_accepted, budget_cents, escrow_remaining_cents, deadline)
  VALUES (p_user, btrim(p_title), btrim(p_brief), p_source_moment_id,
          p_payout_per_clip_cents, p_max_accepted, v_budget, v_budget, p_deadline)
  RETURNING id INTO v_id;

  -- Escrow the whole budget now (USD rail, Hard Rule 33 — never token_transactions).
  PERFORM public.ccg_usd_debit(p_user, v_budget, v_id, 'Clip campaign escrow');

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.clip_campaign_create(
  p_title TEXT, p_brief TEXT, p_payout_per_clip_cents INTEGER,
  p_max_accepted INTEGER, p_deadline TIMESTAMPTZ, p_source_moment_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.clip_campaign_create_internal(auth.uid(), p_title, p_brief,
    p_payout_per_clip_cents, p_max_accepted, p_deadline, p_source_moment_id);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SUBMIT — clippers submit freely (REPO-CHECK N7.2); the clip goes straight into
-- moderation and is invisible to the Market Maker until it clears.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_submission_create_internal(
  p_user UUID, p_campaign UUID, p_clip_path TEXT,
  p_frame_paths TEXT[] DEFAULT NULL, p_trim_start_ms INTEGER DEFAULT NULL,
  p_trim_end_ms INTEGER DEFAULT NULL, p_note TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_c  public.clip_campaigns%ROWTYPE;
  v_id UUID;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_clip_path IS NULL OR btrim(p_clip_path) = '' THEN
    RAISE EXCEPTION 'A clip upload is required';
  END IF;
  -- The upload must live under the caller's own prefix in clip-staging (mirrors the
  -- mig-146 storage RLS, re-checked here so the RPC cannot be pointed elsewhere).
  IF split_part(p_clip_path, '/', 1) <> p_user::TEXT THEN
    RAISE EXCEPTION 'Clip path must live under your own clip-staging prefix';
  END IF;

  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = p_campaign FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Campaign % not found', p_campaign; END IF;
  IF v_c.status <> 'open' THEN RAISE EXCEPTION 'Campaign is not open for submissions'; END IF;
  IF v_c.deadline <= NOW() THEN RAISE EXCEPTION 'Campaign deadline has passed'; END IF;
  IF v_c.market_maker_user_id = p_user THEN
    RAISE EXCEPTION 'You cannot submit to your own campaign';
  END IF;

  INSERT INTO public.clip_campaign_submissions
    (campaign_id, clipper_user_id, clip_path, frame_paths, trim_start_ms, trim_end_ms,
     note, status)
  VALUES (p_campaign, p_user, p_clip_path, p_frame_paths, p_trim_start_ms, p_trim_end_ms,
          p_note, 'in_moderation')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.clip_submission_create(
  p_campaign UUID, p_clip_path TEXT, p_frame_paths TEXT[] DEFAULT NULL,
  p_trim_start_ms INTEGER DEFAULT NULL, p_trim_end_ms INTEGER DEFAULT NULL,
  p_note TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.clip_submission_create_internal(auth.uid(), p_campaign, p_clip_path,
    p_frame_paths, p_trim_start_ms, p_trim_end_ms, p_note);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- MODERATE — SERVICE-ONLY, exactly like moment_pre_gen_moderate (mig 141).
-- A client that could call this could self-approve its own clip.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_submission_moderate(
  p_submission UUID, p_verdict TEXT, p_labels JSONB DEFAULT NULL,
  p_third_party BOOLEAN DEFAULT FALSE, p_model TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_status TEXT;
BEGIN
  IF p_verdict NOT IN ('approved','rejected','escalated') THEN
    RAISE EXCEPTION 'Invalid moderation verdict: %', p_verdict;
  END IF;

  -- minor-safety ('escalated') is absolute: blocked AND queued. Clearing the case
  -- never auto-approves — a human re-runs moderation explicitly.
  v_status := CASE WHEN p_verdict = 'approved' THEN 'approved' ELSE 'rejected' END;

  UPDATE public.clip_campaign_submissions
  SET status = v_status, moderation_labels = p_labels, moderation_model = p_model,
      moderated_at = NOW(), updated_at = NOW()
  WHERE id = p_submission
    AND status IN ('submitted','in_moderation');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % is not awaiting moderation', p_submission;
  END IF;

  IF p_verdict = 'escalated' THEN
    INSERT INTO public.clip_campaign_moderation (submission_id, reason, labels)
    VALUES (p_submission, 'minor_safety', p_labels);
  ELSIF p_verdict = 'approved' AND COALESCE(p_third_party, FALSE) THEN
    INSERT INTO public.clip_campaign_moderation (submission_id, reason, labels)
    VALUES (p_submission, 'third_party_likeness', p_labels);
  END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- ACCEPT + PAY — atomic, idempotent, escrow-bounded
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_campaign_accept_internal(
  p_user UUID, p_submission UUID
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_s      public.clip_campaign_submissions%ROWTYPE;
  v_c      public.clip_campaigns%ROWTYPE;
  v_pay    UUID;
  v_fee    INTEGER;
  v_net    INTEGER;
  v_feebps INTEGER;
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_s FROM public.clip_campaign_submissions
  WHERE id = p_submission FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Submission % not found', p_submission; END IF;

  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = v_s.campaign_id FOR UPDATE;
  IF v_c.market_maker_user_id <> p_user THEN
    RAISE EXCEPTION 'Only the campaign owner may accept submissions';
  END IF;

  -- Idempotency: the payment ledger is the source of truth (UNIQUE on submission).
  SELECT id INTO v_pay FROM public.clip_campaign_payments WHERE submission_id = p_submission;
  IF v_pay IS NOT NULL THEN RETURN v_pay; END IF;

  -- Only a MODERATION-APPROVED clip can ever be accepted.
  IF v_s.status <> 'approved' THEN
    RAISE EXCEPTION 'Submission is not approved by moderation (status %)', v_s.status;
  END IF;
  IF v_c.status NOT IN ('open','reviewing') THEN
    RAISE EXCEPTION 'Campaign is % and cannot accept clips', v_c.status;
  END IF;
  IF v_c.accepted_count >= v_c.max_accepted THEN
    RAISE EXCEPTION 'Campaign has already accepted its maximum of % clips', v_c.max_accepted;
  END IF;
  IF v_c.escrow_remaining_cents < v_c.payout_per_clip_cents THEN
    RAISE EXCEPTION 'Campaign escrow is exhausted';
  END IF;

  -- REPO-CHECK N7.2: the money gate lands HERE, not at submission time.
  IF NOT public.is_eligible_for_real_money(v_s.clipper_user_id) THEN
    RAISE EXCEPTION 'This clipper must verify their identity before they can be paid';
  END IF;

  v_feebps := COALESCE(public.platform_fee('clip_campaign_fee_bps'), 0);
  v_fee := (v_c.payout_per_clip_cents * v_feebps) / 10000;
  v_net := v_c.payout_per_clip_cents - v_fee;
  IF v_net <= 0 THEN RAISE EXCEPTION 'Fee configuration would leave the clipper nothing'; END IF;

  INSERT INTO public.clip_campaign_payments
    (campaign_id, submission_id, clipper_user_id, gross_cents, fee_cents, net_cents)
  VALUES (v_c.id, p_submission, v_s.clipper_user_id, v_c.payout_per_clip_cents, v_fee, v_net)
  RETURNING id INTO v_pay;

  UPDATE public.clip_campaign_submissions
  SET status = 'paid', accepted_at = NOW(), updated_at = NOW()
  WHERE id = p_submission;

  UPDATE public.clip_campaigns
  SET accepted_count         = accepted_count + 1,
      escrow_remaining_cents = escrow_remaining_cents - v_c.payout_per_clip_cents,
      status = CASE WHEN accepted_count + 1 >= max_accepted THEN 'closed' ELSE status END,
      updated_at = NOW()
  WHERE id = v_c.id;

  -- Escrow → clipper, net of the platform fee. The escrow was already debited from
  -- the Market Maker at creation, so this is the only outbound leg.
  PERFORM public.ccg_usd_credit(v_s.clipper_user_id, v_net, v_pay,
                                'Clip campaign payout', 'distribution');

  RETURN v_pay;
END;
$$;

CREATE OR REPLACE FUNCTION public.clip_campaign_accept(p_submission UUID)
RETURNS UUID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.clip_campaign_accept_internal(auth.uid(), p_submission);
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- CANCEL / EXPIRE — the ONLY other way escrow moves. Refunds what is left.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.clip_campaign_cancel_internal(p_user UUID, p_campaign UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_c      public.clip_campaigns%ROWTYPE;
  v_refund INTEGER;
BEGIN
  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = p_campaign FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Campaign % not found', p_campaign; END IF;
  IF v_c.market_maker_user_id <> p_user THEN
    RAISE EXCEPTION 'Only the campaign owner may cancel it';
  END IF;
  IF v_c.status IN ('cancelled','closed') THEN
    RETURN 0;   -- idempotent: escrow already settled
  END IF;

  v_refund := v_c.escrow_remaining_cents;

  UPDATE public.clip_campaigns
  SET status = 'cancelled', escrow_remaining_cents = 0, updated_at = NOW()
  WHERE id = p_campaign;

  -- Pending clips can never be accepted after a cancel; reject them explicitly so
  -- no submission is left dangling in a state the clipper cannot read the end of.
  UPDATE public.clip_campaign_submissions
  SET status = 'rejected', updated_at = NOW()
  WHERE campaign_id = p_campaign AND status IN ('submitted','in_moderation','approved');

  IF v_refund > 0 THEN
    PERFORM public.ccg_usd_credit(v_c.market_maker_user_id, v_refund, p_campaign,
                                  'Clip campaign escrow refund', 'refund');
  END IF;

  RETURN v_refund;
END;
$$;

CREATE OR REPLACE FUNCTION public.clip_campaign_cancel(p_campaign UUID)
RETURNS INTEGER
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.clip_campaign_cancel_internal(auth.uid(), p_campaign);
$$;

-- Deadline sweep (pg_cron / admin): expire open campaigns and refund the remainder.
CREATE OR REPLACE FUNCTION public.clip_campaigns_expire_due()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE r RECORD; v_n INTEGER := 0;
BEGIN
  FOR r IN
    SELECT id, market_maker_user_id, escrow_remaining_cents
    FROM public.clip_campaigns
    WHERE status IN ('open','reviewing') AND deadline <= NOW()
    FOR UPDATE
  LOOP
    UPDATE public.clip_campaigns
    SET status = 'closed', escrow_remaining_cents = 0, updated_at = NOW()
    WHERE id = r.id;
    UPDATE public.clip_campaign_submissions
    SET status = 'rejected', updated_at = NOW()
    WHERE campaign_id = r.id AND status IN ('submitted','in_moderation','approved');
    IF r.escrow_remaining_cents > 0 THEN
      PERFORM public.ccg_usd_credit(r.market_maker_user_id, r.escrow_remaining_cents,
                                    r.id, 'Clip campaign expiry refund', 'refund');
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- GRANTS — clients get the three wrappers; everything else is service-only.
-- ═══════════════════════════════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION public.clip_campaign_create_internal(UUID, TEXT, TEXT, INTEGER, INTEGER, TIMESTAMPTZ, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clip_submission_create_internal(UUID, UUID, TEXT, TEXT[], INTEGER, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clip_campaign_accept_internal(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clip_campaign_cancel_internal(UUID, UUID) FROM PUBLIC, anon, authenticated;
-- Moderation and the expiry sweep must never be client-callable.
REVOKE ALL ON FUNCTION public.clip_submission_moderate(UUID, TEXT, JSONB, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clip_campaigns_expire_due() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.clip_campaign_create(TEXT, TEXT, INTEGER, INTEGER, TIMESTAMPTZ, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clip_campaign_create(TEXT, TEXT, INTEGER, INTEGER, TIMESTAMPTZ, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.clip_submission_create(UUID, TEXT, TEXT[], INTEGER, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clip_submission_create(UUID, TEXT, TEXT[], INTEGER, INTEGER, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.clip_campaign_accept(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clip_campaign_accept(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.clip_campaign_cancel(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clip_campaign_cancel(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.clip_campaign_mint_eligible(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clip_campaign_mint_eligible(UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — create+escrow · submit · moderation wall · accept+pay ·
-- idempotency · escrow bound · cancel refund · archived campaigns untouched.
-- Runs on the mig-155 smoke identities (is_test_account; P7 sweeps them).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_mm UUID; v_clip UUID;
  v_camp UUID; v_s1 UUID; v_s2 UUID; v_s3 UUID; v_pay UUID; v_pay2 UUID;
  v_usd0 BIGINT; v_usd1 BIGINT; v_cusd0 BIGINT; v_cusd1 BIGINT; v_cur BIGINT;
  v_err BOOLEAN; v_msg TEXT; v_n INTEGER; v_pol TEXT;
  v_c public.clip_campaigns%ROWTYPE;
BEGIN
  SELECT id INTO v_mm   FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_clip FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_mm IS NULL OR v_clip IS NULL THEN
    RAISE EXCEPTION 'mig 176 smoke needs the mig-155 smoke users';
  END IF;
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'N7 smoke SKIPPED (battle_payments_mode is live)';
    RETURN;
  END IF;

  -- Market Maker eligibility (mig-172 pattern; idempotent against prior residue).
  IF NOT public.is_collection_minter(v_mm) THEN
    INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_mm, 'approved');
    INSERT INTO public.platform_connections
      (user_id, platform, platform_user_id, platform_username, access_token, is_active)
    VALUES (v_mm, 'youtube', 'n7-smoke', '@n7_smoke', 'tok', TRUE);
  END IF;

  PERFORM public.sim_seed_balance(v_mm);
  PERFORM public.sim_seed_balance(v_clip);
  PERFORM public.ccg_usd_credit(v_mm, 100000, gen_random_uuid(), 'N7 smoke float', 'distribution');
  SELECT balance_usd_cents INTO v_usd0  FROM public.sim_usd_balances WHERE user_id = v_mm;
  SELECT balance_usd_cents INTO v_cusd0 FROM public.sim_usd_balances WHERE user_id = v_clip;

  -- ── create: budget = 500c * 2 = 1000c, escrowed immediately ─────────────────
  v_camp := public.clip_campaign_create_internal(
    v_mm, 'N7 smoke bounty', 'Cut a 10s highlight.', 500, 2, NOW() + INTERVAL '7 days');
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_mm;
  IF v_cur <> v_usd0 - 1000 THEN
    RAISE EXCEPTION 'SMOKE FAIL: full budget must be escrowed at creation (was %, now %)', v_usd0, v_cur;
  END IF;
  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = v_camp;
  IF v_c.escrow_remaining_cents <> 1000 OR v_c.budget_cents <> 1000 THEN
    RAISE EXCEPTION 'SMOKE FAIL: escrow bookkeeping wrong at creation';
  END IF;
  -- licensing-only by default (REPO-CHECK 1.6)
  IF public.clip_campaign_mint_eligible(v_camp) THEN
    RAISE EXCEPTION 'SMOKE FAIL: an untethered campaign must NOT be mint-eligible';
  END IF;

  -- a tether to someone else's post is refused (Hard Rule 37 holds)
  v_err := FALSE;
  BEGIN
    PERFORM public.clip_campaign_create_internal(
      v_mm, 'bad tether', 'x', 100, 1, NOW() + INTERVAL '1 day',
      (SELECT id FROM public.moments WHERE owner_user_id <> v_mm LIMIT 1));
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%your own verified post%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: tethering to a post you do not own must be blocked (got %)', v_msg;
  END IF;

  -- ── submit: no KYC needed to submit (REPO-CHECK N7.2) ───────────────────────
  v_s1 := public.clip_submission_create_internal(
    v_clip, v_camp, v_clip::TEXT || '/' || v_camp::TEXT || '/clip.mp4');
  IF (SELECT status FROM public.clip_campaign_submissions WHERE id = v_s1) <> 'in_moderation' THEN
    RAISE EXCEPTION 'SMOKE FAIL: a new submission must land in moderation, never visible';
  END IF;

  -- a clip path outside the clipper's own prefix is refused
  v_err := FALSE;
  BEGIN
    PERFORM public.clip_submission_create_internal(v_clip, v_camp, v_mm::TEXT || '/x/clip.mp4');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: cross-prefix clip path must be blocked'; END IF;

  -- the Market Maker cannot submit to their own campaign
  v_err := FALSE;
  BEGIN
    PERFORM public.clip_submission_create_internal(v_mm, v_camp, v_mm::TEXT || '/c/clip.mp4');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: self-submission must be blocked'; END IF;

  -- ── the moderation wall ─────────────────────────────────────────────────────
  -- an un-moderated clip can never be accepted
  v_err := FALSE;
  BEGIN
    PERFORM public.clip_campaign_accept_internal(v_mm, v_s1);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%not approved by moderation%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: accepting an unmoderated clip must be blocked (got %)', v_msg;
  END IF;

  -- minor-safety escalation: blocked AND queued, and it stays blocked
  v_s2 := public.clip_submission_create_internal(v_clip, v_camp, v_clip::TEXT || '/b/clip.mp4');
  PERFORM public.clip_submission_moderate(v_s2, 'escalated', '{"minor_safety":0.99}'::JSONB, FALSE, 'sim');
  IF (SELECT status FROM public.clip_campaign_submissions WHERE id = v_s2) <> 'rejected' THEN
    RAISE EXCEPTION 'SMOKE FAIL: an escalated clip must be rejected (minor-safety is absolute)';
  END IF;
  SELECT COUNT(*) INTO v_n FROM public.clip_campaign_moderation
  WHERE submission_id = v_s2 AND reason = 'minor_safety' AND status = 'open';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: escalation must be queued for human review'; END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.clip_campaign_accept_internal(v_mm, v_s2);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: a rejected clip must never be acceptable'; END IF;

  -- the RLS wall itself: the Market Maker's read path is gated on approved states
  SELECT qual::TEXT INTO v_pol FROM pg_policies
  WHERE tablename = 'clip_campaign_submissions'
    AND policyname = 'clip_submissions_select_clipper_or_moderated_mm';
  IF v_pol IS NULL OR v_pol NOT LIKE '%approved%' OR v_pol NOT LIKE '%clipper_user_id%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the moderation RLS wall is missing or weakened';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies
             WHERE tablename = 'clip_campaign_moderation') THEN
    RAISE EXCEPTION 'SMOKE FAIL: the review queue must have NO client policies';
  END IF;

  -- ── accept + pay ────────────────────────────────────────────────────────────
  PERFORM public.clip_submission_moderate(v_s1, 'approved', NULL, FALSE, 'sim');

  -- clipper is not KYC'd yet → the money gate refuses (REPO-CHECK N7.2)
  IF NOT public.is_eligible_for_real_money(v_clip) THEN
    v_err := FALSE;
    BEGIN
      PERFORM public.clip_campaign_accept_internal(v_mm, v_s1);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
    END;
    IF NOT v_err OR v_msg NOT LIKE '%verify their identity%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: paying an unverified clipper must be blocked (got %)', v_msg;
    END IF;
    INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_clip, 'approved');
  END IF;

  v_pay := public.clip_campaign_accept_internal(v_mm, v_s1);
  -- 500c gross, 10% fee = 50c, clipper nets 450c
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_clip;
  IF v_cur <> v_cusd0 + 450 THEN
    RAISE EXCEPTION 'SMOKE FAIL: clipper must net 450c (was %, now %)', v_cusd0, v_cur;
  END IF;
  IF (SELECT status FROM public.clip_campaign_submissions WHERE id = v_s1) <> 'paid' THEN
    RAISE EXCEPTION 'SMOKE FAIL: an accepted submission must end up paid';
  END IF;
  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = v_camp;
  IF v_c.escrow_remaining_cents <> 500 OR v_c.accepted_count <> 1 THEN
    RAISE EXCEPTION 'SMOKE FAIL: escrow/accepted bookkeeping wrong after payout';
  END IF;

  -- idempotency: replaying accept returns the same payment, pays nothing more
  v_pay2 := public.clip_campaign_accept_internal(v_mm, v_s1);
  IF v_pay2 <> v_pay THEN RAISE EXCEPTION 'SMOKE FAIL: replayed accept must return the same payment'; END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_clip;
  IF v_cur <> v_cusd0 + 450 THEN RAISE EXCEPTION 'SMOKE FAIL: replayed accept must not double-pay'; END IF;
  SELECT COUNT(*) INTO v_n FROM public.clip_campaign_payments WHERE submission_id = v_s1;
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: exactly one payment row per submission'; END IF;

  -- ── cancel refunds exactly the remaining escrow ─────────────────────────────
  SELECT balance_usd_cents INTO v_usd1 FROM public.sim_usd_balances WHERE user_id = v_mm;
  IF public.clip_campaign_cancel_internal(v_mm, v_camp) <> 500 THEN
    RAISE EXCEPTION 'SMOKE FAIL: cancel must refund the remaining 500c';
  END IF;
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_mm;
  IF v_cur <> v_usd1 + 500 THEN RAISE EXCEPTION 'SMOKE FAIL: refund must land in the escrow owner''s balance'; END IF;
  SELECT * INTO v_c FROM public.clip_campaigns WHERE id = v_camp;
  IF v_c.status <> 'cancelled' OR v_c.escrow_remaining_cents <> 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: a cancelled campaign must hold no escrow';
  END IF;
  -- cancel is idempotent (no second refund)
  IF public.clip_campaign_cancel_internal(v_mm, v_camp) <> 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: repeat cancel must refund nothing';
  END IF;

  -- money conservation: MM out 1000, back 500 refund; clipper in 450; fee 50 kept.
  SELECT balance_usd_cents INTO v_cur FROM public.sim_usd_balances WHERE user_id = v_mm;
  IF v_cur <> v_usd0 - 500 THEN
    RAISE EXCEPTION 'SMOKE FAIL: MM net must be -500c (paid one 500c clip), got % vs %', v_cur, v_usd0;
  END IF;

  -- ── the archived mig-089 system is untouched ────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'campaigns_archived_ledger') THEN
    RAISE NOTICE 'N7 smoke: no campaigns_archived_ledger present (nothing to protect)';
  END IF;

  RAISE NOTICE 'N7 smoke OK: escrow at create, moderation wall holds, minor-safety absolute, pay idempotent, refunds exact';
END $$;
