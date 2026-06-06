-- ─────────────────────────────────────────────────────────────────────────────
-- 089 — Campaign Deprecation (Redesign Doc 1)
--
-- The Campaigns royalty system is replaced by the Likeness Cards system
-- (migrations 081–082). Do NOT drop the tables — rename them to preserve data
-- integrity. All FKs remain intact; rows are immutable from this point on.
--
-- The legacy Flutter campaigns UI is repointed at the renamed tables (history
-- view only — see flutter_app/lib/features/campaigns/* changes in this commit).
--
-- Cron jobs that processed live campaigns are unscheduled. The edge function
-- `campaign-process-revenue` can stay deployed; nothing will invoke it now.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.campaigns                  RENAME TO campaigns_archived;
ALTER TABLE public.campaign_ownership_ledger  RENAME TO campaigns_archived_ledger;
ALTER TABLE public.campaign_revenue_events    RENAME TO campaigns_archived_revenue;
ALTER TABLE public.campaign_distributions     RENAME TO campaigns_archived_distributions;
ALTER TABLE public.campaign_proposals         RENAME TO campaigns_archived_proposals;
ALTER TABLE public.campaign_votes             RENAME TO campaigns_archived_votes;
ALTER TABLE public.campaign_updates           RENAME TO campaigns_archived_updates;

-- Close any open archived campaigns.
UPDATE public.campaigns_archived
SET status = 'closed', closed_at = COALESCE(closed_at, NOW())
WHERE status NOT IN ('closed', 'failed');

-- Unschedule cron jobs (guarded so the migration is idempotent).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'campaign-status-tick') THEN
    PERFORM cron.unschedule('campaign-status-tick');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'governance-tick') THEN
    PERFORM cron.unschedule('governance-tick');
  END IF;
END;
$$;
