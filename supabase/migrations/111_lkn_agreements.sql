-- ─────────────────────────────────────────────────────────────────────────────
-- Migration 111 — Licensing Marketplace: License Agreements (Purchases)
-- Doc 5. A license agreement is the legal record created when a buyer purchases
-- a tier. APPEND-ONLY: after INSERT only status fields may change (Hard Rule 29).
-- license_id is the externally-facing identifier used in verification API calls.
--
-- ADJUSTED: renumbered 098 -> 111. Schema-qualified + RLS added.
-- ADJUSTED: added generate_license_id() here (doc5 had it standalone) since this
--           is where it is consumed, and an append-only guard trigger to enforce
--           Hard Rule 29 at the DB layer rather than relying on edge-fn discipline.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── License ID generator: LKN-[year]-[8 unambiguous chars] ───────────────────
CREATE OR REPLACE FUNCTION public.generate_license_id()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_year  TEXT := EXTRACT(YEAR FROM NOW())::TEXT;
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no ambiguous chars (no I/O/0/1)
  v_code  TEXT := '';
  i INTEGER;
BEGIN
  FOR i IN 1..8 LOOP
    v_code := v_code || substr(v_chars, floor(random() * length(v_chars))::int + 1, 1);
  END LOOP;
  RETURN 'LKN-' || v_year || '-' || v_code;
END;
$$;

CREATE TABLE public.lkn_agreements (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Public-facing license identifier (short, URL-safe). Default-generated;
  -- the purchase edge function retries on the (statistically impossible) collision.
  license_id                  TEXT NOT NULL UNIQUE DEFAULT public.generate_license_id(),

  listing_id                  UUID NOT NULL REFERENCES public.lkn_listings(id),
  tier_id                     UUID NOT NULL REFERENCES public.lkn_license_tiers(id),
  template_id                 UUID NOT NULL REFERENCES public.lkn_license_templates(id),

  licensor_user_id            UUID NOT NULL REFERENCES auth.users(id),
  licensee_user_id            UUID NOT NULL REFERENCES auth.users(id),

  -- Snapshot of key terms at time of purchase (template may change after).
  -- These are the actual terms in force — verification NEVER reads the template.
  terms_snapshot              JSONB NOT NULL,   -- full copy of the template row at purchase

  -- Effective dates
  effective_date              DATE NOT NULL DEFAULT CURRENT_DATE,
  expiration_date             DATE,             -- NULL if perpetual

  -- State (the only thing allowed to change after INSERT — Hard Rule 29)
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'expired', 'revoked', 'suspended', 'transferred')),
  revoked_at                  TIMESTAMPTZ,
  revoked_reason              TEXT,

  -- Payment
  price_paid_usd_cents        BIGINT NOT NULL,
  platform_fee_usd_cents      BIGINT NOT NULL,
  licensor_receives_usd_cents BIGINT NOT NULL,
  stripe_payment_intent_id    TEXT,
  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,

  -- Cryptographic signature of the license record (ECDSA in lkn-verify)
  record_hash                 TEXT NOT NULL,    -- SHA-256 of the core license fields
  signature                   TEXT,             -- signature of record_hash

  -- Signing
  licensee_agreed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  licensor_countersigned_at   TIMESTAMPTZ,      -- for approval-required tiers

  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX agreements_licensor_idx  ON public.lkn_agreements (licensor_user_id, status);
CREATE INDEX agreements_licensee_idx  ON public.lkn_agreements (licensee_user_id, status);
CREATE INDEX agreements_listing_idx   ON public.lkn_agreements (listing_id);
CREATE INDEX agreements_expiry_idx    ON public.lkn_agreements (expiration_date, status)
  WHERE status = 'active';

-- ── Hard Rule 29 enforcement: terms snapshot & identity are immutable ────────
-- Only status / revocation / countersign timestamps may change on UPDATE.
CREATE OR REPLACE FUNCTION public.lkn_agreements_guard_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.license_id        IS DISTINCT FROM OLD.license_id
     OR NEW.listing_id     IS DISTINCT FROM OLD.listing_id
     OR NEW.tier_id        IS DISTINCT FROM OLD.tier_id
     OR NEW.template_id    IS DISTINCT FROM OLD.template_id
     OR NEW.licensor_user_id IS DISTINCT FROM OLD.licensor_user_id
     OR NEW.licensee_user_id IS DISTINCT FROM OLD.licensee_user_id
     OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
     OR NEW.effective_date IS DISTINCT FROM OLD.effective_date
     OR NEW.price_paid_usd_cents IS DISTINCT FROM OLD.price_paid_usd_cents
     OR NEW.record_hash    IS DISTINCT FROM OLD.record_hash
     OR NEW.created_at     IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'lkn_agreements is append-only: immutable fields cannot change (Hard Rule 29)';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER lkn_agreements_immutable
  BEFORE UPDATE ON public.lkn_agreements
  FOR EACH ROW EXECUTE FUNCTION public.lkn_agreements_guard_immutable();

-- ── Agreement change log (append-only audit trail) ───────────────────────────
CREATE TABLE public.lkn_agreement_events (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agreement_id                UUID NOT NULL REFERENCES public.lkn_agreements(id),
  event_type                  TEXT NOT NULL CHECK (event_type IN (
    'created', 'activated', 'revoked', 'suspended', 'reinstated',
    'expired', 'transferred', 'countersigned', 'addendum_added'
  )),
  actor_user_id               UUID REFERENCES auth.users(id),  -- who triggered the event
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX agreement_events_idx ON public.lkn_agreement_events (agreement_id, created_at DESC);

-- ── Row Level Security ───────────────────────────────────────────────────────
-- Parties (licensor or licensee) may read their own agreements. No client
-- INSERT/UPDATE — purchases and status changes run through SECURITY DEFINER
-- edge functions (lkn-purchase-license, lkn-revoke-license) on the service role.
ALTER TABLE public.lkn_agreements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_agreements_select_party" ON public.lkn_agreements
  FOR SELECT USING (auth.uid() = licensor_user_id OR auth.uid() = licensee_user_id);

ALTER TABLE public.lkn_agreement_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lkn_agreement_events_select_party" ON public.lkn_agreement_events
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.lkn_agreements a
            WHERE a.id = agreement_id
              AND (a.licensor_user_id = auth.uid() OR a.licensee_user_id = auth.uid()))
  );
