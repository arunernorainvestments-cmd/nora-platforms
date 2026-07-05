-- Migration 150: discard a pending (un-finalized) self-minted chit — the mint "Cancel".
--
-- The mint wizard's Preview step (Hard Rule 39: the user must preview before a chit
-- finalizes) had no way to back out: the chit already exists (created at generation,
-- is_active=FALSE until chit_finalize_preview) and it OCCUPIES the one self_mint_slot
-- (self_mint_slot counts any held, non-retired copy — mig 142). So "just navigate away"
-- would strand a pending card that blocks the next mint behind the swap-confirm flow.
--
-- chit_discard_pending retires that pending chit cleanly (mirrors chit_swap_retire, but
-- standalone — no replacement mint): zero holdings via the append-only ledger, soft-
-- retire (ledger FKs forbid a hard DELETE), purge any decks. Returns the moment_id so
-- the caller (mint-cancel edge fn) can delete the chit's battle-media. A FINALIZED chit
-- can never be discarded here — that is a real owned collectible, not a pending preview.

-- Allow the new retirement reason.
ALTER TABLE public.moment_chits DROP CONSTRAINT IF EXISTS moment_chits_retired_reason_check;
ALTER TABLE public.moment_chits
  ADD CONSTRAINT moment_chits_retired_reason_check
  CHECK (retired_reason IN ('swap','moderation','admin','discarded'));

CREATE OR REPLACE FUNCTION public.chit_discard_pending(p_user UUID, p_chit UUID)
RETURNS UUID   -- the moment_id, for battle-media cleanup by the caller
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_moment UUID; v_deck RECORD;
BEGIN
  -- Only a not-yet-finalized, non-retired, consent-minted chit the caller holds.
  SELECT mc.moment_id INTO v_moment
  FROM public.moment_chits mc
  JOIN public.chit_ownership co ON co.chit_id = mc.id
  WHERE mc.id = p_chit
    AND co.user_id = p_user AND co.quantity > 0
    AND mc.character_class = 'consent_minted'
    AND mc.finalized_at IS NULL
    AND mc.retired_at IS NULL
  LIMIT 1;
  IF v_moment IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a discardable pending chit for this user', p_chit;
  END IF;

  -- Dispose remaining holdings (append-only ledger, negative delta).
  SELECT quantity INTO v_qty FROM public.chit_ownership WHERE user_id = p_user AND chit_id = p_chit;
  IF COALESCE(v_qty, 0) > 0 THEN
    PERFORM public.chit_grant(p_user, p_chit, -v_qty, 'swap_retired', v_moment);
  END IF;

  UPDATE public.moment_chits
  SET is_active = FALSE, retired_at = NOW(), retired_reason = 'discarded'
  WHERE id = p_chit;

  -- Pull it from every deck that contains it; those decks are no longer legal.
  FOR v_deck IN
    DELETE FROM public.deck_chits WHERE chit_id = p_chit RETURNING deck_id
  LOOP
    UPDATE public.decks SET is_legal = FALSE, validated_at = NOW(), updated_at = NOW()
    WHERE id = v_deck.deck_id;
  END LOOP;

  RETURN v_moment;
END;
$$;

REVOKE ALL ON FUNCTION public.chit_discard_pending(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: a pending chit occupies the slot + is discardable + frees it; a
-- finalized chit is NOT discardable. The whole test runs inside a subtransaction that
-- is force-rolled-back via a sentinel exception, so it leaves NO residue and never has
-- to (illegally) DELETE append-only ledger rows.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID; v_moment UUID; v_chit UUID; v_slot UUID; v_err BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_user FROM auth.users LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'chit-discard smoke SKIPPED (no auth user)';
    RETURN;
  END IF;

  BEGIN  -- subtransaction: everything below is rolled back at the end
    v_moment := public.moment_record(v_user, 'youtube', 'discard-smoke-' || gen_random_uuid()::TEXT,
                                     'https://example.com/post', NULL, 1000, TRUE, '@smoke');
    v_chit := public.create_moment_chit('Discard Smoke','influencer','spell_moment','F','on_summon',
                NULL, 'consent_minted', v_moment, '{}'::TEXT[], NULL, NULL, NULL, 'smoke');
    UPDATE public.moment_chits SET is_active = FALSE WHERE id = v_chit;  -- pending
    PERFORM public.chit_grant(v_user, v_chit, 1, 'mint', v_moment);

    -- Occupies the slot.
    v_slot := public.self_mint_slot(v_user);
    IF v_slot IS DISTINCT FROM v_chit THEN
      RAISE EXCEPTION 'SMOKE FAIL: pending chit should occupy the self_mint_slot (got %)', v_slot;
    END IF;

    -- A finalized chit cannot be discarded.
    UPDATE public.moment_chits SET finalized_at = NOW() WHERE id = v_chit;
    BEGIN
      PERFORM public.chit_discard_pending(v_user, v_chit);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE;
    END;
    IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: finalized chit must not be discardable'; END IF;

    -- Un-finalize → discard succeeds → slot freed, reason recorded.
    UPDATE public.moment_chits SET finalized_at = NULL WHERE id = v_chit;
    PERFORM public.chit_discard_pending(v_user, v_chit);
    IF public.self_mint_slot(v_user) IS NOT NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: slot should be free after discard';
    END IF;
    IF (SELECT retired_reason FROM public.moment_chits WHERE id = v_chit) <> 'discarded' THEN
      RAISE EXCEPTION 'SMOKE FAIL: retired_reason not set to discarded';
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';  -- sentinel: unwind the subtxn, discarding all test rows
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'chit-discard smoke OK: occupies slot, finalized-guarded, frees slot on discard';
      ELSE
        RAISE;  -- a real assertion failure propagates and aborts the migration
      END IF;
  END;
END $$;
