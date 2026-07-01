-- Migration 136: tier-ascension (Phase 6 — P6.2).
--
-- The viral upgrade. Weekly, user-requested, ≤ once / 7 days per user (protects the social
-- APIs). On refresh: re-read the linked post's cumulative engagement, recompute tier, and
-- ASCEND if a higher tier is crossed. One-directional (never de-rank — engagement is
-- monotonic), definition-level (updates the chit row → all owned copies ascend together),
-- re-derives stats/cost/effect from the COST-BANDED ladder (stronger AND costlier). Family/
-- effect type is FIXED at mint; only magnitude/tier scales. Between-matches only — active
-- matches use the start-of-match snapshot (Hard Rule 36), so updating moment_chits is safe.
-- Large single-jump ascensions go to a manual-review queue; deleted/expired sources keep
-- their last-verified tier (no de-rank, no further ascension until re-verified).
--
-- Spec: NORA_PLATFORMS_BUILD_SPEC_v3.md §Phase 6.2.

-- ── cooldown log + large-jump review queue ──────────────────────────────────────
CREATE TABLE public.chit_ascension_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX chit_ascension_log_user_idx ON public.chit_ascension_log (user_id, refreshed_at DESC);

CREATE TABLE public.ascension_review_queue (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chit_id     UUID NOT NULL REFERENCES public.moment_chits(id),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  from_tier   TEXT NOT NULL,
  to_tier     TEXT NOT NULL,
  engagement  BIGINT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ascension_review_pending_idx ON public.ascension_review_queue (status) WHERE status = 'pending';

-- ── re-derive a chit's stats for a new tier (family/effect/timing FIXED) ─────────
CREATE OR REPLACE FUNCTION public.moment_chit_rederive(p_chit_id UUID, p_new_tier TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_c public.moment_chits%ROWTYPE; v_stats JSONB;
BEGIN
  SELECT * INTO v_c FROM public.moment_chits WHERE id = p_chit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found: %', p_chit_id; END IF;

  v_stats := public.derive_chit_stats(p_new_tier, v_c.chit_type, v_c.effect_ref);

  UPDATE public.moment_chits SET
    tier             = p_new_tier,
    aura_cost        = (v_stats->>'aura_cost')::INTEGER,
    atk              = (v_stats->>'atk')::INTEGER,
    hp               = (v_stats->>'hp')::INTEGER,
    effect_magnitude = (v_stats->>'effect_magnitude')::INTEGER,
    updated_at       = NOW()
  WHERE id = p_chit_id;
  -- archetype_family, effect_ref, timing_type, keywords intentionally unchanged.
END;
$$;

-- ── weekly ascension refresh for one user ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.chit_ascension_refresh(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
  r RECORD;
  v_new_tier TEXT; v_new_rank INTEGER; v_cur_rank INTEGER; v_jump INTEGER;
  v_ascended INTEGER := 0; v_queued INTEGER := 0;
BEGIN
  SELECT MAX(refreshed_at) INTO v_last FROM public.chit_ascension_log WHERE user_id = p_user_id;
  IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '7 days' THEN
    RAISE EXCEPTION 'Ascension refresh is available once per 7 days';
  END IF;

  FOR r IN
    SELECT m.engagement_count AS eng, mc.id AS chit_id, mc.tier AS cur_tier
    FROM public.moments m
    JOIN public.moment_chits mc ON mc.id = m.minted_chit_id
    WHERE m.owner_user_id = p_user_id
      AND m.source_status = 'active'        -- deleted/expired keep last-verified tier
      AND m.minted_chit_id IS NOT NULL
  LOOP
    v_new_tier := public.tier_for_engagement(r.eng);
    SELECT tier_rank INTO v_new_rank FROM public.tier_ladder WHERE tier = v_new_tier;
    SELECT tier_rank INTO v_cur_rank FROM public.tier_ladder WHERE tier = r.cur_tier;

    IF v_new_rank > v_cur_rank THEN            -- one-directional: only ascend
      v_jump := v_new_rank - v_cur_rank;
      IF v_jump >= 3 THEN
        INSERT INTO public.ascension_review_queue (chit_id, user_id, from_tier, to_tier, engagement)
        VALUES (r.chit_id, p_user_id, r.cur_tier, v_new_tier, r.eng);
        v_queued := v_queued + 1;
      ELSE
        PERFORM public.moment_chit_rederive(r.chit_id, v_new_tier);
        v_ascended := v_ascended + 1;
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.chit_ascension_log (user_id) VALUES (p_user_id);
  RETURN jsonb_build_object('ascended', v_ascended, 'queued_for_review', v_queued);
END;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.chit_ascension_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ascension_review_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ascension_log_select_own" ON public.chit_ascension_log
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "ascension_review_select_own" ON public.ascension_review_queue
  FOR SELECT USING (auth.uid() = user_id);
-- No client write policies (refresh runs SECURITY DEFINER; review queue is admin-only).

-- ═══════════════════════════════════════════════════════════════════════════════
-- Apply-time smoke: re-derive a seed chit up the cost-banded ladder and back, proving
-- ascension re-derivation (stronger AND costlier; family/effect fixed). (Full user-scoped
-- refresh with cooldown needs a real auth user + linked moment — test-account pass.)
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_id UUID; v_ref0 UUID; v_tier TEXT; v_cost INTEGER; v_fam TEXT; v_mag INTEGER;
BEGIN
  SELECT id, effect_ref INTO v_id, v_ref0 FROM public.moment_chits WHERE name = 'Seed Sprinter';
  IF v_id IS NULL THEN RAISE NOTICE 'P6.2 smoke skipped: Seed Sprinter not present'; RETURN; END IF;

  PERFORM public.moment_chit_rederive(v_id, 'A');
  SELECT tier, aura_cost, archetype_family, effect_magnitude INTO v_tier, v_cost, v_fam, v_mag
  FROM public.moment_chits WHERE id = v_id;

  IF v_tier <> 'A'         THEN RAISE EXCEPTION 'SMOKE FAIL: tier not A (%)', v_tier; END IF;
  IF v_cost <> 8           THEN RAISE EXCEPTION 'SMOKE FAIL: A aura_cost expected 8, got %', v_cost; END IF;
  IF v_fam  <> 'athlete'   THEN RAISE EXCEPTION 'SMOKE FAIL: family changed on ascension (%)', v_fam; END IF;
  IF v_mag  <> 12          THEN RAISE EXCEPTION 'SMOKE FAIL: A effect_magnitude expected 12, got %', v_mag; END IF;
  IF (SELECT effect_ref FROM public.moment_chits WHERE id = v_id) IS DISTINCT FROM v_ref0 THEN
    RAISE EXCEPTION 'SMOKE FAIL: effect_ref changed on ascension'; END IF;

  PERFORM public.moment_chit_rederive(v_id, 'C');   -- restore the seed
  RAISE NOTICE 'P6.2 ascension smoke OK: Seed Sprinter C→A (cost 8, mag 12, family/effect fixed) → reset C';
END $$;
