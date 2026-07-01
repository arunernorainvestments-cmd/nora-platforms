-- Migration 126: v3 CCG engine schema (Phase 3 — P3.1).
--
-- The card-battler board state. NEW `ccg_*` artifacts — the legacy 1v1 `battle_*` engine
-- (mig 060–069/091/103/106) is left intact (still deployed + consumed by nora-arena) and
-- is archived-not-dropped in P7. Prediction markets wire to ccg_matches in P5.
--
-- Server-authoritative: the client computes NOTHING; it replays ccg_events. Match-start
-- stat SNAPSHOT (Hard Rule 36) lives on ccg_match_cards.snap_* so mid-match ascension can
-- never alter an active match.
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 3.1/3.7/3.8.

-- ── ccg_matches ─────────────────────────────────────────────────────────────────
CREATE TABLE public.ccg_matches (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','finished','abandoned')),
  turn_number   INTEGER NOT NULL DEFAULT 1 CHECK (turn_number >= 1),
  active_seat   SMALLINT NOT NULL DEFAULT 1 CHECK (active_seat IN (1,2)),
  winner_seat   SMALLINT CHECK (winner_seat IN (1,2)),
  current_vibe  SMALLINT NOT NULL DEFAULT 0 CHECK (current_vibe BETWEEN 0 AND 100), -- P4 drives match_vibe; engine reads via get_match_vibe()
  is_test       BOOLEAN NOT NULL DEFAULT FALSE,   -- true = synthetic/bot match (seats may be null)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at   TIMESTAMPTZ
);

CREATE INDEX ccg_matches_status_idx ON public.ccg_matches (status);

-- ── ccg_match_players (one row per seat) ────────────────────────────────────────
CREATE TABLE public.ccg_match_players (
  match_id   UUID NOT NULL REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  seat       SMALLINT NOT NULL CHECK (seat IN (1,2)),
  user_id    UUID REFERENCES auth.users(id),   -- NULL allowed for test/bot seats
  deck_id    UUID REFERENCES public.decks(id),
  life       INTEGER NOT NULL DEFAULT 30,
  aura       INTEGER NOT NULL DEFAULT 0 CHECK (aura >= 0),
  max_aura   INTEGER NOT NULL DEFAULT 0 CHECK (max_aura BETWEEN 0 AND 10),
  PRIMARY KEY (match_id, seat)
);

CREATE INDEX ccg_match_players_user_idx ON public.ccg_match_players (user_id);

-- ── ccg_match_cards (card instances = the match-start snapshot + live state) ─────
CREATE TABLE public.ccg_match_cards (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id           UUID NOT NULL REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  owner_seat         SMALLINT NOT NULL CHECK (owner_seat IN (1,2)),
  chit_id            UUID NOT NULL REFERENCES public.moment_chits(id),

  zone               TEXT NOT NULL DEFAULT 'deck' CHECK (zone IN ('deck','hand','field','graveyard')),
  field_pos          SMALLINT CHECK (field_pos BETWEEN 1 AND 3),
  deck_order         INTEGER NOT NULL DEFAULT 0,   -- draw order within the deck

  -- SNAPSHOT at match start (Hard Rule 36) — never re-read from moment_chits mid-match.
  snap_chit_type     TEXT NOT NULL,
  snap_family        TEXT NOT NULL,
  snap_tier          TEXT NOT NULL,
  snap_aura_cost     INTEGER NOT NULL,
  snap_atk           INTEGER,
  snap_hp            INTEGER,
  snap_keywords      TEXT[] NOT NULL DEFAULT '{}',
  snap_timing        TEXT,
  snap_vibe_gate     INTEGER,
  snap_effect_kind   TEXT,
  snap_effect_target TEXT,
  snap_effect_magnitude INTEGER,
  snap_trigger_condition TEXT,

  -- Live combat state.
  cur_atk            INTEGER,
  cur_hp             INTEGER,
  shield             INTEGER NOT NULL DEFAULT 0 CHECK (shield >= 0),
  is_summoning_sick  BOOLEAN NOT NULL DEFAULT TRUE,
  has_attacked       BOOLEAN NOT NULL DEFAULT FALSE,
  summoned_turn      INTEGER,   -- turn it entered the field (fusion window)

  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ccg_cards_match_zone_idx ON public.ccg_match_cards (match_id, owner_seat, zone);
CREATE INDEX ccg_cards_field_idx      ON public.ccg_match_cards (match_id, zone) WHERE zone = 'field';

-- ── ccg_events (ordered, server-authoritative, with *_after reconciliation) ─────
CREATE TABLE public.ccg_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id          UUID NOT NULL REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  turn_number       INTEGER NOT NULL,
  sequence_in_turn  INTEGER NOT NULL,
  event_type        TEXT NOT NULL CHECK (event_type IN (
    'match_start','turn_start','draw','summon','cast','activate','attack',
    'effect','fusion','ko','life_change','aura_change','vibe_change','turn_end','match_end'
  )),
  actor_seat        SMALLINT CHECK (actor_seat IN (1,2)),
  payload           JSONB NOT NULL DEFAULT '{}',
  -- reconciliation snapshot after the event
  life_p1_after     INTEGER,
  life_p2_after     INTEGER,
  aura_active_after INTEGER,
  vibe_after        SMALLINT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (match_id, turn_number, sequence_in_turn)
);

CREATE INDEX ccg_events_replay_idx ON public.ccg_events (match_id, turn_number, sequence_in_turn);

-- ── RLS: participants read their match; client never writes (resolver is SECURITY DEFINER) ─
ALTER TABLE public.ccg_matches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ccg_match_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ccg_match_cards   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ccg_events        ENABLE ROW LEVEL SECURITY;

-- A user can see a match they're seated in (or public test matches).
CREATE POLICY "ccg_matches_select" ON public.ccg_matches
  FOR SELECT USING (
    is_test OR EXISTS (
      SELECT 1 FROM public.ccg_match_players p
      WHERE p.match_id = ccg_matches.id AND p.user_id = auth.uid()
    )
  );

CREATE POLICY "ccg_players_select" ON public.ccg_match_players
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.ccg_matches m WHERE m.id = ccg_match_players.match_id
            AND (m.is_test OR EXISTS (
              SELECT 1 FROM public.ccg_match_players p2
              WHERE p2.match_id = m.id AND p2.user_id = auth.uid())))
  );

-- Cards: a player sees their own hand/deck + everything on the field/graveyard; opponent
-- hand/deck stay hidden. (Spectator/test visibility handled by is_test.)
CREATE POLICY "ccg_cards_select" ON public.ccg_match_cards
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.ccg_matches m
      JOIN public.ccg_match_players p ON p.match_id = m.id
      WHERE m.id = ccg_match_cards.match_id
        AND (m.is_test
             OR (p.user_id = auth.uid() AND (
                   ccg_match_cards.zone IN ('field','graveyard')
                   OR ccg_match_cards.owner_seat = p.seat)))
    )
  );

CREATE POLICY "ccg_events_select" ON public.ccg_events
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.ccg_matches m
      WHERE m.id = ccg_events.match_id
        AND (m.is_test OR EXISTS (
          SELECT 1 FROM public.ccg_match_players p
          WHERE p.match_id = m.id AND p.user_id = auth.uid()))
    )
  );
