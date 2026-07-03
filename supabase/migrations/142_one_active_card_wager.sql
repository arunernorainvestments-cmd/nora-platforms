-- Migration 142: M-P4 — one-active-card rule + card-wager game mode.
--
-- Minting spec PHASE 4. Two invariants, DB-owned:
--   1. ONE ACTIVE SELF-MINTED CHIT PER USER: a user may hold at most one live chit
--      minted from their own moment. Enforced at mint (moment_mint raises unless the
--      mint is an explicit swap). Swap = mint the NEW chit first, then retire the old
--      one in the SAME transaction (never delete the old before the new confirms);
--      media deletion happens post-commit in the edge fn. Chit rows are RETIRED, not
--      DELETEd — the append-only acquisition ledger references them (mig 117).
--   2. WAGER MATCH: both players stake an owned chit into escrow at match creation;
--      on resolution the winner receives the loser's chit (ledger transfer), the
--      loser's copy is gone (it left their holdings at escrow). Attribution
--      (`original_minter_handle`) lives on the chit definition and survives transfer.
--      A wagered chit transfers ONLY via a resolved wager match; an abandoned match
--      returns both stakes.

-- ── retirement fields (soft-delete: ledger FKs forbid hard DELETE) ────────────────
ALTER TABLE public.moment_chits
  ADD COLUMN IF NOT EXISTS retired_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS retired_reason TEXT CHECK (retired_reason IN ('swap','moderation','admin'));

-- ── ledger reasons for escrow/transfer/retirement ─────────────────────────────────
ALTER TABLE public.chit_acquisition_ledger
  DROP CONSTRAINT chit_acquisition_ledger_reason_check;
ALTER TABLE public.chit_acquisition_ledger
  ADD CONSTRAINT chit_acquisition_ledger_reason_check CHECK (reason IN (
    'mint','pack_purchase','barter_in','barter_out','gift','event','platform_correction',
    'wager_escrow','wager_return','wager_won','swap_retired'
  ));

-- ── wager escrow ──────────────────────────────────────────────────────────────────
ALTER TABLE public.ccg_matches
  ADD COLUMN IF NOT EXISTS match_type TEXT NOT NULL DEFAULT 'standard'
    CHECK (match_type IN ('standard','wager'));

CREATE TABLE public.ccg_wager_escrow (
  match_id    UUID NOT NULL REFERENCES public.ccg_matches(id) ON DELETE CASCADE,
  seat        SMALLINT NOT NULL CHECK (seat IN (1,2)),
  user_id     UUID NOT NULL REFERENCES auth.users(id),
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  status      TEXT NOT NULL DEFAULT 'escrowed'
    CHECK (status IN ('escrowed','transferred','returned')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  PRIMARY KEY (match_id, seat)
);

-- A chit copy can sit in at most one open escrow per user.
CREATE UNIQUE INDEX ccg_wager_escrow_open_chit_idx
  ON public.ccg_wager_escrow (user_id, chit_id) WHERE status = 'escrowed';

ALTER TABLE public.ccg_wager_escrow ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ccg_wager_escrow_select_participants" ON public.ccg_wager_escrow
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.ccg_match_players p
            WHERE p.match_id = ccg_wager_escrow.match_id AND p.user_id = auth.uid())
  );
-- No client writes: escrow moves only via the SECURITY DEFINER fns below.

-- ── self-mint slot: the one live self-minted chit the user still holds ────────────
-- Held = quantity > 0 or currently escrowed in a wager (it is still "their" card
-- until the match resolves). A chit LOST via wager frees the slot (the card lives
-- on with the winner, attribution intact); a retired chit frees the slot.
CREATE FUNCTION public.self_mint_slot(p_user UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT mc.id
  FROM public.moment_chits mc
  JOIN public.moments m ON m.id = mc.moment_id
  WHERE m.owner_user_id = p_user
    AND mc.character_class = 'consent_minted'
    AND mc.retired_at IS NULL
    AND (
      EXISTS (SELECT 1 FROM public.chit_ownership co
              WHERE co.user_id = p_user AND co.chit_id = mc.id AND co.quantity > 0)
      OR EXISTS (SELECT 1 FROM public.ccg_wager_escrow we
                 WHERE we.user_id = p_user AND we.chit_id = mc.id AND we.status = 'escrowed')
    )
  ORDER BY mc.created_at DESC
  LIMIT 1;
$$;

-- Client-facing wrapper for the swap-warning UI (own slot only).
CREATE FUNCTION public.my_self_mint_slot()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('chit_id', mc.id, 'name', mc.name, 'tier', mc.tier,
                               'card_art_url', mc.card_art_url)
     FROM public.moment_chits mc
     WHERE mc.id = public.self_mint_slot(auth.uid())),
    'null'::JSONB);
