-- Migration 157: ascension user surface — client lockdown + detail-returning refresh.
--
-- The viral-upgrade loop (mig 136) gets its first user surface: the /collection
-- "check for tier-ups" flow, served by the new `chit-ascension` edge function
-- (re-reads live post engagement via the platform APIs, then runs the refresh).
-- Two schema changes have to land first:
--
--   1. LOCKDOWN. mig 136 never REVOKEd its SECURITY DEFINER functions, and Postgres
--      grants EXECUTE to PUBLIC by default — so any signed-in client could call
--      moment_chit_rederive(<any chit>, 'S') straight through PostgREST and set
--      tiers directly (a Hard Rule 34 tamper vector), or chit_ascension_refresh
--      (<other user>) to burn a stranger's weekly cooldown. The same audit found
--      ccg_create_match / ccg_create_outcome_market (migs 143/145) PUBLIC-executable
--      with zero client callers — locked down here too. Clients reach ascension ONLY
--      through the chit-ascension edge function: the refresh must be preceded by a
--      live engagement re-read, or the user's one weekly window is spent comparing
--      stale mint-time counts against themselves.
--
--   2. DETAILS. chit_ascension_refresh returned bare counts; the UI needs to know
--      WHICH chits moved (tier-up celebration) and when the next refresh unlocks.
--      Same signature and semantics (one-directional, jump >= 3 goes to review,
--      listed chits skipped per mig 155) — only the JSONB gets richer.

