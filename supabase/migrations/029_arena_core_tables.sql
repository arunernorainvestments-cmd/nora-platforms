-- Migration 029: Arena core tables
-- Ref: CLAUDE.md "Two-Game Architecture" and "Arena Visual Design"
-- ArenaScore is EPHEMERAL — lives only in arena_state during a match.
-- Never write arena_state.score_* back to display_score, heat_score, or any
-- persistent score column.

-- ── arena_matches ─────────────────────────────────────────────────────────────
-- Static-ish per-match data. One row per match, created by arena_matchmake().
-- state transitions: pending → pre_match → live → resolved

CREATE TABLE public.arena_matches (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  round               smallint    NOT NULL CHECK (round IN (1, 2, 3)),
  state               text        NOT NULL DEFAULT 'pending'
                                  CHECK (state IN ('pending', 'pre_match', 'live', 'resolved')),
  player_1_id         uuid        NOT NULL REFERENCES public.profiles(id),
  player_2_id         uuid        NOT NULL REFERENCES public.profiles(id),
  player_1_archetype  text        NOT NULL,
  player_2_archetype  text        NOT NULL,
  scheduled_start     timestamptz NOT NULL,
  actual_start        timestamptz,
  actual_end          timestamptz,
  winner_id           uuid        REFERENCES public.profiles(id),
  final_score_p1      numeric,
  final_score_p2      numeric,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- tick loop: "find live matches" + "is this creator in a match"
CREATE INDEX arena_matches_state_start_idx ON public.arena_matches (state, scheduled_start);
CREATE INDEX arena_matches_player_1_idx    ON public.arena_matches (player_1_id);
CREATE INDEX arena_matches_player_2_idx    ON public.arena_matches (player_2_id);

-- ── arena_events ──────────────────────────────────────────────────────────────
-- Append-only action log. One row per Back or Trigger action.
-- type='trigger' is a no-op in Phase A (abilities Phase B).

CREATE TABLE public.arena_events (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id    uuid        NOT NULL REFERENCES public.arena_matches(id),
  user_id     uuid        NOT NULL REFERENCES public.profiles(id),
  target_id   uuid        NOT NULL REFERENCES public.profiles(id),
  type        text        NOT NULL CHECK (type IN ('back', 'trigger')),
  value       numeric     NOT NULL,
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  processed   boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- tick loop event pull; per-user backing queries
CREATE INDEX arena_events_match_unprocessed_idx ON public.arena_events (match_id, processed, created_at);
CREATE INDEX arena_events_user_match_idx        ON public.arena_events (user_id, match_id);

-- ── arena_state ───────────────────────────────────────────────────────────────
-- Live mutable state per match. One row per match, PK = match_id.
-- Updated every tick by process_arena_tick().
-- Fields with _p1/_p2 suffix correspond to player_1_id/player_2_id in arena_matches.
-- Phase A: suppression_*, momentum_window_* and active_effects are placeholders —
--          they are kept at defaults and wired in Phase B.

CREATE TABLE public.arena_state (
  match_id            uuid    PRIMARY KEY REFERENCES public.arena_matches(id),
  tick                int     NOT NULL DEFAULT 0,
  score_p1            numeric NOT NULL DEFAULT 0,
  score_p2            numeric NOT NULL DEFAULT 0,
  flow_rate_p1        numeric NOT NULL DEFAULT 0,
  flow_rate_p2        numeric NOT NULL DEFAULT 0,
  heat_influence_p1   numeric NOT NULL DEFAULT 0,
  heat_influence_p2   numeric NOT NULL DEFAULT 0,
  active_effects      jsonb   NOT NULL DEFAULT '[]'::jsonb,
  suppression_p1      numeric NOT NULL DEFAULT 0,
  suppression_p2      numeric NOT NULL DEFAULT 0,
  momentum_window_p1  boolean NOT NULL DEFAULT false,
  momentum_window_p2  boolean NOT NULL DEFAULT false,
  total_pool_p1       numeric NOT NULL DEFAULT 0,
  total_pool_p2       numeric NOT NULL DEFAULT 0,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

-- ── RLS ───────────────────────────────────────────────────────────────────────
-- All three tables: authenticated users read; service role (and SECURITY DEFINER
-- functions) write.

ALTER TABLE public.arena_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.arena_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.arena_state   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "arena_matches: authenticated read"
  ON public.arena_matches FOR SELECT TO authenticated USING (true);

CREATE POLICY "arena_events: authenticated read"
  ON public.arena_events FOR SELECT TO authenticated USING (true);

CREATE POLICY "arena_state: authenticated read"
  ON public.arena_state FOR SELECT TO authenticated USING (true);

-- ── Realtime publications ─────────────────────────────────────────────────────
-- Required so Flutter StreamProvider subscriptions receive live score/event updates.
-- arena_state: published so score changes are pushed to all match viewers each tick.
-- arena_events: published so the event ticker receives new Back/Trigger events.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'arena_state'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.arena_state;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'arena_events'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.arena_events;
  END IF;
END;
$$;
