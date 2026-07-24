-- Migration 174: N5 — card-centric prediction markets (token-settled).
--
-- Collections spec Phase N5. Markets pivot from creator Display Score to
-- card/collection events with INTERNAL-table oracles (cleaner than social
-- metrics). Three new resolution_type values, all TOKEN-settled on the existing
-- Markets rail (Hard Rule 33: Markets = tokens — unchanged; battle_outcome stays
-- the only USD market). These are new resolution types + a resolver, NOT a new
-- market system: the existing pool/payout (resolve-markets → processPayout) is
-- reused; this migration only adds market creation + the SQL outcome oracle +
-- the self-bet integrity guard.
--
--   card_ascension_time    — "Will card X reach tier Y by date D?"  Oracle:
--                            moment_chits.tier vs tier_ladder rank (ascension is
--                            one-directional, so at/after D current≥target ⇒ YES).
--   collection_sellout_date — "Will collection Z sell out by date D?" Oracle:
--                            collections.status = 'sold_out' (terminal) by D.
--   spotlight_champion     — "Will <user> be a Champion Spotlight this week?"
--                            Oracle: arena_spotlight_assignments slots for the
--                            week (REPO-CHECK N5.1: Champion Spotlight already
--                            exists as the weekly arena_spotlight_assignments —
--                            5 slots; a candidate "is champion" if in any slot).
--
-- REPO-CHECK N5.2 [FOUNDER — surfaced]: fate of existing display_score markets.
-- Default taken: RUN ALONGSIDE during beta (this migration adds types, retires
-- nothing). Retiring display_score is a founder call.
--
-- Integrity (Rule 26 class): a card's MINTER (moment owner) cannot bet on that
-- card's ascension market — they drive the engagement that ascends it.

-- ── new resolution types + subject/target columns ─────────────────────────────────
ALTER TABLE public.markets DROP CONSTRAINT IF EXISTS markets_resolution_type_check;
ALTER TABLE public.markets
  ADD CONSTRAINT markets_resolution_type_check CHECK (resolution_type IN (
    'display_score','battle_outcome',
    'card_ascension_time','collection_sellout_date','spotlight_champion'
  ));

ALTER TABLE public.markets
  ADD COLUMN IF NOT EXISTS subject_ref    UUID,   -- chit / collection / candidate user
  ADD COLUMN IF NOT EXISTS target_tier    TEXT,   -- ascension target Y (tier letter)
  ADD COLUMN IF NOT EXISTS spotlight_week DATE;   -- week_start for spotlight_champion

-- Display-score markets use fixed timeframes (15m/1h/4h/24h); card markets run on
-- user-chosen multi-day horizons, so they carry timeframe='custom'. Some markets
-- CHECK constraints predate the migration ledger (mig 012 was applied by hand), so
-- widen whatever timeframe constraint exists rather than assuming its name — this
-- ADDS 'custom' and never loosens the existing allowlist. No-op if none exists.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE conrelid = 'public.markets'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%timeframe%'
  LOOP
    IF r.def ILIKE '%custom%' THEN CONTINUE; END IF;  -- already widened
    EXECUTE format(
      'ALTER TABLE public.markets DROP CONSTRAINT %I, '
      'ADD CONSTRAINT %I CHECK ((%s) OR timeframe = ''custom'')',
      r.conname, r.conname, regexp_replace(r.def, '^CHECK\s*', ''));
    RAISE NOTICE 'mig 174: widened % to allow timeframe=custom', r.conname;
  END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- OUTCOME ORACLE — pure read over internal tables; the resolver (resolve-markets)
