-- Migration 120: premium chit packs on the lkn_* licensing rail (Phase 1 — P1.5).
--
-- A premium pack is a set of `licensed`-class moment_chits sold for real money under a
-- licensing listing (lkn_listings). This migration defines the pack + the grant
-- mechanism; the real-money PURCHASE wiring (Stripe / currency branch) lands in P5.
-- Until then packs are sim-mode and granted via chit_pack_grant by a server path.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 1.

CREATE TABLE public.chit_packs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT NOT NULL,
  description       TEXT,
  -- The licensor whose licensed chits this pack sells (earns the royalty in P5).
  licensor_user_id  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  -- The licensing listing this pack rides on (lkn_* plumbing).
  lkn_listing_id    UUID REFERENCES public.lkn_listings(id) ON DELETE SET NULL,
  price_usd_cents   BIGINT NOT NULL DEFAULT 0 CHECK (price_usd_cents >= 0),
  payments_mode     TEXT NOT NULL DEFAULT 'sim' CHECK (payments_mode IN ('sim','live')),
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX chit_packs_active_idx ON public.chit_packs (is_active);

CREATE TABLE public.chit_pack_contents (
  pack_id     UUID NOT NULL REFERENCES public.chit_packs(id) ON DELETE CASCADE,
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  quantity    INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  PRIMARY KEY (pack_id, chit_id)
);

-- Pack contents must be licensed-class chits (a premium pack sells licensed content).
CREATE OR REPLACE FUNCTION public.chit_pack_contents_guard()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (SELECT character_class FROM public.moment_chits WHERE id = NEW.chit_id) <> 'licensed' THEN
    RAISE EXCEPTION 'Premium packs may only contain licensed-class chits (chit %)', NEW.chit_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER chit_pack_contents_licensed
  BEFORE INSERT OR UPDATE ON public.chit_pack_contents
  FOR EACH ROW EXECUTE FUNCTION public.chit_pack_contents_guard();

-- ── chit_pack_grant: grant a purchased pack's chits into the ledger ─────────────
-- Called by the purchase flow (sim now; P5 wires real-money entry + idempotency).
-- p_reference_id is the purchase/receipt id used for the acquisition ledger + idempotency.
CREATE OR REPLACE FUNCTION public.chit_pack_grant(
  p_user_id      UUID,
  p_pack_id      UUID,
  p_reference_id UUID DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_c RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.chit_packs WHERE id = p_pack_id AND is_active) THEN
    RAISE EXCEPTION 'Pack not found or inactive: %', p_pack_id;
  END IF;

  -- Idempotency: skip if this reference already granted this pack to this user.
  IF p_reference_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.chit_acquisition_ledger
    WHERE user_id = p_user_id AND reason = 'pack_purchase' AND reference_id = p_reference_id
  ) THEN
    RETURN;
  END IF;

  FOR v_c IN SELECT chit_id, quantity FROM public.chit_pack_contents WHERE pack_id = p_pack_id LOOP
    PERFORM public.chit_grant(p_user_id, v_c.chit_id, v_c.quantity, 'pack_purchase', p_reference_id);
  END LOOP;
END;
$$;

-- ── RLS: packs + contents public-read; grant is server-only ─────────────────────
ALTER TABLE public.chit_packs         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chit_pack_contents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "chit_packs_select_active" ON public.chit_packs
  FOR SELECT USING (is_active);

CREATE POLICY "chit_pack_contents_select" ON public.chit_pack_contents
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.chit_packs p WHERE p.id = chit_pack_contents.pack_id AND p.is_active
  ));
