-- Migration 162: delete a FINALIZED self-minted chit — the collection "Delete card".
--
-- chit_discard_pending (mig 150) covers the not-yet-finalized mint-preview case only;
-- a finalized card had NO owner-initiated exit short of swap-minting a replacement.
-- During launch testing the founder needs to delete a bad generation and re-mint the
-- SAME moment immediately, so this mirrors the discard flow for a finalized chit:
-- zero holdings (append-only ledger), soft-retire reason 'discarded' (ledger FKs
-- forbid hard DELETEs), purge decks, free the self_mint_slot, and RELEASE the source
-- moment via moment_release_on_retire (mig 158 — 'discarded' releases; the source
-- approval stands, so re-mint needs no fresh moderation pass).
--
-- Definition-level guards (a delete retires ALL copies of the definition):
--   * caller must be the moment owner (the minter) AND hold copies;
--   * NO other user may hold a copy (sold/wagered-away cards are theirs now);
--   * never while wager-escrowed or marketplace-listed (same walls as swap-retire).

CREATE OR REPLACE FUNCTION public.chit_delete_owned(p_user UUID, p_chit UUID)
RETURNS UUID   -- the moment_id, for battle-media cleanup by the caller
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_qty INTEGER; v_moment UUID; v_deck RECORD;
BEGIN
  -- The caller's own live self-minted chit (minter = moment owner), copies in hand.
  SELECT mc.moment_id INTO v_moment
  FROM public.moment_chits mc
  JOIN public.moments m ON m.id = mc.moment_id
  JOIN public.chit_ownership co ON co.chit_id = mc.id
  WHERE mc.id = p_chit
    AND m.owner_user_id = p_user
    AND co.user_id = p_user AND co.quantity > 0
    AND mc.character_class = 'consent_minted'
    AND mc.retired_at IS NULL
  LIMIT 1;
  IF v_moment IS NULL THEN
    RAISE EXCEPTION 'Chit % is not a deletable self-minted chit for this user', p_chit;
  END IF;

  -- Someone else holds a copy → the definition is no longer only yours to destroy.
  IF EXISTS (
    SELECT 1 FROM public.chit_ownership
    WHERE chit_id = p_chit AND user_id <> p_user AND quantity > 0
  ) THEN
    RAISE EXCEPTION 'Chit % has copies held by other users and cannot be deleted', p_chit;
  END IF;

  -- Never delete a chit that is mid-wager (mirror of chit_swap_retire, mig 142/155).
  IF EXISTS (SELECT 1 FROM public.ccg_wager_escrow
             WHERE chit_id = p_chit AND status = 'escrowed') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active wager match', p_chit;
  END IF;

  -- Never delete a chit that is listed for sale (marketplace escrow, mig 154/155).
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE chit_id = p_chit AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active marketplace listing', p_chit;
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

  -- Free the moment for a clean re-mint (mig 158: 'discarded' releases).
  PERFORM public.moment_release_on_retire(p_chit);

  RETURN v_moment;
END;
$$;

REVOKE ALL ON FUNCTION public.chit_delete_owned(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke (pattern: mig 150 — subtransaction force-rolled-back via a
-- sentinel, so no residue and no illegal ledger deletes): a FINALIZED chit is
-- deletable by its minter, the slot + moment are released; a foreign-held copy
-- blocks deletion.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID; v_other UUID; v_moment UUID; v_chit UUID; v_err BOOLEAN := FALSE;
  v_status TEXT; v_minted UUID;
BEGIN
  -- A user whose self-mint slot is FREE (mig 158 pattern) — a plain LIMIT 1 user may
  -- hold a real chit, and self_mint_slot would keep returning it after the smoke delete.
  SELECT u.id INTO v_user FROM auth.users u WHERE public.self_mint_slot(u.id) IS NULL LIMIT 1;
  SELECT id INTO v_other FROM auth.users WHERE id <> v_user ORDER BY created_at LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'chit-delete smoke SKIPPED (no free-slot auth user)';
    RETURN;
  END IF;

  BEGIN  -- subtransaction: everything below is rolled back at the end
    v_moment := public.moment_record(v_user, 'youtube', 'delete-smoke-' || gen_random_uuid()::TEXT,
                                     'https://example.com/post', NULL, 1000, TRUE, '@smoke', 'smoke title');
    v_chit := public.create_moment_chit('Delete Smoke','influencer','spell_moment','F','on_summon',
                NULL, 'consent_minted', v_moment, '{}'::TEXT[], NULL, NULL, NULL, 'smoke');
    UPDATE public.moment_chits SET finalized_at = NOW(), is_active = TRUE WHERE id = v_chit;
    UPDATE public.moments SET minted_chit_id = v_chit, mint_status = 'minted' WHERE id = v_moment;
    PERFORM public.chit_grant(v_user, v_chit, 1, 'mint', v_moment);

    -- A foreign-held copy blocks deletion.
    IF v_other IS NOT NULL THEN
      PERFORM public.chit_grant(v_other, v_chit, 1, 'mint', v_moment);
      BEGIN
        PERFORM public.chit_delete_owned(v_user, v_chit);
      EXCEPTION WHEN OTHERS THEN v_err := TRUE;
      END;
      IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: foreign-held copy must block delete'; END IF;
      -- Zero the foreign copy so the should-succeed path below is clean (the whole
      -- subtxn rolls back anyway; reason must be from the ledger CHECK vocabulary).
      PERFORM public.chit_grant(v_other, v_chit, -1, 'platform_correction', v_moment);
    END IF;

    -- Deletable by the minter: slot freed, moment released for re-mint.
    PERFORM public.chit_delete_owned(v_user, v_chit);
    IF public.self_mint_slot(v_user) IS NOT NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: slot should be free after delete';
    END IF;
    SELECT mint_status, minted_chit_id INTO v_status, v_minted FROM public.moments WHERE id = v_moment;
    IF v_minted IS NOT NULL OR v_status <> 'moderated' THEN
      RAISE EXCEPTION 'SMOKE FAIL: moment not released for re-mint (status=%, minted=%)', v_status, v_minted;
    END IF;
    IF (SELECT retired_reason FROM public.moment_chits WHERE id = v_chit) <> 'discarded' THEN
      RAISE EXCEPTION 'SMOKE FAIL: retired_reason not set to discarded';
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';  -- sentinel: unwind the subtxn, discarding all test rows
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'chit-delete smoke OK: finalized delete frees slot + releases moment; foreign copies guarded';
      ELSE
        RAISE;  -- a real assertion failure propagates and aborts the migration
      END IF;
  END;
END $$;
