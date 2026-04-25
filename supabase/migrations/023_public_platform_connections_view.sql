-- Migration 023: Public platform connections view
-- Documents the public_platform_connections view that was created directly in
-- the SQL Editor. This view lets the public profile screen read connection
-- metadata without touching the platform_connections table (which holds OAuth
-- tokens and is restricted to service role writes + owner reads by RLS).
--
-- Only exposes safe columns (no tokens). Filters to is_active = true so
-- disconnected platforms are never visible to anonymous viewers.

CREATE OR REPLACE VIEW public.public_platform_connections AS
  SELECT
    user_id,
    platform,
    platform_username,
    connected_at,
    is_active
  FROM public.platform_connections
  WHERE is_active = true;

-- Allow anon and authenticated roles to read the view.
-- The underlying platform_connections RLS still applies to direct table
-- access; this view is the only public-facing surface.
GRANT SELECT ON public.public_platform_connections TO anon, authenticated;
