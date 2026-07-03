-- Migration 145: M-P5 — integration glue Arena depends on (minting spec PHASE 5).
--
--   1. profiles.avatar_loadout — Platforms PERSISTS what Arena's Dressing Room
--      writes; it never edits or interprets it (no web 3D editor). Client-writable
--      through the existing own-update RLS on profiles (mig 001).
--   2. ccg_matches.is_monetized — set per decision gate G-MON (real-money market
--      exists iff BOTH players are KYC-verified, Hard Rule 35). Arena reads it to
--      gate the spectator bet UI; ccg_match_is_monetized() exposes the single bit
--      to any authenticated caller without widening match RLS.
--   3. battle_place_spectator_bet_usd(p_match_id, p_team_number, p_amount_dollars)
--      — the match-scoped RPC Arena's SpectatorMarketService calls (RECONCILIATION
--      §7/R3: the canonical mobile bet path). Thin wrapper over the mig-133
--      ccg_place_bet: resolves the open battle_outcome market from the match; all
--      KYC / one-role / eligibility enforcement stays in the mig-133 triggers.

-- ── 1. avatar loadout ─────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_loadout JSONB
    CHECK (avatar_loadout IS NULL OR (
      jsonb_typeof(avatar_loadout) = 'object' AND pg_column_size(avatar_loadout) <= 8192
    ));

COMMENT ON COLUMN public.profiles.avatar_loadout IS
  'Arena Dressing Room state (e.g. {"Gender":"Male","SkinId":"skin_male_casual"}). '
  'Platforms persists only — never edits, never interprets (minting spec P5). '
  'Client-writable via the own-update profiles policy; capped at 8 KB.';

-- ── 2. G-MON monetized flag on the match ──────────────────────────────────────────
ALTER TABLE public.ccg_matches
  ADD COLUMN IF NOT EXISTS is_monetized BOOLEAN NOT NULL DEFAULT FALSE;

-- Backfill: any match that already carries a real-money market is monetized.
UPDATE public.ccg_matches m SET is_monetized = TRUE
WHERE EXISTS (SELECT 1 FROM public.markets mk
              WHERE mk.ccg_match_id = m.id AND mk.currency = 'usd');

-- ccg_create_outcome_market (mig 133) now stamps the flag when the G-MON gate
-- passes. Body unchanged otherwise.
CREATE OR REPLACE FUNCTION public.ccg_create_outcome_market(p_match_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_s1 UUID; v_s2 UUID; v_mkt UUID;
BEGIN
  SELECT user_id INTO v_s1 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 1;
  SELECT user_id INTO v_s2 FROM public.ccg_match_players WHERE match_id = p_match_id AND seat = 2;

  -- G-MON gate (decision gate — confirm before live): both must be KYC'd, else non-monetized.
  IF v_s1 IS NULL OR v_s2 IS NULL
     OR NOT public.is_kyc_verified(v_s1) OR NOT public.is_kyc_verified(v_s2) THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_mkt FROM public.markets WHERE ccg_match_id = p_match_id LIMIT 1;
  IF v_mkt IS NOT NULL THEN RETURN v_mkt; END IF;

  INSERT INTO public.markets (title, market_type, target_metric, timeframe, end_at,
    resolution_type, currency, ccg_match_id, status)
  VALUES ('Battle outcome', 'battle_outcome', 'battle_outcome', '24h', NOW() + INTERVAL '1 day',
    'battle_outcome', 'usd', p_match_id, 'open')
  RETURNING id INTO v_mkt;

  UPDATE public.ccg_matches SET is_monetized = TRUE WHERE id = p_match_id;
  RETURN v_mkt;
END;
$$;

-- Single-bit read for spectators (match RLS stays participant-scoped).
CREATE FUNCTION public.ccg_match_is_monetized(p_match_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE((SELECT is_monetized FROM public.ccg_matches WHERE id = p_match_id), FALSE);
$$;

GRANT EXECUTE ON FUNCTION public.ccg_match_is_monetized(UUID) TO authenticated;

-- ── 3. the Arena bet RPC ──────────────────────────────────────────────────────────
-- Mirrors the legacy battle_place_spectator_bet(p_match_id, p_team_number, …) call
-- shape (mig 062) but in USD on the v3 rail. The mig-133 triggers enforce currency
-- integrity, one-role-per-match, market-open, and real-money eligibility.
CREATE FUNCTION public.battle_place_spectator_bet_usd(
  p_match_id       UUID,
  p_team_number    SMALLINT,
  p_amount_dollars NUMERIC
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_mkt UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_team_number NOT IN (1, 2) THEN RAISE EXCEPTION 'team_number must be 1 or 2'; END IF;

  SELECT id INTO v_mkt FROM public.markets
  WHERE ccg_match_id = p_match_id AND currency = 'usd' AND status = 'open'
  LIMIT 1;
  IF v_mkt IS NULL THEN
    RAISE EXCEPTION 'Match is not monetized (no open real-money market — G-MON)';
  END IF;

  RETURN public.ccg_place_bet(v_mkt, 'team_' || p_team_number, p_amount_dollars);
END;
$$;

GRANT EXECUTE ON FUNCTION public.battle_place_spectator_bet_usd(UUID, SMALLINT, NUMERIC) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: loadout CHECK shape; non-KYC match stays non-monetized and the
-- bet RPC refuses it; monetized-bit read works.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_u UUID; v_match UUID; v_mkt UUID; v_err BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_u FROM auth.users WHERE email = 'cinematic-smoke@noraplatforms.com';
  IF v_u IS NULL THEN
    RAISE NOTICE 'M-P5 smoke SKIPPED (no smoke user)';
    RETURN;
  END IF;

  -- loadout: object OK, scalar rejected
  UPDATE public.profiles SET avatar_loadout = '{"Gender":"Male","SkinId":"skin_male_casual"}'
  WHERE id = v_u;
  BEGIN
    UPDATE public.profiles SET avatar_loadout = '"just-a-string"' WHERE id = v_u;
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: non-object loadout must be rejected'; END IF;
  UPDATE public.profiles SET avatar_loadout = NULL WHERE id = v_u;

  -- G-MON: smoke user is not KYC'd → no market, not monetized, bet RPC refuses
  v_match := public.ccg_create_match(v_u, NULL, NULL, NULL, TRUE);
  v_mkt := public.ccg_create_outcome_market(v_match);
  IF v_mkt IS NOT NULL THEN RAISE EXCEPTION 'SMOKE FAIL: non-KYC match must not get a USD market'; END IF;
  IF public.ccg_match_is_monetized(v_match) THEN RAISE EXCEPTION 'SMOKE FAIL: match must be non-monetized'; END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.battle_place_spectator_bet_usd(v_match, 1::SMALLINT, 5.00);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;   -- not authenticated AND not monetized
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: bet on non-monetized match must fail'; END IF;

  DELETE FROM public.ccg_matches WHERE id = v_match;
  RAISE NOTICE 'M-P5 smoke OK: loadout shape + G-MON non-monetized path + bet refusal';
END $$;
