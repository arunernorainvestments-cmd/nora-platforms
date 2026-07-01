-- Migration 121: mark the v2.x 1v1 fighter model deprecated (Phase 1 — P1.6).
--
-- SEQUENCING NOTE: P1 introduces the NEW deck-based eligibility model and DEPRECATION
-- MARKERS only. The physical archival (rename `battle_abilities` → *_archived, drop the
-- license-per-character eligibility functions) is DEFERRED to Phase 7, because:
--   • the legacy `process_battle_turn` engine is still deployed until P3 replaces it, and
--   • the mobile client (nora-arena) still consumes check_battle_eligibility /
--     get_eligible_characters (RECONCILIATION §1) until it cuts over to the deck model.
-- Renaming/dropping now would break live code with no replacement. So: comment now,
-- archive-not-drop in P7 (Hard Rule 11; P1 DO-NOT "don't drop the archived 1v1 tables").
--
-- v3 eligibility = "you own moment chits and have a legal deck" (RECONCILIATION R2 retired).

COMMENT ON TABLE public.battle_abilities IS
  'DEPRECATED by v3 (2026-07): per-archetype move-sets of the 1v1 fighter. Retired in '
  'favor of moment_chits + effect_templates (P2). Archive-not-drop scheduled for Phase 7; '
  'do NOT extend. See NORA_PLATFORMS_BUILD_SPEC_v3.md.';

COMMENT ON FUNCTION public.check_battle_eligibility(UUID, UUID) IS
  'DEPRECATED by v3 (2026-07): license/card-per-character battle eligibility. v3 eligibility '
  'is deck-based (public.deck_is_legal). Kept until nora-arena cuts over (RECONCILIATION R2); '
  'removal scheduled for Phase 7.';

COMMENT ON FUNCTION public.get_eligible_characters(UUID) IS
  'DEPRECATED by v3 (2026-07): character-fielding eligibility of the 1v1 fighter. Superseded '
  'by moment-chit ownership + legal decks. Kept for the mobile client until cutover; '
  'removal scheduled for Phase 7.';

-- ── the NEW eligibility primitive (deck-based) ──────────────────────────────────
-- Match entry (P3) gates on this: the deck exists, belongs to the user, and passes
-- lean-deck validation (size 20 / max 2 / owned / active).
CREATE OR REPLACE FUNCTION public.deck_is_legal(p_deck_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM public.decks WHERE id = p_deck_id;
  IF v_owner IS NULL OR v_owner <> p_user_id THEN
    RETURN FALSE;
  END IF;
  RETURN (public.deck_validate(p_deck_id)->>'is_valid')::BOOLEAN;
END;
$$;

COMMENT ON FUNCTION public.deck_is_legal(UUID, UUID) IS
  'v3 battle eligibility: TRUE iff the deck belongs to the user and passes lean-deck '
  'validation. Replaces check_battle_eligibility for the card-battler (P3 match entry).';
