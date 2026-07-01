-- Migration 117: chit ownership — append-only acquisition ledger + derived holdings.
--
-- Source of truth is the append-only `chit_acquisition_ledger` (signed quantity deltas).
-- `chit_ownership` is a trigger-maintained holdings table (fast reads, RLS-friendly),
-- mirroring the likeness_card_transfers → current_owner trigger pattern (mig 081).
-- Copies of the same chit are fungible.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 1; plan P1.2.

-- ── chit_acquisition_ledger (append-only) ───────────────────────────────────────
CREATE TABLE public.chit_acquisition_ledger (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chit_id              UUID NOT NULL REFERENCES public.moment_chits(id),

  -- Signed: +N acquire, -N disposal (barter-away). Nonzero.
  quantity_delta       INTEGER NOT NULL CHECK (quantity_delta <> 0),

  reason               TEXT NOT NULL CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction'
  )),
  reference_id         UUID,                                   -- barter offer / pack / event
  counterparty_user_id UUID REFERENCES auth.users(id),         -- other side of a barter/gift
  notes                TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX chit_ledger_user_idx  ON public.chit_acquisition_ledger (user_id, created_at DESC);
CREATE INDEX chit_ledger_chit_idx  ON public.chit_acquisition_ledger (chit_id);
CREATE INDEX chit_ledger_ref_idx   ON public.chit_acquisition_ledger (reference_id);

-- ── chit_ownership (derived holdings) ───────────────────────────────────────────
CREATE TABLE public.chit_ownership (
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  quantity    INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, chit_id)
);

CREATE INDEX chit_ownership_chit_idx ON public.chit_ownership (chit_id);

-- ── append-only guard: ledger rows are immutable ────────────────────────────────
CREATE OR REPLACE FUNCTION public.chit_ledger_block_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'chit_acquisition_ledger is append-only (no UPDATE/DELETE)';
END;
$$;

CREATE TRIGGER chit_ledger_no_update
  BEFORE UPDATE OR DELETE ON public.chit_acquisition_ledger
  FOR EACH ROW EXECUTE FUNCTION public.chit_ledger_block_mutation();

-- ── holdings maintenance: apply each ledger row to chit_ownership ────────────────
CREATE OR REPLACE FUNCTION public.apply_chit_ledger_to_holdings()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.chit_ownership (user_id, chit_id, quantity, updated_at)
  VALUES (NEW.user_id, NEW.chit_id, NEW.quantity_delta, NOW())
  ON CONFLICT (user_id, chit_id) DO UPDATE
    SET quantity   = chit_ownership.quantity + NEW.quantity_delta,
        updated_at = NOW();

  -- Guard: a disposal can never drive holdings negative.
  IF (SELECT quantity FROM public.chit_ownership
      WHERE user_id = NEW.user_id AND chit_id = NEW.chit_id) < 0 THEN
    RAISE EXCEPTION 'Insufficient chit holdings for user % chit %', NEW.user_id, NEW.chit_id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER chit_ledger_apply_holdings
  AFTER INSERT ON public.chit_acquisition_ledger
  FOR EACH ROW EXECUTE FUNCTION public.apply_chit_ledger_to_holdings();

-- ── grant helper (server-only): records an acquisition + maintains holdings ──────
-- Used by mint (P6), pack grant (mig 120), gifting, and barter (mig 119).
CREATE OR REPLACE FUNCTION public.chit_grant(
  p_user_id      UUID,
  p_chit_id      UUID,
  p_quantity     INTEGER,
  p_reason       TEXT,
  p_reference_id UUID DEFAULT NULL,
  p_counterparty UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ledger_id UUID;
BEGIN
  IF p_quantity = 0 THEN
    RAISE EXCEPTION 'chit_grant quantity must be nonzero';
  END IF;

  INSERT INTO public.chit_acquisition_ledger
    (user_id, chit_id, quantity_delta, reason, reference_id, counterparty_user_id)
  VALUES (p_user_id, p_chit_id, p_quantity, p_reason, p_reference_id, p_counterparty)
  RETURNING id INTO v_ledger_id;

  RETURN v_ledger_id;
END;
$$;

-- ── RLS: users read their own holdings/ledger; no client writes ─────────────────
ALTER TABLE public.chit_acquisition_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chit_ownership          ENABLE ROW LEVEL SECURITY;

CREATE POLICY "chit_ledger_select_own" ON public.chit_acquisition_ledger
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "chit_ownership_select_own" ON public.chit_ownership
  FOR SELECT USING (auth.uid() = user_id);

-- Writes only via SECURITY DEFINER (chit_grant / barter / pack grant). No client policies.
