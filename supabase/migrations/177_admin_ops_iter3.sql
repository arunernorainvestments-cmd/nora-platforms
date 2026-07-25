-- Migration 177: admin console iteration 3 — campaign moderation queue, the
-- Mystery Box gate, an audit trail, and the missing N7 expiry schedule.
--
-- Three things this fixes, in order of severity:
--
-- 1. **`clip_campaigns_expire_due()` (mig 176) had no scheduler.** Nothing ever
--    called it, so a campaign past its deadline stayed 'open' forever and the
--    Market Maker's escrowed budget was never refunded. Money silently stuck.
--    Now on pg_cron, hourly. This is a bug fix, not an enhancement.
--
-- 2. **The campaign-clip review queue had no console.** mig 176 deliberately used
--    a separate table (`clip_campaign_moderation`) because `moderation_escalations`
--    has a NOT NULL moment_id FK'd to `moments`; the cost was that escalated
--    campaign clips — including minor-safety cases — piled up with nowhere to
--    review them. Wired here.
--
-- 3. **Admin actions left no audit trail.** admin-review only console.log'd them.
--    With founder-gate switches now reachable from the console (marketplace USD
--    lane, battle payments mode, and the Mystery Box gate added below), "who
--    flipped this and when" has to survive log rotation.

-- ═══════════════════════════════════════════════════════════════════════════════
-- admin_audit_log — append-only, service-written, admin-readable
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.admin_audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id    UUID NOT NULL REFERENCES auth.users(id),
  action      TEXT NOT NULL,
  target_id   TEXT,                -- free-form: the row/user/setting acted on
  detail      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX admin_audit_log_time_idx  ON public.admin_audit_log (created_at DESC);
CREATE INDEX admin_audit_log_admin_idx ON public.admin_audit_log (admin_id, created_at DESC);

COMMENT ON TABLE public.admin_audit_log IS
  'Append-only record of every console action (mig 177). Written by admin-review '
  'through admin_log_action; readable by admins only. Never UPDATEd or DELETEd — '
  'the point is that a flipped founder gate is still attributable months later.';

CREATE OR REPLACE FUNCTION public.admin_audit_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'admin_audit_log is append-only (no UPDATE/DELETE)';
END;
$$;

CREATE TRIGGER admin_audit_log_no_mutation
  BEFORE UPDATE OR DELETE ON public.admin_audit_log
  FOR EACH ROW EXECUTE FUNCTION public.admin_audit_block_mutation();

ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_audit_log_select_admin" ON public.admin_audit_log
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin)
  );
-- No client write policy: only admin_log_action writes here.

