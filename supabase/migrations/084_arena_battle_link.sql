-- ─────────────────────────────────────────────────────────────────────────────
-- 084 — Arena ↔ Battle Link (Redesign Doc 1)
--
-- Hard Rule 21 changes when this lands:
--   OLD: "Battle and Arena are entirely separate"
--   NEW: "Battle matches are the source of truth for linked Arena markets.
--         Arena auto-opens on battle_start_match and resolves on battle
--         resolution only. Battle artifacts remain prefixed battle_.
--         Arena artifacts remain unprefixed."
--
-- arena_matches gets battle_match_id + resolution_type. The legacy 'display_score'
-- resolution path is preserved for existing Markets; new battle-linked markets
-- use 'battle_outcome' and are resolved against battle_matches.winner_team_number.
--
-- bets.position CHECK is extended to allow 'team_1' / 'team_2' for battle-linked
-- markets. Legacy 'yes' / 'no' positions remain valid for display_score markets.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE arena_matches
  ADD COLUMN battle_match_id  UUID REFERENCES battle_matches(id),
  ADD COLUMN resolution_type  TEXT NOT NULL DEFAULT 'display_score'
    CHECK (resolution_type IN ('display_score', 'battle_outcome'));

ALTER TABLE arena_matches
  ADD CONSTRAINT battle_link_requires_outcome CHECK (
    (battle_match_id IS NULL) OR (resolution_type = 'battle_outcome')
  );

CREATE INDEX arena_battle_link_idx
  ON arena_matches (battle_match_id)
  WHERE battle_match_id IS NOT NULL;

-- ── Extend bets.position CHECK to allow team_1 / team_2 ─────────────────────
ALTER TABLE public.bets DROP CONSTRAINT IF EXISTS bets_position_check;

ALTER TABLE public.bets
  ADD CONSTRAINT bets_position_check
  CHECK (position IN ('yes', 'no', 'team_1', 'team_2'));

-- NOTE: doc 2 modifies the resolve-markets edge function to branch on
-- arena_matches.resolution_type. Display Score (legacy) and battle_outcome
-- (new) take different resolution paths.
