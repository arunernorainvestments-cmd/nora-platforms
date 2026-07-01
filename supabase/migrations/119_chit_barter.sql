-- Migration 119: chit barter (Phase 1 — P1.4).
--
-- Two-party swap with an offer → accept/cancel consent handshake. Settlement is atomic
-- and logs a transfer event. Barters are UNGATED (no KYC) EXCEPT when any chit on either
-- side is a `licensed` premium chit (licensing crossover) — then BOTH parties must be
-- KYC-verified (the verify/cancel popup on the client). Token legs reuse the existing
-- chit_purchase/chit_sale token_transaction types (Hard Rule 5: log type + reference_id).
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 1.

-- ── offers ──────────────────────────────────────────────────────────────────────
-- offer / request are jsonb: { "chits": [{"chit_id":uuid,"quantity":int}...], "tokens": int }
CREATE TABLE public.chit_barter_offers (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  initiator_user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  counterparty_user_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  offer                 JSONB NOT NULL,   -- what the initiator gives
  request               JSONB NOT NULL,   -- what the counterparty gives
  requires_kyc          BOOLEAN NOT NULL DEFAULT FALSE,  -- licensed chit on either side
  status                TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','accepted','cancelled','expired')),
  settled_reference_id  UUID,             -- = id (used as ledger reference on accept)
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at           TIMESTAMPTZ,
  CONSTRAINT barter_distinct_parties CHECK (initiator_user_id <> counterparty_user_id)
);

CREATE INDEX barter_offers_counterparty_idx ON public.chit_barter_offers (counterparty_user_id, status);
CREATE INDEX barter_offers_initiator_idx    ON public.chit_barter_offers (initiator_user_id, status);

-- ── transfer event log (the "logs a transfer event" deliverable) ────────────────
CREATE TABLE public.chit_barter_events (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id      UUID NOT NULL REFERENCES public.chit_barter_offers(id),
  initiator_user_id     UUID NOT NULL REFERENCES auth.users(id),
  counterparty_user_id  UUID NOT NULL REFERENCES auth.users(id),
  offer         JSONB NOT NULL,
  request       JSONB NOT NULL,
  was_kyc_gated BOOLEAN NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── helpers ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_kyc_verified(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.kyc_verifications
    WHERE user_id = p_user_id
      AND status = 'approved'
      AND (expires_at IS NULL OR expires_at > NOW())
  );
$$;

-- Any licensed chit referenced in an offer/request side?
CREATE OR REPLACE FUNCTION public._barter_touches_licensed(p_side JSONB)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(p_side->'chits', '[]'::jsonb)) AS e
    JOIN public.moment_chits mc ON mc.id = (e->>'chit_id')::UUID
    WHERE mc.character_class = 'licensed'
  );
$$;

-- Move tokens between two users (atomic; raises on insufficient balance).
CREATE OR REPLACE FUNCTION public._barter_move_tokens(p_from UUID, p_to UUID, p_amount INTEGER, p_ref UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_amount IS NULL OR p_amount = 0 THEN RETURN; END IF;
  IF p_amount < 0 THEN RAISE EXCEPTION 'barter token amount must be positive'; END IF;

  UPDATE public.token_balances
  SET available_tokens = available_tokens - p_amount,
      lifetime_spent   = lifetime_spent + p_amount,
      updated_at       = NOW()
  WHERE user_id = p_from AND available_tokens >= p_amount;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient token balance for barter (user %)', p_from;
  END IF;

  UPDATE public.token_balances
  SET available_tokens = available_tokens + p_amount,
      lifetime_earned  = lifetime_earned + p_amount,
      updated_at       = NOW()
  WHERE user_id = p_to;

  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (p_from, 'chit_purchase', -p_amount, p_ref, 'chit barter'),
         (p_to,   'chit_sale',      p_amount, p_ref, 'chit barter');
END;
$$;

-- ── create offer ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.chit_barter_create_offer(
  p_counterparty  UUID,
  p_offer         JSONB,
  p_request       JSONB
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_initiator UUID := auth.uid();
  v_offer_id  UUID;
  v_kyc       BOOLEAN;
BEGIN
  IF v_initiator IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF v_initiator = p_counterparty THEN RAISE EXCEPTION 'Cannot barter with yourself'; END IF;

  -- Sanity: initiator must currently hold what they offer.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(p_offer->'chits','[]'::jsonb)) AS e
    LEFT JOIN public.chit_ownership co
      ON co.user_id = v_initiator AND co.chit_id = (e->>'chit_id')::UUID
    WHERE COALESCE(co.quantity,0) < (e->>'quantity')::INTEGER
  ) THEN
    RAISE EXCEPTION 'You do not own all offered chits';
  END IF;

  v_kyc := public._barter_touches_licensed(p_offer) OR public._barter_touches_licensed(p_request);

  INSERT INTO public.chit_barter_offers
    (initiator_user_id, counterparty_user_id, offer, request, requires_kyc)
  VALUES (v_initiator, p_counterparty, p_offer, p_request, v_kyc)
  RETURNING id INTO v_offer_id;

  RETURN v_offer_id;
END;
$$;

