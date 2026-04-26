-- Migration 025: Test Account System
-- Adds is_test_account flag to profiles and platform_connections.
-- Test accounts are synthetic creators used for dev/QA seeding.
-- They are filtered from all ranking, discovery, and challenge surfaces.

-- ── 1. Add is_test_account to profiles ──────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_test_account boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS profiles_is_test_account_idx
  ON public.profiles (is_test_account);

-- ── 2. Protect is_test_account from client-side mutation ─────────────────────
-- A trigger resets the field to its old value if the calling role is not
-- service_role. This prevents an authenticated user from setting their own
-- profile to is_test_account = true (or false if already a test account).
CREATE OR REPLACE FUNCTION public.protect_is_test_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.is_test_account IS DISTINCT FROM NEW.is_test_account THEN
    -- auth.role() returns the role from the JWT ('authenticated', 'anon', etc.)
    -- Service-role calls bypass RLS entirely and do not pass a JWT, so
    -- auth.role() returns 'service_role' for direct service client calls.
    IF current_setting('role', true) NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
      NEW.is_test_account := OLD.is_test_account;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_is_test_account ON public.profiles;
CREATE TRIGGER trg_protect_is_test_account
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_is_test_account();

-- ── 3. Add is_test_account to platform_connections ───────────────────────────
-- Marks synthetic connections that sync-platform-metrics should skip.
-- Avoids calling real OAuth APIs with fake tokens.
ALTER TABLE public.platform_connections
  ADD COLUMN IF NOT EXISTS is_test_account boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS platform_connections_is_test_account_idx
  ON public.platform_connections (is_test_account);

-- ── 4. Update evaluate_main_character_badge() to exclude test accounts ────────
-- The #1 heat_score scan must not be won by a test account.
CREATE OR REPLACE FUNCTION public.evaluate_main_character_badge()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_leader_id    uuid;
  v_badge_id     uuid;
  v_challenge_id uuid;
BEGIN
  -- Find the real user (non-test-account) with the highest heat_score.
  SELECT pm.user_id INTO v_leader_id
  FROM public.platform_metrics pm
  JOIN public.profiles p ON p.id = pm.user_id
  WHERE pm.heat_score IS NOT NULL
    AND p.is_test_account = false
  ORDER BY pm.heat_score DESC
  LIMIT 1;

  IF v_leader_id IS NULL THEN
    RETURN;
  END IF;

  -- Clear heat_score_leader_since for anyone who is no longer the leader.
  UPDATE public.platform_metrics
  SET heat_score_leader_since = NULL
  WHERE user_id != v_leader_id
    AND heat_score_leader_since IS NOT NULL;

  -- Set heat_score_leader_since for the current leader.
  UPDATE public.platform_metrics
  SET heat_score_leader_since = COALESCE(heat_score_leader_since, now())
  WHERE user_id = v_leader_id;

  SELECT id INTO v_badge_id     FROM public.badge_definitions     WHERE slug = 'main_character';
  SELECT id INTO v_challenge_id FROM public.challenge_definitions WHERE slug = 'main_character';

  IF v_badge_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.platform_metrics
    WHERE user_id = v_leader_id
      AND heat_score_leader_since <= now() - interval '24 hours'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.user_badges
    WHERE user_id = v_leader_id AND badge_id = v_badge_id
  ) THEN
    INSERT INTO public.user_badges (user_id, badge_id, challenge_id)
    VALUES (v_leader_id, v_badge_id, v_challenge_id)
    ON CONFLICT DO NOTHING;

    PERFORM public.increment_token_balance(v_leader_id, 150);

    INSERT INTO public.token_transactions (user_id, type, amount, description)
    VALUES (
      v_leader_id,
      'challenge_reward',
      150,
      'Main Character — #1 Heat Score for 24 consecutive hours'
    );
  END IF;
END;
$$;
