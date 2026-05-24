-- Migration 075: Campaign status tick — pg_cron job.
-- process_campaign_status_tick() runs every minute and:
--   open → funded  : goal reached (current_funding >= funding_goal)
--   open → failed  : closes_at passed without reaching goal
-- Also refunds failed simulated campaigns from sim balances.

CREATE OR REPLACE FUNCTION public.process_campaign_status_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_campaign RECORD;
BEGIN
  -- ── open → funded (goal reached) ─────────────────────────────────────────
  UPDATE public.campaigns
  SET status    = 'funded',
      funded_at = NOW()
  WHERE status = 'open'
    AND current_funding_usd_cents >= funding_goal_usd_cents;

  -- ── open → failed (deadline passed, goal not met) ─────────────────────────
  FOR v_campaign IN
    SELECT id FROM public.campaigns
    WHERE status = 'open'
      AND closes_at IS NOT NULL
      AND closes_at < NOW()
      AND current_funding_usd_cents < funding_goal_usd_cents
  LOOP
    UPDATE public.campaigns
    SET status    = 'failed',
        closed_at = NOW()
    WHERE id = v_campaign.id;

    -- Refund all simulated backers for this campaign
    UPDATE public.sim_usd_balances s
    SET balance_usd_cents       = s.balance_usd_cents + l.usd_cents_paid,
        lifetime_invested_cents = GREATEST(0, s.lifetime_invested_cents - l.usd_cents_paid),
        updated_at              = NOW()
    FROM public.campaign_ownership_ledger l
    WHERE l.campaign_id = v_campaign.id
      AND l.is_simulated = TRUE
      AND l.event_type = 'purchase'
      AND l.from_user_id IS NULL
      AND l.to_user_id = s.user_id;

    -- Log refund transactions
    INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, reference_id, description)
    SELECT
      l.to_user_id,
      'refund',
      l.usd_cents_paid,
      v_campaign.id,
      'Refund: campaign did not reach funding goal'
    FROM public.campaign_ownership_ledger l
    WHERE l.campaign_id = v_campaign.id
      AND l.is_simulated = TRUE
      AND l.event_type = 'purchase'
      AND l.from_user_id IS NULL;
  END LOOP;
END;
$$;

-- Register cron job (idempotent)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'campaign-status-tick') THEN
    PERFORM cron.unschedule('campaign-status-tick');
  END IF;
END;
$$;

SELECT cron.schedule(
  'campaign-status-tick',
  '* * * * *',
  'SELECT public.process_campaign_status_tick()'
);