-- ── cancel offer (either party) ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.chit_barter_cancel(p_offer_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_o public.chit_barter_offers%ROWTYPE;
BEGIN
  SELECT * INTO v_o FROM public.chit_barter_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_o.status <> 'pending' THEN RAISE EXCEPTION 'Offer is not pending'; END IF;
  IF auth.uid() NOT IN (v_o.initiator_user_id, v_o.counterparty_user_id) THEN
    RAISE EXCEPTION 'Not a party to this offer';
  END IF;

  UPDATE public.chit_barter_offers
  SET status = 'cancelled', resolved_at = NOW()
  WHERE id = p_offer_id;
END;
$$;

-- ── accept offer (counterparty only): atomic settlement ─────────────────────────
CREATE OR REPLACE FUNCTION public.chit_barter_accept(p_offer_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_o   public.chit_barter_offers%ROWTYPE;
  v_e   JSONB;
BEGIN
  SELECT * INTO v_o FROM public.chit_barter_offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_o.status <> 'pending' THEN RAISE EXCEPTION 'Offer is not pending'; END IF;
  IF auth.uid() <> v_o.counterparty_user_id THEN
    RAISE EXCEPTION 'Only the counterparty can accept';
  END IF;

  -- KYC gate on licensed crossover (Hard Rule: licensed swap needs both KYC'd).
  IF v_o.requires_kyc THEN
    IF NOT public.is_kyc_verified(v_o.initiator_user_id)
       OR NOT public.is_kyc_verified(v_o.counterparty_user_id) THEN
      RAISE EXCEPTION 'Licensed-chit barter requires both parties KYC-verified';
    END IF;
  END IF;

  -- Validate holdings on both sides at settlement time.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(v_o.offer->'chits','[]'::jsonb)) AS e
    LEFT JOIN public.chit_ownership co
      ON co.user_id = v_o.initiator_user_id AND co.chit_id = (e->>'chit_id')::UUID
    WHERE COALESCE(co.quantity,0) < (e->>'quantity')::INTEGER
  ) THEN
    RAISE EXCEPTION 'Initiator no longer owns all offered chits';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(v_o.request->'chits','[]'::jsonb)) AS e
    LEFT JOIN public.chit_ownership co
      ON co.user_id = v_o.counterparty_user_id AND co.chit_id = (e->>'chit_id')::UUID
    WHERE COALESCE(co.quantity,0) < (e->>'quantity')::INTEGER
  ) THEN
    RAISE EXCEPTION 'You do not own all requested chits';
  END IF;

  -- Move offered chits: initiator → counterparty.
  FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_o.offer->'chits','[]'::jsonb)) LOOP
    PERFORM public.chit_grant(v_o.initiator_user_id, (v_e->>'chit_id')::UUID,
      -(v_e->>'quantity')::INTEGER, 'barter_out', p_offer_id, v_o.counterparty_user_id);
    PERFORM public.chit_grant(v_o.counterparty_user_id, (v_e->>'chit_id')::UUID,
       (v_e->>'quantity')::INTEGER, 'barter_in', p_offer_id, v_o.initiator_user_id);
  END LOOP;

  -- Move requested chits: counterparty → initiator.
  FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(v_o.request->'chits','[]'::jsonb)) LOOP
    PERFORM public.chit_grant(v_o.counterparty_user_id, (v_e->>'chit_id')::UUID,
      -(v_e->>'quantity')::INTEGER, 'barter_out', p_offer_id, v_o.initiator_user_id);
    PERFORM public.chit_grant(v_o.initiator_user_id, (v_e->>'chit_id')::UUID,
       (v_e->>'quantity')::INTEGER, 'barter_in', p_offer_id, v_o.counterparty_user_id);
  END LOOP;

  -- Move tokens (either direction).
  PERFORM public._barter_move_tokens(v_o.initiator_user_id, v_o.counterparty_user_id,
    COALESCE((v_o.offer->>'tokens')::INTEGER, 0), p_offer_id);
  PERFORM public._barter_move_tokens(v_o.counterparty_user_id, v_o.initiator_user_id,
    COALESCE((v_o.request->>'tokens')::INTEGER, 0), p_offer_id);

  UPDATE public.chit_barter_offers
  SET status = 'accepted', resolved_at = NOW(), settled_reference_id = p_offer_id
  WHERE id = p_offer_id;

  INSERT INTO public.chit_barter_events
    (offer_id, initiator_user_id, counterparty_user_id, offer, request, was_kyc_gated)
  VALUES (p_offer_id, v_o.initiator_user_id, v_o.counterparty_user_id,
          v_o.offer, v_o.request, v_o.requires_kyc);
END;
$$;

-- ── RLS: parties see their own offers/events; writes via the RPCs above ─────────
ALTER TABLE public.chit_barter_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chit_barter_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "barter_offers_select_party" ON public.chit_barter_offers
  FOR SELECT USING (auth.uid() IN (initiator_user_id, counterparty_user_id));

CREATE POLICY "barter_events_select_party" ON public.chit_barter_events
  FOR SELECT USING (auth.uid() IN (initiator_user_id, counterparty_user_id));
