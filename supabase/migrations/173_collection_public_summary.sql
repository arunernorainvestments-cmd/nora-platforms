-- Migration 173: N4 — public-safe collection summary aggregates.
--
-- Collections spec Phase N4. The profile "Collections" section shows cards
-- created + supply/SOLD counts. Sold/remaining derive from copy ownership +
-- purchase receipts, both RLS-restricted (owner/party only), so a public
-- profile viewer (incl. anon) cannot read them directly. These SECURITY DEFINER
-- aggregates expose ONLY counts — never prices, never PII, never any value or
-- appreciation figure (G-COLL language ban). Safe to grant broadly.
--
-- collection_sets_remaining (mig 172) is likewise a plain count — grant it to
-- anon too so the summary works for logged-out profile views.

-- Full sets SOLD = one per collection_purchases receipt (each buys a full set).
CREATE OR REPLACE FUNCTION public.collection_sold_sets(p_collection UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COUNT(*)::INTEGER FROM public.collection_purchases
  WHERE collection_id = p_collection;
$$;

REVOKE ALL ON FUNCTION public.collection_sold_sets(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.collection_sold_sets(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.collection_sets_remaining(UUID) TO anon;
