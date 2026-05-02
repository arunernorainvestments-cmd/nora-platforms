-- Migration 045: Match telemetry table + arena_state extensions
-- Telemetry row is written at match resolution by process_arena_tick() v3.
-- expired_effects is added to arena_state for Religion:Revival (needs effect history).

-- ── Add expired_effects to arena_state ───────────────────────────────────────
-- Populated during tick decay: when a trigger effect expires, it's prepended to
-- this array (capped at 10 entries) before removal from active_effects.
-- Religion:Revival reads the most recent entry for this player's side.

ALTER TABLE public.arena_state
  ADD COLUMN IF NOT EXISTS expired_effects jsonb NOT NULL DEFAULT '[]'::jsonb;

-- ── arena_match_telemetry ─────────────────────────────────────────────────────

CREATE TABLE public.arena_match_telemetry (
  match_id          uuid      PRIMARY KEY REFERENCES public.arena_matches(id),
  archetype_p1      text      NOT NULL,
  archetype_p2      text      NOT NULL,
  subcategory_p1    text,
  subcategory_p2    text,
  total_back_p1     numeric   NOT NULL,
  total_back_p2     numeric   NOT NULL,
  total_trigger_p1  numeric   NOT NULL,
  total_trigger_p2  numeric   NOT NULL,
  unique_backers_p1 integer   NOT NULL,
  unique_backers_p2 integer   NOT NULL,
  abilities_used_p1 jsonb     NOT NULL,
  abilities_used_p2 jsonb     NOT NULL,
  final_score_p1    numeric   NOT NULL,
  final_score_p2    numeric   NOT NULL,
  winner_archetype  text      NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.arena_match_telemetry ENABLE ROW LEVEL SECURITY;

-- Service role writes; authenticated users can read for leaderboard/balance analysis tools.
CREATE POLICY "arena_match_telemetry: authenticated read"
  ON public.arena_match_telemetry FOR SELECT TO authenticated USING (true);

CREATE INDEX arena_match_telemetry_archetype_idx
  ON public.arena_match_telemetry (archetype_p1, archetype_p2);
CREATE INDEX arena_match_telemetry_created_idx
  ON public.arena_match_telemetry (created_at DESC);
