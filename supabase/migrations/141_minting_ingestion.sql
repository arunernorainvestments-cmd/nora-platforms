-- Migration 141: M-P1 — ingestion consent + pre-generation moderation backend.
--
-- Minting spec PHASE 1: a moderated, OWNED, attributable source before any
-- generation runs. The DB owns three invariants here:
--   1. Source allowlist (Hard Rule 37): consent-minted moments come only from
--      tiktok / instagram / youtube — enforced in moment_record, the single
--      SECURITY DEFINER write path (moments has no client INSERT policy).
--   2. Pre-gen moderation verdict is recorded server-side with its labels; the
--      minor-safety screen is ABSOLUTE — an escalated moment is rejected AND
--      queued for human review; generation never runs (moment_mint /
--      cinematic-mint already require moderation_status = 'approved').
--   3. Mint-pipeline functions are service-only: clients could previously
--      EXECUTE moment_moderate / moment_mint (SECURITY DEFINER default grant)
--      and self-approve — revoked here.

-- ── moments: pre-gen moderation detail ────────────────────────────────────────────
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS moderation_labels    JSONB,        -- classifier output (per category)
  ADD COLUMN IF NOT EXISTS moderation_model     TEXT,         -- 'sim' | model id that produced the verdict
  ADD COLUMN IF NOT EXISTS moderated_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS third_party_likeness BOOLEAN NOT NULL DEFAULT FALSE;  -- flagged for review, not blocked

COMMENT ON COLUMN public.moments.third_party_likeness IS
  'Pre-gen moderation flag: the owner''s post prominently features other identifiable '
  'people (minting spec P1 Layer 2). Flag-for-review, not a block; review rows live in '
  'moderation_escalations.';

-- ── moderation_escalations: human-review queue ────────────────────────────────────
-- minor_safety rows are the absolute screen (moment stays rejected regardless of
-- case resolution — clearing a case never auto-approves; a human re-runs moderation
-- explicitly). third_party_likeness rows are review-only (moment stays approved).
CREATE TABLE public.moderation_escalations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  moment_id       UUID NOT NULL REFERENCES public.moments(id) ON DELETE CASCADE,
  reason          TEXT NOT NULL CHECK (reason IN ('minor_safety','third_party_likeness','other')),
  labels          JSONB,
  status          TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','resolved_blocked','resolved_cleared')),
  resolution_note TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at     TIMESTAMPTZ
);

CREATE INDEX moderation_escalations_open_idx
  ON public.moderation_escalations (status, created_at) WHERE status = 'open';
CREATE INDEX moderation_escalations_moment_idx
  ON public.moderation_escalations (moment_id);

COMMENT ON TABLE public.moderation_escalations IS
  'Pre-gen moderation human-review queue (minting spec P1). Service-only: no client '
  'RLS policies — moderation labels are sensitive and minor-safety cases must never '
  'be visible to (or influenced by) the minting user.';

ALTER TABLE public.moderation_escalations ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: service_role bypasses RLS; clients see nothing.

-- ── moment_record: + source allowlist + creator handle ────────────────────────────
-- Recreated with p_handle (drop first: adding a defaulted param would otherwise
-- create an ambiguous overload).
DROP FUNCTION IF EXISTS public.moment_record(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN);

CREATE FUNCTION public.moment_record(
  p_owner UUID, p_platform TEXT, p_external_id TEXT, p_url TEXT,
  p_thumbnail TEXT, p_engagement BIGINT, p_consent BOOLEAN DEFAULT TRUE,
  p_handle TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  -- Hard Rule 37 source allowlist. X/Facebook deferred; no raw upload path exists.
  IF p_platform NOT IN ('tiktok','instagram','youtube') THEN
    RAISE EXCEPTION 'Source platform not allowlisted for minting: %', p_platform;
  END IF;

  INSERT INTO public.moments
    (owner_user_id, source_platform, source_external_id, source_url, thumbnail_url,
     engagement_count, engagement_synced_at, consent_granted_at, creator_handle)
  VALUES (p_owner, p_platform, p_external_id, p_url, p_thumbnail,
     GREATEST(COALESCE(p_engagement,0),0), NOW(),
     CASE WHEN p_consent THEN NOW() ELSE NULL END, p_handle)
  ON CONFLICT (source_platform, source_external_id) DO UPDATE
    SET engagement_count = GREATEST(EXCLUDED.engagement_count, 0),
        engagement_synced_at = NOW(),
        thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, public.moments.thumbnail_url),
        creator_handle = COALESCE(EXCLUDED.creator_handle, public.moments.creator_handle)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ── moment_pre_gen_moderate: record the Layer-2 verdict + escalations ─────────────
