-- Migration 158: release the source moment when its chit is retired + post_title signal.
--
-- BUG (2026-07-12, "Moment already minted"): chit_discard_pending (mig 150) and
-- chit_swap_retire (mig 142/155) retire the chit and free the self_mint_slot, but never
-- clear moments.minted_chit_id. Re-ingesting the same post then upserts the SAME moments
-- row and moment_pre_gen_moderate resets mint_status 'minted'→'moderated' (mig 141), so
-- the wizard sails past clip-attach + classify (both check mint_status) and only dies at
-- generate on the minted_chit_id check — permanently. The discard dialog promises "your
-- original moment stays linked, so you can mint it again"; this migration makes that true.
--
-- Rule: retiring a chit for reasons 'swap' or 'discarded' RELEASES its source moment
-- (minted_chit_id NULL, mint_status 'minted'→'moderated'; moderation_status untouched —
-- the source approval stands). 'moderation' and 'admin' retirements do NOT release: a
-- content-pulled chit must never silently free its moment for a re-mint.
--
-- Also: persist the post title (moments.post_title) at ingest — moment-classify's family
-- decision previously only saw handle + URL; the title is the real text signal.

-- ── post_title: classification signal captured at ingest ──────────────────────────
ALTER TABLE public.moments
  ADD COLUMN IF NOT EXISTS post_title TEXT;

COMMENT ON COLUMN public.moments.post_title IS
  'Source post title/caption captured at ingest (official API / oEmbed). Text signal '
  'for moment-classify family detection; never user-editable after ingest.';

-- moment_record: + p_title (drop first — a defaulted param would create an ambiguous
-- overload; same pattern as mig 141).
DROP FUNCTION IF EXISTS public.moment_record(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN, TEXT);

