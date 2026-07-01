-- Migration 130: Vibe Meter schema + wiring (Phase 4 — P4).
--
-- The per-match Vibe Meter (0–100): a shared, symmetric, server-authoritative hype gauge
-- with a passive floor / slow rise, so it works in thin or non-monetized matches. Vibe is
-- the second resource gate ("is the crowd hyped?"). Depends on ZERO legacy tables.
--
-- Two values: `vibe` (live, broadcast over Realtime) and `available_vibe` (latched at the
-- round boundary — the value the engine reads for Vibe-gated chits, so a mid-turn spike
-- only unlocks at the NEXT round). Thresholds = the chits' own vibe_gate values.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 4.

-- ── match_vibe ──────────────────────────────────────────────────────────────────
CREATE TABLE public.match_vibe (
  match_id        UUID PRIMARY KEY REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  vibe            SMALLINT NOT NULL DEFAULT 0  CHECK (vibe BETWEEN 0 AND 100),           -- live (broadcast)
  available_vibe  SMALLINT NOT NULL DEFAULT 0  CHECK (available_vibe BETWEEN 0 AND 100), -- latched at round boundary
  vibe_floor      SMALLINT NOT NULL DEFAULT 15 CHECK (vibe_floor BETWEEN 0 AND 100),     -- passive floor
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── ccg_vibe_events (activity pulses feeding the multi-factor target) ────────────
-- market activity (P5 bets), spectator presence, token reactions all pulse here.
CREATE TABLE public.ccg_vibe_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id    UUID NOT NULL REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  source      TEXT NOT NULL CHECK (source IN ('market_bet','spectator','token_reaction')),
  weight      INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ccg_vibe_events_recent_idx ON public.ccg_vibe_events (match_id, created_at DESC);

-- ── record a Vibe signal (called by P5 bets, reactions, spectator join) ──────────
CREATE OR REPLACE FUNCTION public.ccg_record_vibe_signal(
  p_match_id UUID, p_source TEXT, p_weight INTEGER DEFAULT 1
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.ccg_vibe_events (match_id, source, weight)
  VALUES (p_match_id, p_source, GREATEST(COALESCE(p_weight,1),1));
END;
$$;

-- ── engine reads the LATCHED value (repoints the P3 stub) ───────────────────────
CREATE OR REPLACE FUNCTION public.ccg_get_match_vibe(p_match_id UUID)
RETURNS SMALLINT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT available_vibe FROM public.match_vibe WHERE match_id = p_match_id),
    (SELECT current_vibe   FROM public.ccg_matches WHERE id = p_match_id),
    0::SMALLINT);
$$;

-- ── latch available_vibe at each round boundary (turn advance) ───────────────────
-- Avoids touching ccg_begin_turn: a turn_number change = a new round = latch live→available.
CREATE OR REPLACE FUNCTION public.ccg_latch_vibe_on_turn()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  UPDATE public.match_vibe SET available_vibe = vibe, updated_at = NOW()
  WHERE match_id = NEW.id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ccg_matches_latch_vibe
  AFTER UPDATE ON public.ccg_matches
  FOR EACH ROW WHEN (NEW.turn_number IS DISTINCT FROM OLD.turn_number)
  EXECUTE FUNCTION public.ccg_latch_vibe_on_turn();

-- ── RLS: vibe is a spectator-facing meter (public read); events are server-only ─
ALTER TABLE public.match_vibe      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ccg_vibe_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "match_vibe_public_read" ON public.match_vibe
  FOR SELECT USING (true);
-- ccg_vibe_events: no client policy (server-only; the tick reads it as definer).

-- ── Realtime: broadcast match_vibe + the CCG event stream to clients ────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='match_vibe') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.match_vibe;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname='supabase_realtime' AND tablename='ccg_events') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.ccg_events;
  END IF;
END $$;
