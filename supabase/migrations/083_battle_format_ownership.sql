-- ─────────────────────────────────────────────────────────────────────────────
-- 083 — Battle Format & Ownership Gate (Redesign Doc 1)
--
-- Adds a format column to battle_matches (1v1/2v2/3v3), links participants to
-- the likeness card granting eligibility, and provides eligibility helpers
-- used by battle_create_lobby and battle_join_lobby (modified in doc 2).
--
-- Deviation from doc: `p.category` → `LOWER(p.category_1)`. The actual column
-- is `category_1` (CHECK values capitalized like 'Athlete'); LOWER() so the
-- returned archetype matches the lowercase archetype convention used by
-- likeness_offerings and battle artifacts.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE battle_matches
  ADD COLUMN format TEXT NOT NULL DEFAULT '3v3'
    CHECK (format IN ('1v1', '2v2', '3v3'));

ALTER TABLE battle_participants
  ADD COLUMN likeness_card_id UUID REFERENCES likeness_cards(id),
  ADD COLUMN creator_id        UUID REFERENCES auth.users(id);
-- creator_id: the market maker this participant represents.
-- likeness_card_id: the card granting eligibility (NULL if creator = user_id).

CREATE INDEX battle_participants_creator_idx
  ON battle_participants (creator_id);

CREATE INDEX battle_participants_card_idx
  ON battle_participants (likeness_card_id)
  WHERE likeness_card_id IS NOT NULL;

-- ── check_battle_eligibility ────────────────────────────────────────────────
-- Returns whether the user can field the given creator in Battle.
-- 'self'  = user IS the creator
-- 'owner' = user owns at least one active likeness_card for this creator
CREATE OR REPLACE FUNCTION check_battle_eligibility(
  p_user_id    UUID,
  p_creator_id UUID
)
RETURNS TABLE (
  is_eligible      BOOLEAN,
  card_id          UUID,
  eligibility_type TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_user_id = p_creator_id THEN
    RETURN QUERY SELECT TRUE, NULL::UUID, 'self'::TEXT;
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      TRUE,
      lc.id,
      'owner'::TEXT
    FROM likeness_cards lc
    JOIN likeness_offerings lo ON lo.id = lc.offering_id
    WHERE lc.current_owner_id = p_user_id
      AND lo.creator_id = p_creator_id
      AND lc.is_active = TRUE
    LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'none'::TEXT;
  END IF;
END;
$$;

-- ── get_eligible_characters ─────────────────────────────────────────────────
-- All characters a user can field: self (if market maker) + owned cards.
CREATE OR REPLACE FUNCTION get_eligible_characters(p_user_id UUID)
RETURNS TABLE (
  creator_id          UUID,
  character_name      TEXT,
  archetype           TEXT,
  character_image_url TEXT,
  eligibility_type    TEXT,
  card_id             UUID,
  card_number         INTEGER,
  rarity              TEXT,
  stat_power          INTEGER,
  stat_charisma       INTEGER,
  stat_resilience     INTEGER,
  stat_agility        INTEGER,
  stat_wit            INTEGER,
  stat_influence      INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
    SELECT
      p.id,
      COALESCE(p.display_name, p.username)::TEXT,
      LOWER(COALESCE(p.category_1, 'influencer'))::TEXT,
      p.avatar_url,
      'self'::TEXT,
      NULL::UUID, NULL::INTEGER, NULL::TEXT,
      COALESCE(css.effective_power, 50),
      COALESCE(css.effective_charisma, 50),
      COALESCE(css.effective_resilience, 50),
      COALESCE(css.effective_agility, 50),
      COALESCE(css.effective_wit, 50),
      COALESCE(css.effective_influence, 50)
    FROM profiles p
    LEFT JOIN creator_stat_sheets css ON css.user_id = p.id
    WHERE p.id = p_user_id
      AND p.is_market_maker = TRUE
      AND p.pending_opt_out = FALSE;

  RETURN QUERY
    SELECT
      lo.creator_id,
      lo.character_name,
      lo.archetype,
      lo.character_image_url,
      'owner'::TEXT,
      lc.id, lc.card_number, lc.rarity,
      COALESCE(css.effective_power, 50),
      COALESCE(css.effective_charisma, 50),
      COALESCE(css.effective_resilience, 50),
      COALESCE(css.effective_agility, 50),
      COALESCE(css.effective_wit, 50),
      COALESCE(css.effective_influence, 50)
    FROM likeness_cards lc
    JOIN likeness_offerings lo ON lo.id = lc.offering_id
    LEFT JOIN creator_stat_sheets css ON css.user_id = lo.creator_id
    WHERE lc.current_owner_id = p_user_id
      AND lc.is_active = TRUE
      AND lo.status IN ('active', 'sold_out')
      AND lo.creator_id <> p_user_id;  -- exclude self-owned cards (already in 'self' return)
END;
$$;