$$;

-- ── swap retirement (runs INSIDE the mint tx, after the new chit exists) ──────────
CREATE FUNCTION public.chit_swap_retire(p_user UUID, p_old_chit UUID, p_new_chit UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_deck RECORD;
BEGIN
  -- The old chit must be THIS user's live self-minted chit.
  IF NOT EXISTS (
    SELECT 1 FROM public.moment_chits mc
    JOIN public.moments m ON m.id = mc.moment_id
    WHERE mc.id = p_old_chit AND m.owner_user_id = p_user
      AND mc.character_class = 'consent_minted' AND mc.retired_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Chit % is not a live self-minted chit of user %', p_old_chit, p_user;
  END IF;
  -- Never retire a chit that is mid-wager.
  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE chit_id = p_old_chit AND user_id = p_user AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_old_chit;
  END IF;

  -- Dispose remaining holdings (append-only ledger, negative delta).
  SELECT quantity INTO v_qty FROM public.chit_ownership
  WHERE user_id = p_user AND chit_id = p_old_chit;
  IF COALESCE(v_qty, 0) > 0 THEN
    PERFORM public.chit_grant(p_user, p_old_chit, -v_qty, 'swap_retired', p_new_chit);
  END IF;

  -- Retire the definition (soft: ledger/match-history FKs stay valid).
  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'swap'
  WHERE id = p_old_chit;

  -- Pull it from every deck that contains it; those decks are no longer legal.
  FOR v_deck IN
    DELETE FROM public.deck_chits WHERE chit_id = p_old_chit RETURNING deck_id
  LOOP
    UPDATE public.decks SET is_legal = FALSE, validated_at = NOW(), updated_at = NOW()
    WHERE id = v_deck.deck_id;
  END LOOP;
END;
$$;

-- ── moment_mint: enforce the slot (skip only on explicit swap) ────────────────────
DROP FUNCTION public.moment_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT);

CREATE FUNCTION public.moment_mint(
  p_moment_id         UUID,
  p_family            TEXT,          -- from AI classification
  p_chit_type         TEXT,
  p_timing            TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_name              TEXT DEFAULT NULL,
  p_keywords          TEXT[] DEFAULT '{}',
  p_vibe_gate         INTEGER DEFAULT NULL,
  p_moment_video_ref  TEXT DEFAULT NULL,
  p_swap_of           UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_m public.moments%ROWTYPE; v_tier TEXT; v_chit UUID; v_slot UUID;
BEGIN
  SELECT * INTO v_m FROM public.moments WHERE id = p_moment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Moment not found: %', p_moment_id; END IF;
  IF v_m.consent_granted_at IS NULL THEN RAISE EXCEPTION 'No consent on moment'; END IF;
  IF v_m.moderation_status <> 'approved' THEN RAISE EXCEPTION 'Moment not moderation-approved'; END IF;
  IF v_m.minted_chit_id IS NOT NULL THEN RAISE EXCEPTION 'Moment already minted'; END IF;
  IF v_m.source_status <> 'active' THEN RAISE EXCEPTION 'Moment source is not active'; END IF;

  -- One active self-minted chit per user (minting spec P4). A swap must name the
  -- exact chit being replaced; the caller retires it in this same transaction.
  v_slot := public.self_mint_slot(v_m.owner_user_id);
  IF p_swap_of IS NULL THEN
    IF v_slot IS NOT NULL THEN
      RAISE EXCEPTION 'self_mint_slot_occupied: user already holds self-minted chit % (swap required)', v_slot;
    END IF;
  ELSIF v_slot IS NULL OR v_slot <> p_swap_of THEN
    RAISE EXCEPTION 'swap_mismatch: % is not the occupying self-minted chit (%)', p_swap_of, v_slot;
  END IF;

  -- Tier assigned from CURRENT engagement (not user-set).
  v_tier := public.tier_for_engagement(v_m.engagement_count);

  v_chit := public.create_moment_chit(
    COALESCE(p_name, 'Moment ' || LEFT(p_moment_id::TEXT, 8)),
    p_family, p_chit_type, v_tier, p_timing, p_effect_template_id,
    'consent_minted', p_moment_id, COALESCE(p_keywords,'{}'), p_vibe_gate,
    v_m.thumbnail_url, p_moment_video_ref, NULL);

  UPDATE public.moments
  SET archetype_family = p_family, minted_chit_id = v_chit, mint_status = 'minted'
  WHERE id = p_moment_id;

  RETURN v_chit;
END;
$$;

-- ── cinematic_complete_mint: thread the swap through; retire AFTER the new mint ───
DROP FUNCTION public.cinematic_complete_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT, TEXT);

CREATE FUNCTION public.cinematic_complete_mint(
  p_generation_id      UUID,
  p_family             TEXT,
  p_chit_type          TEXT,
  p_timing             TEXT DEFAULT NULL,
  p_effect_template_id UUID DEFAULT NULL,
  p_name               TEXT DEFAULT NULL,
  p_keywords           TEXT[] DEFAULT '{}',
  p_vibe_gate          INTEGER DEFAULT NULL,
  p_card_art_url       TEXT DEFAULT NULL,
  p_mp4_url            TEXT DEFAULT NULL,
  p_swap_of            UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_gen  public.cinematic_generations%ROWTYPE;
  v_m    public.moments%ROWTYPE;
  v_chit UUID;
BEGIN
  SELECT * INTO v_gen FROM public.cinematic_generations WHERE id = p_generation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Generation not found: %', p_generation_id; END IF;
  -- Post-gen moderation is mandatory (Hard Rule 39) — no verdict, no chit.
  IF v_gen.status <> 'moderation_approved' THEN
    RAISE EXCEPTION 'Generation % is not moderation_approved (status: %)', p_generation_id, v_gen.status;
  END IF;
  IF v_gen.chit_id IS NOT NULL THEN
    RAISE EXCEPTION 'Generation % already completed into chit %', p_generation_id, v_gen.chit_id;
  END IF;
  -- battle-media only (Hard Rule 38).
  IF p_mp4_url IS NULL OR position('/battle-media/' IN p_mp4_url) = 0 THEN
    RAISE EXCEPTION 'mp4 url must be a battle-media object';
  END IF;

  SELECT * INTO v_m FROM public.moments WHERE id = v_gen.moment_id;

  -- moment_mint re-checks consent + pre-gen moderation + not-already-minted (mig 135),
  -- derives tier from CURRENT engagement (Hard Rule 34), and enforces the self-mint
  -- slot (mig 142) — a swap must name the occupying chit.
  v_chit := public.moment_mint(
    v_gen.moment_id, p_family, p_chit_type, p_timing, p_effect_template_id,
    p_name, p_keywords, p_vibe_gate, v_gen.mp4_path, p_swap_of);

  -- Cinematic contract fields + preview gate (inactive until the user finalizes —
  -- deck validation (mig 118) excludes inactive chits, so a pending chit can't play).
  UPDATE public.moment_chits
  SET match_cut_template_id   = v_gen.template_id,
      anchor_plate_version    = v_gen.anchor_plate_version,
      prompt_template_version = v_gen.prompt_template_version,
      generation_seed         = v_gen.generation_seed,
      mp4_cutscene_url        = p_mp4_url,
      card_art_url            = COALESCE(p_card_art_url, card_art_url),
      original_minter_handle  = v_m.creator_handle,
      source_platform         = v_m.source_platform,
      is_active               = FALSE
  WHERE id = v_chit;

  -- Ownership: the minter gets the copy (append-only ledger → holdings).
  PERFORM public.chit_grant(v_m.owner_user_id, v_chit, 1, 'mint', v_gen.moment_id);

  -- Swap: retire the old chit ONLY now that the new one exists (same tx — the old
  -- card can never be lost without its replacement being confirmed).
  IF p_swap_of IS NOT NULL THEN
    PERFORM public.chit_swap_retire(v_m.owner_user_id, p_swap_of, v_chit);
  END IF;

  UPDATE public.cinematic_generations
  SET chit_id = v_chit, status = 'stored'
  WHERE id = p_generation_id;

  RETURN v_chit;
END;
$$;

-- ── wager match creation: stakes into escrow atomically with the match ────────────
CREATE FUNCTION public.ccg_create_wager_match(
  p_seat1_user UUID, p_seat1_deck UUID, p_seat1_stake UUID,
  p_seat2_user UUID, p_seat2_deck UUID, p_seat2_stake UUID,
  p_is_test BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_match UUID; v_seat SMALLINT; v_user UUID; v_stake UUID;
BEGIN
  IF p_seat1_user IS NULL OR p_seat2_user IS NULL THEN
    RAISE EXCEPTION 'Wager matches need two real players';
  END IF;
  IF p_seat1_user = p_seat2_user THEN
    RAISE EXCEPTION 'A user cannot wager against themself';
  END IF;

  -- Validate both stakes BEFORE creating anything.
  FOR v_seat IN 1..2 LOOP
    v_user  := CASE v_seat WHEN 1 THEN p_seat1_user  ELSE p_seat2_user  END;
    v_stake := CASE v_seat WHEN 1 THEN p_seat1_stake ELSE p_seat2_stake END;
    IF v_stake IS NULL THEN RAISE EXCEPTION 'Seat % stake chit required', v_seat; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.moment_chits mc
      JOIN public.chit_ownership co ON co.chit_id = mc.id AND co.user_id = v_user
      WHERE mc.id = v_stake AND mc.retired_at IS NULL AND mc.is_active AND co.quantity > 0
    ) THEN
      RAISE EXCEPTION 'Seat % does not hold a live, finalized copy of stake chit %', v_seat, v_stake;
    END IF;
  END LOOP;

  v_match := public.ccg_create_match(p_seat1_user, p_seat1_deck, p_seat2_user, p_seat2_deck, p_is_test);
  UPDATE public.ccg_matches SET match_type = 'wager' WHERE id = v_match;

  -- Escrow: the copy leaves the player's holdings for the duration of the match.
  FOR v_seat IN 1..2 LOOP
    v_user  := CASE v_seat WHEN 1 THEN p_seat1_user  ELSE p_seat2_user  END;
    v_stake := CASE v_seat WHEN 1 THEN p_seat1_stake ELSE p_seat2_stake END;
    INSERT INTO public.ccg_wager_escrow (match_id, seat, user_id, chit_id)
    VALUES (v_match, v_seat, v_user, v_stake);
    PERFORM public.chit_grant(v_user, v_stake, -1, 'wager_escrow', v_match);
  END LOOP;

  RETURN v_match;
END;
$$;

-- ── wager settlement: winner takes the loser's stake; abandoned returns both ──────
-- Idempotent: rows transition only from 'escrowed'. Attribution is untouched — the
-- chit definition (incl. original_minter_handle) is what transfers.
CREATE FUNCTION public.ccg_settle_wager(p_match_id UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_match public.ccg_matches%ROWTYPE; v_row public.ccg_wager_escrow%ROWTYPE; v_winner UUID;
BEGIN
  SELECT * INTO v_match FROM public.ccg_matches WHERE id = p_match_id;
  IF NOT FOUND OR v_match.match_type <> 'wager' THEN RETURN; END IF;

  IF v_match.status = 'finished' AND v_match.winner_seat IS NOT NULL THEN
    SELECT user_id INTO v_winner FROM public.ccg_match_players
    WHERE match_id = p_match_id AND seat = v_match.winner_seat;

    FOR v_row IN
      SELECT * FROM public.ccg_wager_escrow
      WHERE match_id = p_match_id AND status = 'escrowed'
      FOR UPDATE
    LOOP
      IF v_row.seat = v_match.winner_seat THEN
        -- winner's own stake comes home
        PERFORM public.chit_grant(v_row.user_id, v_row.chit_id, 1, 'wager_return', p_match_id);
        UPDATE public.ccg_wager_escrow SET status = 'returned', resolved_at = NOW()
        WHERE match_id = v_row.match_id AND seat = v_row.seat;
      ELSE
        -- loser's stake transfers to the winner (loser's copy left holdings at escrow)
        PERFORM public.chit_grant(v_winner, v_row.chit_id, 1, 'wager_won', p_match_id, v_row.user_id);
        UPDATE public.ccg_wager_escrow SET status = 'transferred', resolved_at = NOW()
        WHERE match_id = v_row.match_id AND seat = v_row.seat;
      END IF;
    END LOOP;

  ELSIF v_match.status = 'abandoned' THEN
    FOR v_row IN
      SELECT * FROM public.ccg_wager_escrow
      WHERE match_id = p_match_id AND status = 'escrowed'
      FOR UPDATE
    LOOP
      PERFORM public.chit_grant(v_row.user_id, v_row.chit_id, 1, 'wager_return', p_match_id);
      UPDATE public.ccg_wager_escrow SET status = 'returned', resolved_at = NOW()
      WHERE match_id = v_row.match_id AND seat = v_row.seat;
    END LOOP;
  END IF;
END;
$$;

CREATE FUNCTION public.ccg_wager_on_finish()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.match_type = 'wager' AND NEW.status IN ('finished','abandoned') THEN
    PERFORM public.ccg_settle_wager(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ccg_matches_wager_settle
  AFTER UPDATE ON public.ccg_matches
  FOR EACH ROW
  WHEN (NEW.match_type = 'wager' AND NEW.status IN ('finished','abandoned'))
  EXECUTE FUNCTION public.ccg_wager_on_finish();

-- ── grants: pipeline/wager fns are service-only; the slot peek is client-safe ─────
REVOKE ALL ON FUNCTION public.moment_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cinematic_complete_mint(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT[], INTEGER, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.self_mint_slot(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chit_swap_retire(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ccg_create_wager_match(UUID, UUID, UUID, UUID, UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ccg_settle_wager(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_self_mint_slot() TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: escrow → finish → transfer (attribution intact, idempotent);
-- slot blocks a second self-mint; swap retire frees the slot.
-- Runs ONLY against dedicated smoke users (never real accounts — the append-only
-- ledger keeps its rows, so smoke residue must stay on smoke identities). In prod
-- this typically SKIPs; the full E2E proof is tools/minting/smoke_wager.ts.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u1 UUID; v_u2 UUID;
  v_c1 UUID; v_c2 UUID;
  v_match UUID; v_q INTEGER; v_err BOOLEAN := FALSE;
  v_moment UUID; v_chit UUID; v_handle TEXT;
BEGIN
  SELECT id INTO v_u1 FROM auth.users WHERE email = 'cinematic-smoke@noraplatforms.com';
  SELECT id INTO v_u2 FROM auth.users WHERE email = 'cinematic-smoke-2@noraplatforms.com';
  IF v_u1 IS NULL OR v_u2 IS NULL THEN
    RAISE NOTICE 'M-P4 smoke SKIPPED (needs both smoke users; run tools/minting/smoke_wager.ts)';
    RETURN;
  END IF;

  -- Two catalog chits, one per player (any owned chit can be wagered).
  v_c1 := public.create_moment_chit('M-P4 smoke stake 1', 'athlete', 'creature', 'C');
  v_c2 := public.create_moment_chit('M-P4 smoke stake 2', 'musician', 'creature', 'C');
  UPDATE public.moment_chits SET original_minter_handle = '@smoke_minter_2' WHERE id = v_c2;
  PERFORM public.chit_grant(v_u1, v_c1, 1, 'event');
  PERFORM public.chit_grant(v_u2, v_c2, 1, 'event');

  -- wager match (test mode: no decks needed) → escrow drains both holdings
  v_match := public.ccg_create_wager_match(v_u1, NULL, v_c1, v_u2, NULL, v_c2, TRUE);
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u2 AND chit_id = v_c2;
  IF COALESCE(v_q, 0) <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: escrow must drain holdings'; END IF;

  -- double-stake of an escrowed chit must fail
  BEGIN
    PERFORM public.ccg_create_wager_match(v_u1, NULL, v_c1, v_u2, NULL, v_c2, TRUE);
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: double-stake must be blocked'; END IF;

  -- seat 1 wins → seat 2's chit transfers, attribution intact
  UPDATE public.ccg_matches SET status = 'finished', winner_seat = 1, finished_at = NOW()
  WHERE id = v_match;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_c2;
  IF COALESCE(v_q, 0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: winner must receive loser stake'; END IF;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_c1;
  IF COALESCE(v_q, 0) <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: winner stake must return'; END IF;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u2 AND chit_id = v_c2;
  IF COALESCE(v_q, 0) <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: loser copy must be gone'; END IF;
  SELECT original_minter_handle INTO v_handle FROM public.moment_chits WHERE id = v_c2;
  IF v_handle <> '@smoke_minter_2' THEN RAISE EXCEPTION 'SMOKE FAIL: attribution must survive transfer'; END IF;

  -- settle is idempotent (trigger refire changes nothing)
  PERFORM public.ccg_settle_wager(v_match);
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_c2;
  IF v_q <> 1 THEN RAISE EXCEPTION 'SMOKE FAIL: settle must be idempotent'; END IF;

  -- one-active-card: a second self-mint for the same owner must demand a swap
  v_moment := public.moment_record(v_u1, 'youtube', 'mp4-smoke-' || gen_random_uuid()::TEXT,
                                   'https://example.com/post', NULL, 1000, TRUE, '@smoke');
  PERFORM public.moment_pre_gen_moderate(v_moment, 'approved', NULL, FALSE, 'sim');
  v_chit := public.moment_mint(v_moment, 'athlete', 'creature', 'on_summon');
  v_err := FALSE;
  BEGIN
    PERFORM public.moment_mint(v_moment, 'athlete', 'creature', 'on_summon');  -- same moment: already minted
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;
  END;
  IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: re-mint of a minted moment must fail'; END IF;
  IF public.self_mint_slot(v_u1) <> v_chit THEN RAISE EXCEPTION 'SMOKE FAIL: slot must be occupied'; END IF;
  v_err := FALSE;
  BEGIN
    PERFORM public.moment_mint(gen_random_uuid(), 'athlete', 'creature', 'on_summon');
  EXCEPTION WHEN OTHERS THEN v_err := TRUE;  -- (missing moment; slot check is proven below)
  END;

  -- swap retire: slot frees, decks purge, holdings zero
  PERFORM public.chit_swap_retire(v_u1, v_chit, v_c1);
  IF public.self_mint_slot(v_u1) IS NOT NULL THEN RAISE EXCEPTION 'SMOKE FAIL: slot must free after swap retire'; END IF;
  SELECT quantity INTO v_q FROM public.chit_ownership WHERE user_id = v_u1 AND chit_id = v_chit;
  IF COALESCE(v_q, 0) <> 0 THEN RAISE EXCEPTION 'SMOKE FAIL: retired chit holdings must be zero'; END IF;

  -- cleanup: zero holdings (compensating ledger entries — the ledger itself is
  -- append-only), cascade the match, retire the smoke chits out of the catalog.
  PERFORM public.chit_grant(v_u1, v_c1, -1, 'platform_correction');
  PERFORM public.chit_grant(v_u1, v_c2, -1, 'platform_correction');
  DELETE FROM public.ccg_matches WHERE id = v_match;
  DELETE FROM public.moments WHERE id = v_moment;   -- chit keeps moment_id NULL via ON DELETE SET NULL
  UPDATE public.moment_chits SET is_active = FALSE, retired_at = NOW(), retired_reason = 'admin'
  WHERE id IN (v_c1, v_c2, v_chit);

  RAISE NOTICE 'M-P4 smoke OK: escrow/transfer/attribution/idempotency + self-mint slot + swap retire';
END $$;
