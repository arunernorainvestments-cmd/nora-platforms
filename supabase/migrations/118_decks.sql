-- Migration 118: lean decks (Phase 1 — P1.3).
--
-- Lean deck rules: size EXACTLY 20, max 2 copies per chit, every chit owned by the
-- deck owner and active. Validated server-side on save (deck_set_chits) and re-checked
-- at match entry (P3 calls deck_validate). Constants mirror §1 combat constants.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 1.

-- ── decks ───────────────────────────────────────────────────────────────────────
CREATE TABLE public.decks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL DEFAULT 'New Deck',
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  is_legal      BOOLEAN NOT NULL DEFAULT FALSE,   -- last validation result
  validated_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, name)
);

CREATE INDEX decks_user_idx ON public.decks (user_id, is_active);

-- ── deck_chits ──────────────────────────────────────────────────────────────────
CREATE TABLE public.deck_chits (
  deck_id     UUID NOT NULL REFERENCES public.decks(id) ON DELETE CASCADE,
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  quantity    INTEGER NOT NULL CHECK (quantity BETWEEN 1 AND 2),   -- max 2 copies
  PRIMARY KEY (deck_id, chit_id)
);

-- ── deck size / copies constants (config-driven per §1) ─────────────────────────
-- Kept as SQL constants here; when a global config table lands these read from it.
CREATE OR REPLACE FUNCTION public.deck_size_required() RETURNS INTEGER
  LANGUAGE sql IMMUTABLE AS $$ SELECT 20 $$;
CREATE OR REPLACE FUNCTION public.deck_max_copies() RETURNS INTEGER
  LANGUAGE sql IMMUTABLE AS $$ SELECT 2 $$;

-- ── deck_validate: pure check, returns {is_valid, errors[], total} ──────────────
CREATE OR REPLACE FUNCTION public.deck_validate(p_deck_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner   UUID;
  v_total   INTEGER;
  v_errors  TEXT[] := ARRAY[]::TEXT[];
BEGIN
  SELECT user_id INTO v_owner FROM public.decks WHERE id = p_deck_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('is_valid', false, 'errors',
      to_jsonb(ARRAY['deck_not_found']), 'total', 0);
  END IF;

  SELECT COALESCE(SUM(quantity), 0) INTO v_total
  FROM public.deck_chits WHERE deck_id = p_deck_id;

  -- size
  IF v_total <> public.deck_size_required() THEN
    v_errors := v_errors || format('deck_size_must_be_%s_got_%s',
      public.deck_size_required(), v_total);
  END IF;

  -- copies (belt-and-suspenders; also enforced by the column CHECK)
  IF EXISTS (SELECT 1 FROM public.deck_chits
             WHERE deck_id = p_deck_id AND quantity > public.deck_max_copies()) THEN
    v_errors := v_errors || format('max_%s_copies_per_chit', public.deck_max_copies());
  END IF;

  -- every chit active
  IF EXISTS (
    SELECT 1 FROM public.deck_chits dc
    JOIN public.moment_chits mc ON mc.id = dc.chit_id
    WHERE dc.deck_id = p_deck_id AND mc.is_active = FALSE
  ) THEN
    v_errors := v_errors || 'contains_inactive_chit';
  END IF;

  -- ownership: owner must hold at least the deck quantity of each chit
  IF EXISTS (
    SELECT 1 FROM public.deck_chits dc
    LEFT JOIN public.chit_ownership co
      ON co.user_id = v_owner AND co.chit_id = dc.chit_id
    WHERE dc.deck_id = p_deck_id
      AND COALESCE(co.quantity, 0) < dc.quantity
  ) THEN
    v_errors := v_errors || 'does_not_own_all_chits';
  END IF;

  RETURN jsonb_build_object(
    'is_valid', array_length(v_errors, 1) IS NULL,
    'errors',   to_jsonb(v_errors),
    'total',    v_total
  );
END;
$$;

-- ── deck_set_chits: atomic replace + validate + persist legality ────────────────
-- p_chits: jsonb array of {chit_id, quantity}. Caller must own the deck.
CREATE OR REPLACE FUNCTION public.deck_set_chits(p_deck_id UUID, p_chits JSONB)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner  UUID;
  v_result JSONB;
BEGIN
  SELECT user_id INTO v_owner FROM public.decks WHERE id = p_deck_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Deck not found: %', p_deck_id;
  END IF;
  IF v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'Not your deck';
  END IF;

  DELETE FROM public.deck_chits WHERE deck_id = p_deck_id;

  INSERT INTO public.deck_chits (deck_id, chit_id, quantity)
  SELECT p_deck_id,
         (e->>'chit_id')::UUID,
         (e->>'quantity')::INTEGER
  FROM jsonb_array_elements(p_chits) AS e;

  v_result := public.deck_validate(p_deck_id);

  UPDATE public.decks
  SET is_legal     = (v_result->>'is_valid')::BOOLEAN,
      validated_at = NOW(),
      updated_at   = NOW()
  WHERE id = p_deck_id;

  RETURN v_result;
END;
$$;

-- ── touch updated_at ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.touch_deck_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END;
$$;

CREATE TRIGGER decks_touch_updated
  BEFORE UPDATE ON public.decks
  FOR EACH ROW EXECUTE FUNCTION public.touch_deck_updated_at();

-- ── RLS: users manage their own decks; deck_chits scoped through the deck ───────
ALTER TABLE public.decks      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deck_chits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "decks_all_own" ON public.decks
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE POLICY "deck_chits_select_own" ON public.deck_chits
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.decks d WHERE d.id = deck_chits.deck_id AND d.user_id = auth.uid()
  ));

-- Mutations to deck_chits go through deck_set_chits (SECURITY DEFINER) so validation
-- runs atomically; no direct client INSERT/UPDATE/DELETE policy.