CREATE OR REPLACE FUNCTION public.admin_log_action(
  p_admin UUID, p_action TEXT, p_target TEXT DEFAULT NULL, p_detail JSONB DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  INSERT INTO public.admin_audit_log (admin_id, action, target_id, detail)
  VALUES (p_admin, p_action, p_target, p_detail);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_log_action(UUID, TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Campaign-clip verdict override — minor-safety stays ABSOLUTE
-- ═══════════════════════════════════════════════════════════════════════════════
-- The mint contract (mig 141) is that clearing an escalation never auto-approves;
-- a human re-runs the verdict explicitly. This is that explicit re-run for campaign
-- clips — with one thing the edge function must not be trusted to remember: a
-- submission carrying a minor-safety case can NEVER be approved from the console,
-- whatever the case's resolution says. Enforced here, in the database.
CREATE OR REPLACE FUNCTION public.admin_clip_submission_verdict_internal(
  p_admin UUID, p_submission UUID, p_approved BOOLEAN
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_approved AND EXISTS (
    SELECT 1 FROM public.clip_campaign_moderation
    WHERE submission_id = p_submission AND reason = 'minor_safety'
  ) THEN
    RAISE EXCEPTION 'A minor-safety clip can never be approved from the console';
  END IF;

  UPDATE public.clip_campaign_submissions
  SET status = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
      updated_at = NOW()
  WHERE id = p_submission
    AND status IN ('submitted','in_moderation','rejected','approved');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % not found or already accepted/paid', p_submission;
  END IF;

  PERFORM public.admin_log_action(
    p_admin, 'clip_submission_verdict', p_submission::TEXT,
    jsonb_build_object('approved', p_approved));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_clip_submission_verdict_internal(UUID, UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Mystery Box gate from the console (G-MYSTERY, Hard Rule 41)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Flipping this off 'disabled' opens the pool submission + award engine. It is a
-- founder call; the console makes it reachable, the audit log makes it attributable.
CREATE OR REPLACE FUNCTION public.admin_set_mystery_mode_internal(
  p_admin UUID, p_mode TEXT
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_mode NOT IN ('disabled','sim','live') THEN
    RAISE EXCEPTION 'Unknown mystery pool mode: %', p_mode;
  END IF;

  UPDATE public.mystery_pool_settings SET mode = p_mode, updated_at = NOW() WHERE id;

  PERFORM public.admin_log_action(
    p_admin, 'set_mystery_mode', NULL, jsonb_build_object('mode', p_mode));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_mystery_mode_internal(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Manual expiry sweep from the console (the cron below is the routine path)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_expire_campaigns_internal(p_admin UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_n INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_admin AND is_admin) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  v_n := public.clip_campaigns_expire_due();
  PERFORM public.admin_log_action(
    p_admin, 'expire_campaigns', NULL, jsonb_build_object('expired', v_n));
  RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_expire_campaigns_internal(UUID)
  FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- THE MISSING SCHEDULE — hourly expiry sweep (mig 176 shipped the function with
-- no caller, so escrow on an expired campaign was never refunded).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM cron.unschedule('clip-campaigns-expire');
EXCEPTION WHEN OTHERS THEN NULL;   -- not scheduled yet: nothing to remove
END $$;

SELECT cron.schedule(
  'clip-campaigns-expire',
  '0 * * * *',
  $$SELECT public.clip_campaigns_expire_due()$$
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_admin UUID; v_mm UUID; v_clipper UUID;
  v_camp UUID; v_sub UUID;
  v_err BOOLEAN; v_msg TEXT; v_n INTEGER; v_was BOOLEAN;
BEGIN
  SELECT id INTO v_mm      FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_clipper FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_mm IS NULL OR v_clipper IS NULL THEN
    RAISE EXCEPTION 'mig 177 smoke needs the mig-155 smoke users';
  END IF;
  IF public.battle_payments_mode() <> 'sim' THEN
    RAISE NOTICE 'mig 177 smoke SKIPPED (battle_payments_mode is live)';
    RETURN;
  END IF;

  -- Borrow admin on the smoke user for the duration (mig-168 pattern), restore after.
  v_admin := v_mm;
  SELECT is_admin INTO v_was FROM public.profiles WHERE id = v_admin;
  UPDATE public.profiles SET is_admin = TRUE WHERE id = v_admin;

  -- ── the cron entry actually exists (the whole point of this migration) ──────
  SELECT COUNT(*) INTO v_n FROM cron.job WHERE jobname = 'clip-campaigns-expire';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'SMOKE FAIL: the campaign expiry sweep must be scheduled (found %)', v_n;
  END IF;

  -- ── audit log: append-only, and a non-admin cannot write to it ──────────────
  PERFORM public.admin_log_action(v_admin, 'smoke_check', NULL, '{"smoke":true}'::JSONB);
  IF NOT EXISTS (SELECT 1 FROM public.admin_audit_log
                 WHERE admin_id = v_admin AND action = 'smoke_check') THEN
    RAISE EXCEPTION 'SMOKE FAIL: the audit write did not land';
  END IF;
  v_err := FALSE;
  BEGIN
    UPDATE public.admin_audit_log SET action = 'tampered' WHERE admin_id = v_admin;
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: the audit log must be append-only'; END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.admin_log_action(v_clipper, 'should_fail', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: a non-admin must not be able to write audit rows'; END IF;

  -- ── minor-safety can never be approved from the console ─────────────────────
  IF NOT public.is_collection_minter(v_mm) THEN
    INSERT INTO public.kyc_verifications (user_id, status) VALUES (v_mm, 'approved');
    INSERT INTO public.platform_connections
      (user_id, platform, platform_user_id, platform_username, access_token, is_active)
    VALUES (v_mm, 'youtube', 'n8-smoke', '@n8_smoke', 'tok', TRUE);
  END IF;
  PERFORM public.sim_seed_balance(v_mm);
  PERFORM public.ccg_usd_credit(v_mm, 10000, gen_random_uuid(), 'mig177 smoke float', 'distribution');

  v_camp := public.clip_campaign_create_internal(
    v_mm, 'mig177 smoke', 'brief', 100, 1, NOW() + INTERVAL '2 days');
  v_sub := public.clip_submission_create_internal(
    v_clipper, v_camp, v_clipper::TEXT || '/' || v_camp::TEXT || '/clip.mp4');
  PERFORM public.clip_submission_moderate(v_sub, 'escalated', '{"minor_safety":true}'::JSONB, FALSE, 'sim');

  v_err := FALSE;
  BEGIN
    PERFORM public.admin_clip_submission_verdict_internal(v_admin, v_sub, TRUE);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_err OR v_msg NOT LIKE '%minor-safety clip can never be approved%' THEN
    RAISE EXCEPTION 'SMOKE FAIL: console approval of a minor-safety clip must be refused (got %)', v_msg;
  END IF;
  -- resolving the case does NOT change that
  UPDATE public.clip_campaign_moderation
  SET status = 'resolved_cleared', resolved_at = NOW() WHERE submission_id = v_sub;
  v_err := FALSE;
  BEGIN
    PERFORM public.admin_clip_submission_verdict_internal(v_admin, v_sub, TRUE);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN
    RAISE EXCEPTION 'SMOKE FAIL: clearing a minor-safety case must never make the clip approvable';
  END IF;
  -- rejecting it is always allowed
  PERFORM public.admin_clip_submission_verdict_internal(v_admin, v_sub, FALSE);
  IF (SELECT status FROM public.clip_campaign_submissions WHERE id = v_sub) <> 'rejected' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the console must still be able to reject';
  END IF;

  -- ── the Mystery Box gate round-trips and is left disabled ───────────────────
  PERFORM public.admin_set_mystery_mode_internal(v_admin, 'sim');
  IF public.mystery_pool_mode() <> 'sim' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the mystery gate did not flip';
  END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.admin_set_mystery_mode_internal(v_admin, 'nonsense');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: an unknown mystery mode must be refused'; END IF;
  PERFORM public.admin_set_mystery_mode_internal(v_admin, 'disabled');
  IF public.mystery_pool_mode() <> 'disabled' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the mystery gate must be left disabled (G-MYSTERY)';
  END IF;

  -- ── the expiry sweep refunds an overdue campaign ────────────────────────────
  UPDATE public.clip_campaigns SET deadline = NOW() - INTERVAL '1 hour' WHERE id = v_camp;
  v_n := public.admin_expire_campaigns_internal(v_admin);
  IF v_n < 1 THEN RAISE EXCEPTION 'SMOKE FAIL: the overdue campaign must expire'; END IF;
  IF (SELECT escrow_remaining_cents FROM public.clip_campaigns WHERE id = v_camp) <> 0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: expiry must release the escrow';
  END IF;
  IF (SELECT status FROM public.clip_campaigns WHERE id = v_camp) <> 'closed' THEN
    RAISE EXCEPTION 'SMOKE FAIL: an expired campaign must close';
  END IF;

  -- ── a non-admin gets nowhere ────────────────────────────────────────────────
  v_err := FALSE;
  BEGIN
    PERFORM public.admin_set_mystery_mode_internal(v_clipper, 'live');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: a non-admin must not flip the mystery gate'; END IF;
  IF public.mystery_pool_mode() <> 'disabled' THEN
    RAISE EXCEPTION 'SMOKE FAIL: the gate moved during the non-admin check';
  END IF;

  UPDATE public.profiles SET is_admin = COALESCE(v_was, FALSE) WHERE id = v_admin;

  RAISE NOTICE 'mig 177 smoke OK: expiry scheduled + sweeps, audit append-only + admin-gated, minor-safety unapprovable, mystery gate round-trips and is left disabled';
END $$;
