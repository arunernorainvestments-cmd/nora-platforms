-- 018_passive_effects_and_main_character.sql
-- Phase 7 deferred items:
--   1. 'passive_bonus' transaction type for badge token_earn_rate payouts
--   2. heat_score_leader_since on platform_metrics for Main Character badge tracking
--   3. evaluate_main_character_badge() function + hourly pg_cron job
--
-- Run in Supabase SQL Editor after 017_passive_effects_view.sql.

-- ── 1. Add passive_bonus to token_transactions type constraint ────────────────
-- Drop old constraint and recreate with the new value.
ALTER TABLE public.token_transactions
  DROP CONSTRAINT IF EXISTS token_transactions_type_check;

ALTER TABLE public.token_transactions
  ADD CONSTRAINT token_transactions_type_check CHECK (
    type IN (
      'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost',
      'refund', 'promoted', 'referral_bonus', 'purchase',
      'challenge_reward', 'passive_bonus'
    )
  );

-- ── 2. Add heat_score_leader_since to platform_metrics ───────────────────────
-- Tracks when the current #1 Heat Score holder first took the lead.
-- NULL = not currently the leader.
-- Set/cleared by evaluate_main_character_badge() each hour.
ALTER TABLE public.platform_metrics
  ADD COLUMN IF NOT EXISTS heat_score_leader_since timestamptz;

-- ── 3. Main Character badge evaluation function ───────────────────────────────
CREATE OR REPLACE FUNCTION public.evaluate_main_character_badge()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_leader_id    uuid;
  v_badge_id     uuid;
  v_challenge_id uuid;
BEGIN
  -- Find the user with the highest heat_score across all platform_metrics rows.
  -- A user can have multiple rows (one per platform); we pick the highest value.
  SELECT user_id INTO v_leader_id
  FROM public.platform_metrics
  WHERE heat_score IS NOT NULL
  ORDER BY heat_score DESC
  LIMIT 1;

  IF v_leader_id IS NULL THEN
    RETURN;
  END IF;

  -- Clear heat_score_leader_since for anyone who is no longer the leader.
  UPDATE public.platform_metrics
  SET heat_score_leader_since = NULL
  WHERE user_id != v_leader_id
    AND heat_score_leader_since IS NOT NULL;

  -- Set heat_score_leader_since for the current leader.
  -- COALESCE preserves the existing timestamp so streak is not reset while they remain #1.
  UPDATE public.platform_metrics
  SET heat_score_leader_since = COALESCE(heat_score_leader_since, now())
  WHERE user_id = v_leader_id;

  -- Resolve badge and challenge IDs (both seeded in migration 016).
  SELECT id INTO v_badge_id     FROM public.badge_definitions     WHERE slug = 'main_character';
  SELECT id INTO v_challenge_id FROM public.challenge_definitions WHERE slug = 'main_character';

  IF v_badge_id IS NULL THEN
    RETURN; -- badge not seeded yet, bail silently
  END IF;

  -- Award badge + 150 tokens if:
  --   a) current leader has held #1 for >= 24 consecutive hours, AND
  --   b) they do not already have the badge (prevents duplicate awards).
  IF EXISTS (
    SELECT 1 FROM public.platform_metrics
    WHERE user_id = v_leader_id
      AND heat_score_leader_since <= now() - interval '24 hours'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.user_badges
    WHERE user_id = v_leader_id AND badge_id = v_badge_id
  ) THEN
    INSERT INTO public.user_badges (user_id, badge_id, challenge_id)
    VALUES (v_leader_id, v_badge_id, v_challenge_id)
    ON CONFLICT DO NOTHING;

    PERFORM public.increment_token_balance(v_leader_id, 150);

    INSERT INTO public.token_transactions (user_id, type, amount, description)
    VALUES (
      v_leader_id,
      'challenge_reward',
      150,
      'Main Character — #1 Heat Score for 24 consecutive hours'
    );
  END IF;
END;
$$;

-- ── 4. Register hourly pg_cron job ────────────────────────────────────────────
DO $$
BEGIN
  -- Unschedule previous job if it exists (safe re-run).
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'main-character-check') THEN
    PERFORM cron.unschedule('main-character-check');
  END IF;
END;
$$;

SELECT cron.schedule(
  'main-character-check',
  '0 * * * *',
  'SELECT public.evaluate_main_character_badge()'
);