-- Verdicts: 'approved' (may proceed to generation), 'rejected' (blocked),
-- 'escalated' (minor-safety hit: blocked AND queued for human review — absolute,
-- Hard Rule 37). Third-party likeness flags for review without blocking.
CREATE FUNCTION public.moment_pre_gen_moderate(
  p_moment_id   UUID,
  p_verdict     TEXT,
  p_labels      JSONB   DEFAULT NULL,
  p_third_party BOOLEAN DEFAULT FALSE,
  p_model       TEXT    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_verdict NOT IN ('approved','rejected','escalated') THEN
    RAISE EXCEPTION 'Invalid pre-gen moderation verdict: %', p_verdict;
  END IF;

  UPDATE public.moments
  SET moderation_status    = CASE WHEN p_verdict = 'approved' THEN 'approved' ELSE 'rejected' END,
      mint_status          = CASE WHEN p_verdict = 'approved' THEN 'moderated' ELSE 'rejected' END,
      moderation_labels    = p_labels,
      moderation_model     = p_model,
      moderated_at         = NOW(),
      third_party_likeness = COALESCE(p_third_party, FALSE)
  WHERE id = p_moment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Moment not found: %', p_moment_id; END IF;

  IF p_verdict = 'escalated' THEN
    INSERT INTO public.moderation_escalations (moment_id, reason, labels)
    VALUES (p_moment_id, 'minor_safety', p_labels);
  ELSIF p_verdict = 'approved' AND COALESCE(p_third_party, FALSE) THEN
    INSERT INTO public.moderation_escalations (moment_id, reason, labels)
    VALUES (p_moment_id, 'third_party_likeness', p_labels);
  END IF;
END;
$$;

-- ── service-only execution for the whole mint pipeline ────────────────────────────
-- SECURITY DEFINER functions default to PUBLIC EXECUTE; these must only ever run
-- from edge functions with the service key (a client that can call moment_moderate
-- could self-approve its own pre-gen moderation).
REVOKE ALL ON FUNCTION public.moment_record(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moment_pre_gen_moderate(UUID, TEXT, JSONB, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moment_moderate(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moment_recommend(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moment_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: allowlist raises off-list; escalation rejects + queues;
-- third-party flag approves + queues review.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID;
  v_moment UUID;
  v_err BOOLEAN := FALSE;
  v_status TEXT;
  v_n INT;
BEGIN
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'M-P1 smoke SKIPPED (no auth user in this environment)';
    RETURN;
  END IF;

  -- Off-allowlist source must raise (Hard Rule 37).
  BEGIN
    PERFORM public.moment_record(v_user, 'twitch', 'mp1-smoke-x', 'https://example.com', NULL, 0, TRUE, NULL);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: off-allowlist platform must be rejected'; END IF;

  -- Minor-safety escalation: moment rejected + escalation row queued.
  v_moment := public.moment_record(v_user, 'youtube', 'mp1-smoke-' || gen_random_uuid()::TEXT,
                                   'https://example.com/post', NULL, 1000, TRUE, '@smoke');
  PERFORM public.moment_pre_gen_moderate(v_moment, 'escalated',
    '{"minor_safety": true}'::JSONB, FALSE, 'sim');
  SELECT moderation_status INTO v_status FROM public.moments WHERE id = v_moment;
  IF v_status <> 'rejected' THEN RAISE EXCEPTION 'SMOKE FAIL: escalated moment must be rejected'; END IF;
  SELECT COUNT(*) INTO v_n FROM public.moderation_escalations
  WHERE moment_id = v_moment AND reason = 'minor_safety' AND status = 'open';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: minor-safety escalation row missing'; END IF;

  -- Third-party likeness: approved + flagged + review row.
  PERFORM public.moment_pre_gen_moderate(v_moment, 'approved',
    '{"third_party_likeness": true}'::JSONB, TRUE, 'sim');
  SELECT moderation_status INTO v_status FROM public.moments WHERE id = v_moment;
  IF v_status <> 'approved' THEN RAISE EXCEPTION 'SMOKE FAIL: third-party flag must not block'; END IF;
  SELECT COUNT(*) INTO v_n FROM public.moderation_escalations
  WHERE moment_id = v_moment AND reason = 'third_party_likeness';
  IF v_n <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: third-party review row missing'; END IF;

  -- Clean up smoke rows (escalations cascade).
  DELETE FROM public.moments WHERE id = v_moment;

  RAISE NOTICE 'M-P1 smoke OK: allowlist + escalation + third-party review paths enforced';
END $$;
