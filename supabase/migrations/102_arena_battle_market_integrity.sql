-- ─────────────────────────────────────────────────────────────────────────────
-- 102 — Arena / Battle market integrity + KYC backstop
--
-- Enforces the "one role per match" invariant: for a match with an open
-- battle_outcome prediction market, a verified human is either a COMBATANT
-- (uses chits, cannot bet) or a SPECTATOR (bets, cannot influence) — never both.
--
-- Backed by KYC: identity_hash links alt accounts of the same verified human so
-- the rule holds across accounts, not just a single auth.uid().
--
-- See docs/battle-chits-and-arena-integrity.md §2 + §4.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. identity_hash on kyc_verifications (one human → one staking identity) ──
ALTER TABLE public.kyc_verifications
  ADD COLUMN IF NOT EXISTS identity_hash TEXT;

-- One approved identity may map to only one account. NULLs (sim mode, un-hashed)
-- are ignored by the partial unique index.
CREATE UNIQUE INDEX IF NOT EXISTS kyc_identity_hash_unique_idx
  ON public.kyc_verifications (identity_hash)
  WHERE status = 'approved' AND identity_hash IS NOT NULL;

-- ── 2. Singleton settings row gating enforcement ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.platform_integrity_settings (
  id                          BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  enforce_one_role_per_match  BOOLEAN NOT NULL DEFAULT TRUE,   -- integrity (money-independent)
  require_kyc_for_staking     BOOLEAN NOT NULL DEFAULT FALSE,  -- flip TRUE at live launch
  require_kyc_for_combatant   BOOLEAN NOT NULL DEFAULT FALSE,  -- flip TRUE at live launch
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.platform_integrity_settings (id) VALUES (TRUE)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.platform_integrity_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "integrity_settings_public_read" ON public.platform_integrity_settings;
CREATE POLICY "integrity_settings_public_read"
  ON public.platform_integrity_settings FOR SELECT USING (TRUE);

-- ── 3. Helpers ───────────────────────────────────────────────────────────────

-- Is this user's KYC currently approved and unexpired?
CREATE OR REPLACE FUNCTION public.is_kyc_verified(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM kyc_verifications
    WHERE user_id = p_user_id
      AND status = 'approved'
      AND (expires_at IS NULL OR expires_at > NOW())
  );
$$;

-- Every account that belongs to the same verified human as p_user_id (incl. self).
-- Accounts without an approved identity_hash resolve to just themselves.
CREATE OR REPLACE FUNCTION public.identity_linked_users(p_user_id UUID)
RETURNS TABLE (user_id UUID)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT p_user_id
  UNION
  SELECT k.user_id
  FROM kyc_verifications k
  WHERE k.status = 'approved'
    AND k.identity_hash IS NOT NULL
    AND k.identity_hash IN (
      SELECT identity_hash FROM kyc_verifications
      WHERE user_id = p_user_id AND status = 'approved' AND identity_hash IS NOT NULL
    );
$$;

-- Is p_user_id (or any KYC-linked alt) a combatant in this battle match?
CREATE OR REPLACE FUNCTION public.is_match_combatant(p_match_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM battle_participants bp
    WHERE bp.match_id = p_match_id
      AND bp.user_id IN (SELECT user_id FROM identity_linked_users(p_user_id))
  );
$$;

-- ── 4. Bet integrity: combatants (and their alts) may not bet on their match ──
CREATE OR REPLACE FUNCTION public.enforce_bet_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_res        TEXT;
  v_match_id   UUID;
  v_settings   platform_integrity_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_settings FROM platform_integrity_settings WHERE id = TRUE;

  -- KYC gate for any staking (live mode only).
  IF COALESCE(v_settings.require_kyc_for_staking, FALSE)
     AND NOT is_kyc_verified(NEW.user_id) THEN
    RAISE EXCEPTION 'KYC verification required before placing a bet';
  END IF;

  SELECT resolution_type, battle_match_id INTO v_res, v_match_id
  FROM markets WHERE id = NEW.market_id;

  IF v_res = 'battle_outcome' AND v_match_id IS NOT NULL
     AND COALESCE(v_settings.enforce_one_role_per_match, TRUE) THEN
    IF is_match_combatant(v_match_id, NEW.user_id) THEN
      RAISE EXCEPTION 'You are competing in this match — combatants cannot bet on their own battle';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- BEFORE INSERT so it aborts ahead of the 004 pool/token AFTER-insert triggers.
DROP TRIGGER IF EXISTS trg_enforce_bet_integrity ON public.bets;
CREATE TRIGGER trg_enforce_bet_integrity
  BEFORE INSERT ON public.bets
  FOR EACH ROW EXECUTE FUNCTION public.enforce_bet_integrity();

-- ── 5. Legacy Arena: a backer can't trigger and a triggerer can't back ───────
-- Retires the audience-influence-while-staked dynamic without touching the large
-- arena_back / arena_trigger functions (both insert into arena_events, so a guard
-- here aborts their atomic transaction and rolls back the token debit).
CREATE OR REPLACE FUNCTION public.enforce_arena_event_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_settings platform_integrity_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_settings FROM platform_integrity_settings WHERE id = TRUE;
  IF NOT COALESCE(v_settings.enforce_one_role_per_match, TRUE) THEN
    RETURN NEW;
  END IF;

  IF NEW.type = 'trigger' THEN
    IF EXISTS (
      SELECT 1 FROM arena_events e
      WHERE e.match_id = NEW.match_id AND e.type = 'back'
        AND e.user_id IN (SELECT user_id FROM identity_linked_users(NEW.user_id))
    ) THEN
      RAISE EXCEPTION 'You have backed a creator in this match — backers cannot trigger powerups (market integrity)';
    END IF;
  ELSIF NEW.type = 'back' THEN
    IF EXISTS (
      SELECT 1 FROM arena_events e
      WHERE e.match_id = NEW.match_id AND e.type = 'trigger'
        AND e.user_id IN (SELECT user_id FROM identity_linked_users(NEW.user_id))
    ) THEN
      RAISE EXCEPTION 'You have triggered a powerup in this match — you cannot also back a creator (market integrity)';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_arena_event_integrity ON public.arena_events;
CREATE TRIGGER trg_enforce_arena_event_integrity
  BEFORE INSERT ON public.arena_events
  FOR EACH ROW EXECUTE FUNCTION public.enforce_arena_event_integrity();

-- ── 6. Combatant KYC gate (flag-gated; no-op until live launch) ──────────────
CREATE OR REPLACE FUNCTION public.enforce_combatant_kyc()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_settings platform_integrity_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_settings FROM platform_integrity_settings WHERE id = TRUE;
  IF COALESCE(v_settings.require_kyc_for_combatant, FALSE)
     AND NEW.user_id IS NOT NULL
     AND NOT COALESCE(NEW.is_automated, FALSE)
     AND NOT is_kyc_verified(NEW.user_id) THEN
    RAISE EXCEPTION 'KYC verification required before entering a battle';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_combatant_kyc ON public.battle_participants;
CREATE TRIGGER trg_enforce_combatant_kyc
  BEFORE INSERT ON public.battle_participants
  FOR EACH ROW EXECUTE FUNCTION public.enforce_combatant_kyc();
