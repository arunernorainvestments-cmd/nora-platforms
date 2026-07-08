-- Migration 154: marketplace listings + sales ledger + listing allowance (M1 — spec §3.2).
--
-- The sale-offer layer over `chit_ownership`. The acquisition ledger (mig 117) is
-- append-only and NEVER mutated (Hard Rule 29) — `marketplace_listings` is a sibling
-- STATUS table (like `ccg_wager_escrow`, mig 142): a listed chit's copy leaves the
-- seller's holdings via a negative ledger delta ('marketplace_escrow') and the listing
-- row tracks where that copy is. Delist returns it ('marketplace_return'); a sale
-- grants it to the buyer ('marketplace_purchase') with the `acquired_currency`
-- provenance stamp M2 will enforce resale-currency against (token-bought → token-
-- resale-only). `marketplace_sales` is the append-only sale receipt ledger.
--
-- Escrow side-effects on the wider system (list = held, not free):
--   • wager staking is blocked automatically (ccg_create_wager_match needs quantity>0);
--   • deck legality is enforced by deck_validate's ownership re-check at match entry
--     (mig 118) — same treatment as a wager-escrowed chit;
--   • the self-mint slot stays OCCUPIED while listed, ascension FREEZES while
--     escrowed, and swap-retire is blocked — those function patches live in mig 155
--     next to the RPCs.
--
-- Spec: NORA_PLATFORMS_MARKETPLACE_SPEC.md §3.2 / PHASE M1.

-- ── acquisition-ledger vocabulary: marketplace movements + provenance stamp ──────
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired',
    'marketplace_escrow','marketplace_return','marketplace_purchase'
  ));

-- Provenance seam for M2 (dormant in M1): which currency bought this copy. Stamped
-- 'token' on every marketplace purchase now; M2 activates the resale lock against it.
ALTER TABLE public.chit_acquisition_ledger
  ADD COLUMN IF NOT EXISTS acquired_currency TEXT
    CHECK (acquired_currency IN ('token','usd'));

-- ── marketplace_listings (the sale offer / escrow status row) ────────────────────
CREATE TABLE public.marketplace_listings (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chit_id            UUID NOT NULL REFERENCES public.moment_chits(id),
  seller_user_id     UUID NOT NULL REFERENCES auth.users(id),
  currency           TEXT NOT NULL DEFAULT 'token' CHECK (currency IN ('token','usd')),

  -- Frozen at list time from marketplace_tier_pricing — a live buyer can never have
  -- tier/price/fee shift underneath them (ascension is also frozen while escrowed).
  tier_snapshot      TEXT NOT NULL CHECK (tier_snapshot IN ('F','E','D','C','B','A','S')),
  price_snapshot     INTEGER NOT NULL CHECK (price_snapshot > 0),   -- tokens
  fee_bps_snapshot   INTEGER NOT NULL CHECK (fee_bps_snapshot BETWEEN 0 AND 10000),
  usd_cents_snapshot INTEGER NOT NULL CHECK (usd_cents_snapshot > 0), -- recorded, INERT in M1

  status             TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','sold','delisted')),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  closed_at          TIMESTAMPTZ
);

-- One open listing per (seller, chit): the unique-card rule at the copy level.
-- (Different owners of copies of the same chit may each list theirs.)
CREATE UNIQUE INDEX marketplace_listings_open_chit_idx
  ON public.marketplace_listings (seller_user_id, chit_id) WHERE status = 'active';

CREATE INDEX marketplace_listings_browse_idx
  ON public.marketplace_listings (created_at DESC) WHERE status = 'active';
CREATE INDEX marketplace_listings_seller_idx
  ON public.marketplace_listings (seller_user_id, status);
CREATE INDEX marketplace_listings_chit_idx
  ON public.marketplace_listings (chit_id);

COMMENT ON TABLE public.marketplace_listings IS
  'Fixed-price sale offers over chit_ownership (M1). Status sibling of the append-only '
  'acquisition ledger (Hard Rule 29): an active listing means the copy is escrowed out '
  'of the seller''s holdings. All writes via SECURITY DEFINER RPCs (mig 155).';

-- ── marketplace_sales (append-only receipt ledger) ───────────────────────────────
CREATE TABLE public.marketplace_sales (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id     UUID NOT NULL REFERENCES public.marketplace_listings(id),
  chit_id        UUID NOT NULL REFERENCES public.moment_chits(id),
  buyer_user_id  UUID NOT NULL REFERENCES auth.users(id),
  seller_user_id UUID NOT NULL REFERENCES auth.users(id),
  currency       TEXT NOT NULL CHECK (currency IN ('token','usd')),
  gross_price    INTEGER NOT NULL CHECK (gross_price > 0),
  fee_burned     INTEGER NOT NULL DEFAULT 0 CHECK (fee_burned >= 0),
  net_to_seller  INTEGER NOT NULL CHECK (net_to_seller >= 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT marketplace_sales_arith CHECK (gross_price = fee_burned + net_to_seller),
  CONSTRAINT marketplace_sales_one_per_listing UNIQUE (listing_id)
);

COMMENT ON TABLE public.marketplace_sales IS
  'Append-only sale receipts (Hard Rule 29). fee_burned left the token supply — it is '
  'credited to NO ONE (deflationary sink), never platform income.';

-- Append-only guard (mirrors chit_ledger_block_mutation, mig 117).
CREATE OR REPLACE FUNCTION public.marketplace_sales_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'marketplace_sales is append-only (no UPDATE/DELETE)';
END;
$$;

CREATE TRIGGER marketplace_sales_no_mutation
  BEFORE UPDATE OR DELETE ON public.marketplace_sales
  FOR EACH ROW EXECUTE FUNCTION public.marketplace_sales_block_mutation();

-- ── listing allowance: max concurrent active listings per user (default 1) ───────
-- A FUNCTION, not a constant, so a future subscription tier (spec §7.4) raises it via
-- config without a schema change. This IS the "one active listing" rule.
CREATE OR REPLACE FUNCTION public.marketplace_listing_allowance(p_user UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT 1;
$$;

REVOKE ALL ON FUNCTION public.marketplace_listing_allowance(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.marketplace_listing_allowance(UUID) TO authenticated;

-- ── RLS: public-read active listings; sellers read their own; parties read sales.
--    ALL writes via SECURITY DEFINER RPC only (mig 155) — no client write policies,
--    mirroring the create_moment_chit server-only-writer discipline. ─────────────
ALTER TABLE public.marketplace_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_sales    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "marketplace_listings_select_active_or_own" ON public.marketplace_listings
  FOR SELECT USING (status = 'active' OR auth.uid() = seller_user_id);

CREATE POLICY "marketplace_sales_select_party" ON public.marketplace_sales
  FOR SELECT USING (auth.uid() IN (buyer_user_id, seller_user_id));
