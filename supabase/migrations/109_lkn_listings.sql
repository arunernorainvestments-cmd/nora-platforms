-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 109 — Licensing Marketplace: Listings & License Tiers
-- Doc 5. A listing is what a licensor puts on the marketplace; it can hold
-- multiple priced tiers (e.g. a $50 basic license and a $500 exclusive).
--
-- ADJUSTED: renumbered 096 -> 109. Schema-qualified + RLS added.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE public.lkn_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  licensor_user_id            UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- The likeness being licensed
  listing_title               TEXT NOT NULL,         -- e.g. "Drake — Official Likeness License"
  listing_description         TEXT,
  licensor_display_name       TEXT NOT NULL,         -- the name that appears in search
  licensor_image_url          TEXT,
  category                    TEXT NOT NULL CHECK (category IN (
    'musician', 'athlete', 'actor', 'comedian', 'politician', 'entrepreneur',
    'influencer', 'content_creator', 'artist', 'scientist', 'other'
  )),

  -- What the license covers (at least one must be true)
  covers_name                 BOOLEAN NOT NULL DEFAULT TRUE,
  covers_image                BOOLEAN NOT NULL DEFAULT TRUE,
  covers_voice                BOOLEAN NOT NULL DEFAULT FALSE,
  covers_signature            BOOLEAN NOT NULL DEFAULT FALSE,
  covers_persona              BOOLEAN NOT NULL DEFAULT FALSE,  -- catch-all personality traits
  CONSTRAINT lkn_listing_covers_one CHECK (
    covers_name OR covers_image OR covers_voice OR covers_signature OR covers_persona
  ),

  -- Listing state
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'pending_review', 'active', 'paused', 'closed')),
  featured                    BOOLEAN NOT NULL DEFAULT FALSE,  -- future: paid placement

  -- Search/discovery
  tags                        TEXT[] DEFAULT '{}',
  search_vector               TSVECTOR,  -- populated by trigger for full-text search

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at                TIMESTAMPTZ,
  closed_at                   TIMESTAMPTZ
);

-- Full-text search trigger
CREATE OR REPLACE FUNCTION public.lkn_update_search_vector()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    COALESCE(NEW.licensor_display_name, '') || ' ' ||
    COALESCE(NEW.listing_title, '') || ' ' ||
    COALESCE(NEW.listing_description, '') || ' ' ||
    COALESCE(array_to_string(NEW.tags, ' '), '')
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER lkn_listing_search_vector
  BEFORE INSERT OR UPDATE ON public.lkn_listings
  FOR EACH ROW EXECUTE FUNCTION public.lkn_update_search_vector();

CREATE INDEX lkn_listings_search_idx   ON public.lkn_listings USING GIN (search_vector);
CREATE INDEX lkn_listings_status_idx   ON public.lkn_listings (status, published_at DESC);
CREATE INDEX lkn_listings_licensor_idx ON public.lkn_listings (licensor_user_id, status);
CREATE INDEX lkn_listings_category_idx ON public.lkn_listings (category, status);

-- ── License tiers within a listing (e.g. Basic, Standard, Exclusive) ─────────
CREATE TABLE public.lkn_license_tiers (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  UUID NOT NULL REFERENCES public.lkn_listings(id) ON DELETE CASCADE,
  tier_name                   TEXT NOT NULL,          -- e.g. "Basic", "Commercial", "Exclusive"
  tier_description            TEXT,
  price_usd_cents             BIGINT NOT NULL CHECK (price_usd_cents >= 0),

  -- Supply (for exclusive/limited tiers)
  is_exclusive                BOOLEAN NOT NULL DEFAULT FALSE,
  max_licenses                INTEGER,                -- NULL = unlimited
  licenses_sold               INTEGER NOT NULL DEFAULT 0,

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX lkn_tiers_listing_idx ON public.lkn_license_tiers (listing_id, is_active);

-- ── Row Level Security ───────────────────────────────────────────────────────
-- Public can browse active listings; licensors fully manage their own (any state).
ALTER TABLE public.lkn_listings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_listings_public_read_active" ON public.lkn_listings
  FOR SELECT USING (status = 'active');

CREATE POLICY "lkn_listings_owner_all" ON public.lkn_listings
  FOR ALL USING (auth.uid() = licensor_user_id)
  WITH CHECK (auth.uid() = licensor_user_id);

ALTER TABLE public.lkn_license_tiers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_tiers_public_read_active" ON public.lkn_license_tiers
  FOR SELECT USING (
    is_active AND EXISTS (
      SELECT 1 FROM public.lkn_listings l
      WHERE l.id = listing_id AND l.status = 'active'
    )
  );

CREATE POLICY "lkn_tiers_owner_all" ON public.lkn_license_tiers
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.lkn_listings l
            WHERE l.id = listing_id AND l.licensor_user_id = auth.uid())
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.lkn_listings l
            WHERE l.id = listing_id AND l.licensor_user_id = auth.uid())
  );