-- ── 1. lockdown: service-only, like every other mint-pipeline fn (mig 141/155) ──
REVOKE ALL ON FUNCTION public.moment_chit_rederive(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chit_ascension_refresh(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ccg_create_match(UUID, UUID, UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ccg_create_outcome_market(UUID) FROM PUBLIC, anon, authenticated;

-- ── 2. detail-returning refresh (supersedes the mig 155 body) ────────────────────
CREATE OR REPLACE FUNCTION public.chit_ascension_refresh(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
  r RECORD;
  v_new_tier TEXT; v_new_rank INTEGER; v_cur_rank INTEGER; v_jump INTEGER;
  v_ascended JSONB := '[]'::JSONB;
  v_queued   JSONB := '[]'::JSONB;
BEGIN
  SELECT MAX(refreshed_at) INTO v_last FROM public.chit_ascension_log WHERE user_id = p_user_id;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '7 days' THEN
    RAISE EXCEPTION 'Ascension refresh is available once per 7 days';
  END IF;

  FOR r IN
    SELECT m.engagement_count AS eng, mc.id AS chit_id, mc.name AS chit_name, mc.tier AS cur_tier
    FROM public.moments m
    JOIN public.moment_chits mc ON mc.id = m.minted_chit_id
    WHERE m.owner_user_id = p_user_id
      AND m.source_status = 'active'        -- deleted/expired keep last-verified tier
      AND m.minted_chit_id IS NOT NULL
      -- ascension frozen while escrowed in a marketplace listing (M1, mig 155)
      AND NOT EXISTS (SELECT 1 FROM public.marketplace_listings ml
                      WHERE ml.chit_id = mc.id AND ml.status = 'active')
  LOOP
    v_new_tier := public.tier_for_engagement(r.eng);
    SELECT tier_rank INTO v_new_rank FROM public.tier_ladder WHERE tier = v_new_tier;
    SELECT tier_rank INTO v_cur_rank FROM public.tier_ladder WHERE tier = r.cur_tier;

    IF v_new_rank > v_cur_rank THEN            -- one-directional: only ascend
      v_jump := v_new_rank - v_cur_rank;
      IF v_jump >= 3 THEN
        INSERT INTO public.ascension_review_queue (chit_id, user_id, from_tier, to_tier, engagement)
        VALUES (r.chit_id, p_user_id, r.cur_tier, v_new_tier, r.eng);
        v_queued := v_queued || jsonb_build_object(
          'chit_id', r.chit_id, 'name', r.chit_name,
          'from_tier', r.cur_tier, 'to_tier', v_new_tier);
      ELSE
        PERFORM public.moment_chit_rederive(r.chit_id, v_new_tier);
        v_ascended := v_ascended || jsonb_build_object(
          'chit_id', r.chit_id, 'name', r.chit_name,
          'from_tier', r.cur_tier, 'to_tier', v_new_tier);
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.chit_ascension_log (user_id) VALUES (p_user_id);
  RETURN jsonb_build_object(
    'ascended',          jsonb_array_length(v_ascended),
    'queued_for_review', jsonb_array_length(v_queued),
    'ascensions',        v_ascended,
    'queued',            v_queued,
    'next_refresh_at',   NOW() + INTERVAL '7 days'
  );
END;
$$;

-- Replacing the function re-creates it with default (PUBLIC) EXECUTE — re-revoke.
REVOKE ALL ON FUNCTION public.chit_ascension_refresh(UUID) FROM PUBLIC, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke (rollback-sentinel subtxn, mig 150 pattern — no residue):
-- privileges are actually revoked; a 2-rank jump ascends with detail; a 6-rank
-- jump queues for review; the cooldown blocks an immediate second refresh.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_u UUID; v_c1 UUID; v_c2 UUID; v_m1 UUID; v_m2 UUID;
  v_res JSONB; v_tier TEXT; v_cost INTEGER; v_err BOOLEAN;
  v_fn TEXT;
BEGIN
  -- privilege assertions (outside the subtxn: cheap, side-effect free)
  FOREACH v_fn IN ARRAY ARRAY[
    'public.moment_chit_rederive(uuid,text)',
    'public.chit_ascension_refresh(uuid)',
    'public.ccg_create_match(uuid,uuid,uuid,uuid,boolean)',
    'public.ccg_create_outcome_market(uuid)'
  ] LOOP
    IF has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'SMOKE FAIL: % still client-executable', v_fn;
    END IF;
  END LOOP;

  BEGIN
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at, raw_user_meta_data)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'asc-smoke@noraplatforms.com', '', NOW(), NOW(), NOW(),
            '{"full_name":"Ascension Smoke"}');
    UPDATE public.profiles SET is_test_account = TRUE WHERE id = v_u;

    -- chit 1: E-tier, engagement now 60k → C (jump 2) → ascends in place
    v_c1 := public.create_moment_chit('ASC smoke riser', 'athlete', 'creature', 'E');
    INSERT INTO public.moments (owner_user_id, source_platform, source_external_id,
                                engagement_count, minted_chit_id, consent_granted_at)
    VALUES (v_u, 'youtube', 'asc-smoke-1', 60000, v_c1, NOW())
    RETURNING id INTO v_m1;

    -- chit 2: F-tier, engagement now 6M → S (jump 6) → review queue, tier untouched
    v_c2 := public.create_moment_chit('ASC smoke moonshot', 'musician', 'creature', 'F');
    INSERT INTO public.moments (owner_user_id, source_platform, source_external_id,
                                engagement_count, minted_chit_id, consent_granted_at)
    VALUES (v_u, 'youtube', 'asc-smoke-2', 6000000, v_c2, NOW())
    RETURNING id INTO v_m2;

    v_res := public.chit_ascension_refresh(v_u);

    IF (v_res->>'ascended')::INT <> 1 OR (v_res->>'queued_for_review')::INT <> 1 THEN
      RAISE EXCEPTION 'SMOKE FAIL: expected 1 ascended + 1 queued, got %', v_res;
    END IF;
    IF v_res->'ascensions'->0->>'chit_id' <> v_c1::TEXT
       OR v_res->'ascensions'->0->>'from_tier' <> 'E'
       OR v_res->'ascensions'->0->>'to_tier' <> 'C' THEN
      RAISE EXCEPTION 'SMOKE FAIL: ascension detail wrong: %', v_res->'ascensions';
    END IF;
    IF v_res->'queued'->0->>'to_tier' <> 'S' OR v_res->>'next_refresh_at' IS NULL THEN
      RAISE EXCEPTION 'SMOKE FAIL: queued detail / next_refresh_at wrong: %', v_res;
    END IF;

    SELECT tier, aura_cost INTO v_tier, v_cost FROM public.moment_chits WHERE id = v_c1;
    IF v_tier <> 'C' OR v_cost NOT BETWEEN 4 AND 5 THEN
      RAISE EXCEPTION 'SMOKE FAIL: riser not re-derived to C band (tier %, cost %)', v_tier, v_cost;
    END IF;
    SELECT tier INTO v_tier FROM public.moment_chits WHERE id = v_c2;
    IF v_tier <> 'F' THEN
      RAISE EXCEPTION 'SMOKE FAIL: moonshot must stay F while review is pending (got %)', v_tier;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.ascension_review_queue
                   WHERE chit_id = v_c2 AND status = 'pending' AND to_tier = 'S') THEN
      RAISE EXCEPTION 'SMOKE FAIL: moonshot missing from the review queue';
    END IF;

    -- cooldown: an immediate second refresh must be refused
    v_err := FALSE;
    BEGIN
      PERFORM public.chit_ascension_refresh(v_u);
    EXCEPTION WHEN OTHERS THEN v_err := TRUE;
    END;
    IF NOT v_err THEN RAISE EXCEPTION 'SMOKE FAIL: cooldown must block a second refresh'; END IF;

    RAISE EXCEPTION 'SMOKE_ROLLBACK_OK';  -- sentinel: unwind the subtxn, discarding all test rows
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'SMOKE_ROLLBACK_OK' THEN
        RAISE NOTICE 'ascension-surface smoke OK: lockdown holds, E→C ascends w/ detail, F→S queued, cooldown enforced';
      ELSE
        RAISE;  -- a real assertion failure propagates and aborts the migration
      END IF;
  END;
END $$;