CREATE FUNCTION public.moment_record(
  p_owner UUID, p_platform TEXT, p_external_id TEXT, p_url TEXT,
  p_thumbnail TEXT, p_engagement BIGINT, p_consent BOOLEAN DEFAULT TRUE,
  p_handle TEXT DEFAULT NULL, p_title TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id UUID;
BEGIN
  -- Hard Rule 37 source allowlist. X/Facebook deferred; no raw upload path exists.
  IF p_platform NOT IN ('tiktok','instagram','youtube') THEN
    RAISE EXCEPTION 'Source platform not allowlisted for minting: %', p_platform;
  END IF;

  INSERT INTO public.moments
    (owner_user_id, source_platform, source_external_id, source_url, thumbnail_url,
     engagement_count, engagement_synced_at, consent_granted_at, creator_handle, post_title)
  VALUES (p_owner, p_platform, p_external_id, p_url, p_thumbnail,
     GREATEST(COALESCE(p_engagement,0),0), NOW(),
     CASE WHEN p_consent THEN NOW() ELSE NULL END, p_handle, LEFT(p_title, 300))
  ON CONFLICT (source_platform, source_external_id) DO UPDATE
    SET engagement_count = GREATEST(EXCLUDED.engagement_count, 0),
        engagement_synced_at = NOW(),
        thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, public.moments.thumbnail_url),
        creator_handle = COALESCE(EXCLUDED.creator_handle, public.moments.creator_handle),
        post_title = COALESCE(EXCLUDED.post_title, public.moments.post_title)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.moment_record(UUID, TEXT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ── the release, in one place ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.moment_release_on_retire(p_chit UUID)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE public.moments
  SET minted_chit_id = NULL,
      mint_status = CASE WHEN mint_status = 'minted' THEN 'moderated' ELSE mint_status END
  WHERE minted_chit_id = p_chit;
$$;

REVOKE ALL ON FUNCTION public.moment_release_on_retire(UUID) FROM PUBLIC, anon, authenticated;

-- ── chit_discard_pending (mig 150) + moment release ───────────────────────────────
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

  -- Release the source moment so it can be minted again (mig 158).
  PERFORM public.moment_release_on_retire(p_chit);

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

-- ── chit_swap_retire (mig 155 version: wager + marketplace guards) + release ───────
CREATE OR REPLACE FUNCTION public.chit_swap_retire(p_user UUID, p_old_chit UUID, p_new_chit UUID)
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
  -- Never retire a chit that is listed for sale (marketplace escrow, mig 154/155).
  IF EXISTS (SELECT 1 FROM public.marketplace_listings
             WHERE chit_id = p_old_chit AND seller_user_id = p_user AND status = 'active') THEN
    RAISE EXCEPTION 'Chit % is escrowed in an active marketplace listing', p_old_chit;
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

  -- Release the source moment so it can be minted again (mig 158).
  PERFORM public.moment_release_on_retire(p_old_chit);

  -- Pull it from every deck that contains it; those decks are no longer legal.
  FOR v_deck IN
    DELETE FROM public.deck_chits WHERE chit_id = p_old_chit RETURNING deck_id
  LOOP
    UPDATE public.decks SET is_legal = FALSE, validated_at = NOW(), updated_at = NOW()
    WHERE id = v_deck.deck_id;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.chit_swap_retire(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ── one-time repair: moments stuck behind an already-retired swap/discard chit ─────
DO $$
DECLARE v_n INTEGER;
BEGIN
  UPDATE public.moments m
  SET minted_chit_id = NULL,
      mint_status = CASE WHEN m.mint_status = 'minted' THEN 'moderated' ELSE m.mint_status END
  FROM public.moment_chits mc
  WHERE mc.id = m.minted_chit_id
    AND mc.retired_at IS NOT NULL
    AND mc.retired_reason IN ('swap','discarded');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'mig 158 repair: released % stuck moment(s)', v_n;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke (subtransaction-rollback pattern, mig 150): discard releases the
-- moment for a clean re-mint; a moderation retirement does NOT release.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_user UUID; v_moment UUID; v_chit UUID; v_chit2 UUID; v_minted UUID; v_status TEXT;
BEGIN
  -- Needs a user whose one self-mint slot is FREE (moment_mint enforces it, mig 142).
  SELECT u.id INTO v_user FROM auth.users u
  WHERE public.self_mint_slot(u.id) IS NULL
  LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE 'mig 158 smoke SKIPPED (no auth user with a free self-mint slot)';
    RETURN;
  END IF;

  BEGIN  -- subtransaction: everything below is rolled back at the end
    v_moment := public.moment_record(v_user, 'youtube', 'release-smoke-' || gen_random_uuid()::TEXT,
                                     'https://example.com/post', NULL, 1000, TRUE, '@smoke',
                                     'smoke title');
    IF (SELECT post_title FROM public.moments WHERE id = v_moment) <> 'smoke title' THEN
      RAISE EXCEPTION 'SMOKE FAIL: post_title not persisted';
    END IF;
    PERFORM public.moment_pre_gen_moderate(v_moment, 'approved', NULL, FALSE, 'sim');

    -- Mint → moment is locked.
    v_chit := public.moment_mint(v_moment, 'athlete', 'creature', 'on_summon');
    PERFORM public.chit_grant(v_user, v_chit, 1, 'mint', v_moment);
    UPDATE public.moment_chits SET is_active = FALSE WHERE id = v_chit;  -- pending

    -- Discard → moment released, re-mint of the SAME moment succeeds.
    PERFORM public.chit_discard_pending(v_user, v_chit);
    SELECT minted_chit_id, mint_status INTO v_minted, v_status FROM public.moments WHERE id = v_moment;
    IF v_minted IS NOT NULL THEN RAISE EXCEPTION 'SMOKE FAIL: discard must clear minted_chit_id'; END IF;
    IF v_status <> 'moderated' THEN RAISE EXCEPTION 'SMOKE FAIL: discard must roll mint_status to moderated (got %)', v_status; END IF;
    v_chit2 := public.moment_mint(v_moment, 'athlete', 'creature', 'on_summon');  -- must NOT raise

    -- Moderation retirement must NOT release.
    UPDATE public.moment_chits SET is_active = FALSE, retired_at = NOW(), retired_reason = 'moderation'
    WHERE id = v_chit2;
    IF (SELECT minted_chit_id FROM public.moments WHERE id = v_moment) IS NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: moderation retirement must not release the moment';
    END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';  -- sentinel: unwind the subtxn, discarding all test rows
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'mig 158 smoke OK: discard releases moment for re-mint; moderation retirement does not';
      ELSE
        RAISE;  -- a real assertion failure propagates and aborts the migration
      END IF;
  END;
END $$;