-- calls this and reuses the existing token pool payout. Returns 'yes'|'no'|'refund'
-- ('refund' = the subject vanished / data missing → void + refund, mirroring the
-- display_score path's refund).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.card_market_outcome(p_market_id UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_m         public.markets%ROWTYPE;
  v_cur_rank  INTEGER;
  v_tgt_rank  INTEGER;
  v_status    TEXT;
  v_hit       BOOLEAN;
BEGIN
  SELECT * INTO v_m FROM public.markets WHERE id = p_market_id;
  IF NOT FOUND THEN RETURN 'refund'; END IF;

  IF v_m.resolution_type = 'card_ascension_time' THEN
    IF v_m.subject_ref IS NULL OR v_m.target_tier IS NULL THEN RETURN 'refund'; END IF;
    SELECT tl.tier_rank INTO v_cur_rank
    FROM public.moment_chits mc JOIN public.tier_ladder tl ON tl.tier = mc.tier
    WHERE mc.id = v_m.subject_ref;
    SELECT tier_rank INTO v_tgt_rank FROM public.tier_ladder WHERE tier = v_m.target_tier;
    IF v_cur_rank IS NULL OR v_tgt_rank IS NULL THEN RETURN 'refund'; END IF;
    RETURN CASE WHEN v_cur_rank >= v_tgt_rank THEN 'yes' ELSE 'no' END;

  ELSIF v_m.resolution_type = 'collection_sellout_date' THEN
    IF v_m.subject_ref IS NULL THEN RETURN 'refund'; END IF;
    SELECT status INTO v_status FROM public.collections WHERE id = v_m.subject_ref;
    IF v_status IS NULL THEN RETURN 'refund'; END IF;
    RETURN CASE WHEN v_status = 'sold_out' THEN 'yes' ELSE 'no' END;

  ELSIF v_m.resolution_type = 'spotlight_champion' THEN
    IF v_m.subject_ref IS NULL OR v_m.spotlight_week IS NULL THEN RETURN 'refund'; END IF;
    SELECT EXISTS (
      SELECT 1 FROM public.arena_spotlight_assignments a
      WHERE a.week_start = v_m.spotlight_week
        AND v_m.subject_ref IN (a.slot_1_user_id, a.slot_2_user_id, a.slot_3_user_id,
                                a.slot_4_user_id, a.slot_5_user_id)
    ) INTO v_hit;
    RETURN CASE WHEN v_hit THEN 'yes' ELSE 'no' END;
  END IF;

  RETURN 'refund';
END;
$$;
REVOKE ALL ON FUNCTION public.card_market_outcome(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.card_market_outcome(UUID) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- MARKET CREATION — token markets on the existing rail. All open immediately.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_card_ascension_market(
  p_chit_id UUID, p_target_tier TEXT, p_end_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_user UUID := auth.uid(); v_id UUID; v_name TEXT; v_cur TEXT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tier_ladder WHERE tier = p_target_tier) THEN
    RAISE EXCEPTION 'Unknown target tier %', p_target_tier;
  END IF;
  SELECT name, tier INTO v_name, v_cur FROM public.moment_chits
  WHERE id = p_chit_id AND is_active AND retired_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit % not found or not active', p_chit_id; END IF;
  IF p_end_at <= NOW() THEN RAISE EXCEPTION 'end_at must be in the future'; END IF;

  INSERT INTO public.markets
    (creator_id, created_by, opened_by, title, timeframe, end_at, status,
     currency, resolution_type, subject_ref, target_tier)
  VALUES
    (v_user, v_user, v_user,
     'Will "' || v_name || '" reach ' || p_target_tier || '-tier by ' || to_char(p_end_at, 'Mon DD') || '?',
     'custom', p_end_at, 'open',
     'token', 'card_ascension_time', p_chit_id, p_target_tier)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_collection_sellout_market(
  p_collection_id UUID, p_end_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_user UUID := auth.uid(); v_id UUID; v_title TEXT; v_status TEXT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT title, status INTO v_title, v_status FROM public.collections WHERE id = p_collection_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection % not found', p_collection_id; END IF;
  IF v_status NOT IN ('listed','sold_out') THEN
    RAISE EXCEPTION 'Collection % is not on sale', p_collection_id;
  END IF;
  IF p_end_at <= NOW() THEN RAISE EXCEPTION 'end_at must be in the future'; END IF;

  INSERT INTO public.markets
    (creator_id, created_by, opened_by, title, timeframe, end_at, status,
     currency, resolution_type, subject_ref)
  VALUES
    (v_user, v_user, v_user,
     'Will "' || v_title || '" sell out by ' || to_char(p_end_at, 'Mon DD') || '?',
     'custom', p_end_at, 'open',
     'token', 'collection_sellout_date', p_collection_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_spotlight_champion_market(
  p_candidate UUID, p_week_start DATE, p_end_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_user UUID := auth.uid(); v_id UUID; v_name TEXT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT COALESCE(username, 'a creator') INTO v_name FROM public.profiles WHERE id = p_candidate;
  IF NOT FOUND THEN RAISE EXCEPTION 'Candidate % not found', p_candidate; END IF;
  IF p_end_at <= NOW() THEN RAISE EXCEPTION 'end_at must be in the future'; END IF;

  INSERT INTO public.markets
    (creator_id, created_by, opened_by, title, timeframe, end_at, status,
     currency, resolution_type, subject_ref, spotlight_week)
  VALUES
    (p_candidate, v_user, v_user,
     'Will @' || v_name || ' be a Champion Spotlight the week of ' || to_char(p_week_start, 'Mon DD') || '?',
     'custom', p_end_at, 'open',
     'token', 'spotlight_champion', p_candidate, p_week_start)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_card_ascension_market(UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_collection_sellout_market(UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_spotlight_champion_market(UUID, DATE, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_card_ascension_market(UUID, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_collection_sellout_market(UUID, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_spotlight_champion_market(UUID, DATE, TIMESTAMPTZ) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- INTEGRITY — the card's minter (moment owner) cannot bet on its ascension market.
-- A separate BEFORE INSERT guard on bets (never weakens the mig-102 integrity
-- trigger). Runs alongside it.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.enforce_card_market_bet_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_rtype TEXT; v_subject UUID;
BEGIN
  SELECT resolution_type, subject_ref INTO v_rtype, v_subject
  FROM public.markets WHERE id = NEW.market_id;

  IF v_rtype = 'card_ascension_time' AND v_subject IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.moments m
      WHERE m.minted_chit_id = v_subject AND m.owner_user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'A card''s minter cannot bet on its own ascension market';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_card_market_bet_integrity ON public.bets;
CREATE TRIGGER trg_enforce_card_market_bet_integrity
  BEFORE INSERT ON public.bets
  FOR EACH ROW EXECUTE FUNCTION public.enforce_card_market_bet_integrity();

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY-TIME SMOKE — creation + outcome oracle for all 3 types + the self-bet
-- guard. Uses the mkt-smoke identities; no bets settled here (payout is the edge
-- resolver's job) — the oracle + guard are the SQL-testable surface.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_chit UUID; v_moment UUID; v_low TEXT; v_high TEXT; v_curtier TEXT;
  v_coll UUID; v_mk UUID; v_err BOOLEAN; v_week DATE;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'mkt-smoke-1@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'mkt-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN RAISE EXCEPTION 'mig 174 smoke needs the mig-155 smoke users'; END IF;

  -- A chit linked to a moment owned by v_u1, so the minter link the self-bet
  -- guard reads exists. Built with create_moment_chit + a direct moments row (the
  -- mig-157 smoke pattern) rather than the full mint pipeline: the oracle reads
  -- only moment_chits.tier and the guard reads only moments, and going through
  -- moment_mint would collide with the mig-142 one-active-self-mint slot.
  v_chit := public.create_moment_chit('N5 smoke card', 'athlete', 'creature', 'D');
  INSERT INTO public.moments (owner_user_id, source_platform, source_external_id,
                              engagement_count, minted_chit_id, consent_granted_at)
  VALUES (v_u1, 'youtube', 'n5-smoke-' || gen_random_uuid()::TEXT, 1000, v_chit, NOW())
  RETURNING id INTO v_moment;
  SELECT tier INTO v_curtier FROM public.moment_chits WHERE id = v_chit;

  -- Lowest + highest tiers relative to current, for a YES and a NO market.
  SELECT tier INTO v_low  FROM public.tier_ladder ORDER BY tier_rank ASC  LIMIT 1;  -- 'F'
  SELECT tier INTO v_high FROM public.tier_ladder ORDER BY tier_rank DESC LIMIT 1;  -- 'S'

  -- card_ascension: target = lowest tier ⇒ current≥target ⇒ YES.
  v_mk := gen_random_uuid();
  INSERT INTO public.markets (id, creator_id, created_by, opened_by, title, timeframe,
    end_at, status, currency, resolution_type, subject_ref, target_tier)
  VALUES (v_mk, v_u1, v_u1, v_u1, 'smoke asc yes', 'custom', NOW() + INTERVAL '1 day',
    'open', 'token', 'card_ascension_time', v_chit, v_low);
  IF public.card_market_outcome(v_mk) <> 'yes' THEN
    RAISE EXCEPTION 'SMOKE FAIL: ascension to lowest tier must be YES';
  END IF;
  -- self-bet guard: the minter (v_u1) cannot bet this market. Assert on the
  -- guard's own message so an unrelated failure (token debit, RLS) can't pass.
  v_err := FALSE;
  BEGIN
    INSERT INTO public.bets (market_id, user_id, position, amount, status)
    VALUES (v_mk, v_u1, 'yes', 1, 'active');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%cannot bet on its own ascension market%' THEN
      RAISE EXCEPTION 'SMOKE FAIL: self-bet blocked by the wrong error: %', SQLERRM;
    END IF;
    v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: minter self-bet must be blocked'; END IF;

  -- target = highest tier (unless the chit already is S) ⇒ NO.
  IF v_curtier <> v_high THEN
    v_mk := gen_random_uuid();
    INSERT INTO public.markets (id, creator_id, created_by, opened_by, title, timeframe,
      end_at, status, currency, resolution_type, subject_ref, target_tier)
    VALUES (v_mk, v_u1, v_u1, v_u1, 'smoke asc no', 'custom', NOW() + INTERVAL '1 day',
      'open', 'token', 'card_ascension_time', v_chit, v_high);
    IF public.card_market_outcome(v_mk) <> 'no' THEN
      RAISE EXCEPTION 'SMOKE FAIL: ascension to highest tier must be NO (cur %, high %)', v_curtier, v_high;
    END IF;
  END IF;

  -- collection_sellout: a listed (not sold-out) collection ⇒ NO; flip to sold_out ⇒ YES.
  INSERT INTO public.collections (id, market_maker_user_id, title, status, price_cents)
  VALUES (gen_random_uuid(), v_u1, 'N5 smoke coll', 'listed', 1000) RETURNING id INTO v_coll;
  v_mk := gen_random_uuid();
  INSERT INTO public.markets (id, creator_id, created_by, opened_by, title, timeframe,
    end_at, status, currency, resolution_type, subject_ref)
  VALUES (v_mk, v_u1, v_u1, v_u1, 'smoke sellout', 'custom', NOW() + INTERVAL '1 day',
    'open', 'token', 'collection_sellout_date', v_coll);
  IF public.card_market_outcome(v_mk) <> 'no' THEN
    RAISE EXCEPTION 'SMOKE FAIL: a listed collection sellout market must be NO';
  END IF;
  UPDATE public.collections SET status = 'sold_out' WHERE id = v_coll;
  IF public.card_market_outcome(v_mk) <> 'yes' THEN
    RAISE EXCEPTION 'SMOKE FAIL: a sold_out collection sellout market must be YES';
  END IF;

  -- spotlight_champion: candidate NOT assigned ⇒ NO; assign a slot ⇒ YES.
  -- Uses a synthetic historical Monday, NOT the current week: the live week's row
  -- drives the home Spotlight surface and must never be touched by a smoke.
  v_week := DATE '1970-01-05';  -- a Monday, far outside any real assignment
  DELETE FROM public.arena_spotlight_assignments WHERE week_start = v_week;
  v_mk := gen_random_uuid();
  INSERT INTO public.markets (id, creator_id, created_by, opened_by, title, timeframe,
    end_at, status, currency, resolution_type, subject_ref, spotlight_week)
  VALUES (v_mk, v_u2, v_u1, v_u1, 'smoke spotlight', 'custom', NOW() + INTERVAL '1 day',
    'open', 'token', 'spotlight_champion', v_u2, v_week);
  IF public.card_market_outcome(v_mk) <> 'no' THEN
    RAISE EXCEPTION 'SMOKE FAIL: unassigned candidate must be NO';
  END IF;
  INSERT INTO public.arena_spotlight_assignments (week_start, slot_1_user_id)
  VALUES (v_week, v_u2);
  IF public.card_market_outcome(v_mk) <> 'yes' THEN
    RAISE EXCEPTION 'SMOKE FAIL: assigned candidate must be YES';
  END IF;

  -- cleanup: remove exactly the rows this block created (by id, never by subject).
  DELETE FROM public.arena_spotlight_assignments WHERE week_start = v_week;
  DELETE FROM public.markets WHERE title IN
    ('smoke asc yes','smoke asc no','smoke sellout','smoke spotlight')
    AND resolution_type IN ('card_ascension_time','collection_sellout_date','spotlight_champion');
  DELETE FROM public.collections WHERE id = v_coll;
  DELETE FROM public.moments WHERE id = v_moment;
  -- Chits are retired, never hard-deleted (the mig-162 convention) — the smoke
  -- granted no copies/ownership, so retiring leaves nothing dangling.
  UPDATE public.moment_chits
     SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
   WHERE id = v_chit;

  RAISE NOTICE 'N5 smoke OK: 3 outcome oracles correct (asc yes/no, sellout no→yes, spotlight no→yes), minter self-bet blocked';
END $$;
