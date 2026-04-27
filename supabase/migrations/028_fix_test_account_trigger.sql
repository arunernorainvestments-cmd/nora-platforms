-- Migration 028: Patch protect_is_test_account trigger
-- Bug (025): protect_is_test_account() allows mutation when
--   current_setting('role', true) IN ('service_role', 'postgres', 'supabase_admin').
-- Problem: current_setting('role', true) is the PostgREST JWT GUC. When migrations
--   run directly as postgres (Supabase Management API, psql, CLI push), the GUC is
--   unset and returns 'none' — not 'postgres'. The trigger therefore blocked all
--   direct-postgres migration paths it was never intended to block.
-- Fix: extend the allow condition with current_user IN ('postgres', 'supabase_admin')
--   so direct admin connections are permitted regardless of the GUC state.
-- Idempotent: CREATE OR REPLACE is safe to re-run.

CREATE OR REPLACE FUNCTION public.protect_is_test_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.is_test_account IS DISTINCT FROM NEW.is_test_account THEN
    -- Allow: PostgREST service-role requests (GUC set by PostgREST to 'service_role')
    -- Allow: direct admin connections (current_user is 'postgres' or 'supabase_admin')
    -- Block: everything else (authenticated/anon client-side mutations)
    IF current_setting('role', true) NOT IN ('service_role', 'postgres', 'supabase_admin')
       AND current_user NOT IN ('postgres', 'supabase_admin') THEN
      NEW.is_test_account := OLD.is_test_account;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
