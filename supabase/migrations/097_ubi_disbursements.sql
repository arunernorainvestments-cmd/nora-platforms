-- Migration 097: N.O.R.A. Emergency Fund — Disbursements, public log, cron jobs.
-- All money movement via Stripe API or sim_usd_balances only (Hard Rule #23).
-- ubi_public_disbursement_log contains no PII — anonymized records only.

-- ── Disbursements ─────────────────────────────────────────────────────────────

CREATE TABLE ubi_disbursements (
  id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id                 UUID NOT NULL UNIQUE REFERENCES ubi_withdrawal_requests(id),
  recipient_user_id          UUID NOT NULL REFERENCES auth.users(id),

  amount_usd_cents           BIGINT NOT NULL,

  stripe_payout_id           TEXT,
  stripe_destination_account TEXT,

  is_simulated               BOOLEAN NOT NULL DEFAULT FALSE,

  status                     TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  failed_reason              TEXT,

  initiated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at               TIMESTAMPTZ
);

ALTER TABLE ubi_disbursements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ubi_disbursements_own_read"
  ON ubi_disbursements FOR SELECT
  USING (recipient_user_id = auth.uid());

-- ── Public anonymized disbursement log ───────────────────────────────────────
-- Shown on fund landing page. No user_id, no names, no identifying details.

CREATE TABLE ubi_public_disbursement_log (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  disbursement_id  UUID NOT NULL REFERENCES ubi_disbursements(id),
  amount_usd_cents BIGINT NOT NULL,
  emergency_category TEXT NOT NULL,
  month_year       TEXT NOT NULL,
  votes_yes        INTEGER NOT NULL,
  votes_total      INTEGER NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX public_log_category_idx ON ubi_public_disbursement_log (emergency_category);
CREATE INDEX public_log_date_idx     ON ubi_public_disbursement_log (month_year);

ALTER TABLE ubi_public_disbursement_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ubi_public_log_read"
  ON ubi_public_disbursement_log FOR SELECT USING (TRUE);

-- ── process_ubi_vote_deadlines() ──────────────────────────────────────────────
-- Closes expired panels, sets outcome, triggers disbursement or records denial.
-- Handles one-time 24-hour extension when <50% of panel has voted.

CREATE OR REPLACE FUNCTION process_ubi_vote_deadlines()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_panel   ubi_voting_panels%ROWTYPE;
  v_request ubi_withdrawal_requests%ROWTYPE;
  v_outcome TEXT;
  v_key     TEXT := current_setting('app.service_role_key', true);
BEGIN
  FOR v_panel IN
    SELECT * FROM ubi_voting_panels
    WHERE status = 'open'
      AND (
        closes_at <= NOW()
        OR (extended_until IS NOT NULL AND extended_until <= NOW())
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Grant one-time 24-hour extension if < 50% voted at original deadline
    IF v_panel.extended_until IS NULL
      AND v_panel.closes_at <= NOW()
      AND v_panel.votes_received < (v_panel.panel_size / 2)
    THEN
      UPDATE ubi_voting_panels
      SET extended_until = NOW() + INTERVAL '24 hours'
      WHERE id = v_panel.id;
      CONTINUE;
    END IF;

    UPDATE ubi_voting_panels
    SET status = 'closed', closed_at = NOW()
    WHERE id = v_panel.id;

    IF v_panel.votes_received = 0 THEN
      v_outcome := 'inconclusive';
    ELSIF (v_panel.votes_yes::float / v_panel.votes_received::float) > 0.5 THEN
      v_outcome := 'approved';
    ELSE
      v_outcome := 'denied';
    END IF;

    UPDATE ubi_voting_panels SET outcome = v_outcome WHERE id = v_panel.id;

    SELECT * INTO v_request
    FROM ubi_withdrawal_requests WHERE id = v_panel.request_id;

    IF v_outcome = 'approved' THEN
      UPDATE ubi_withdrawal_requests
      SET status = 'approved', approved_at = NOW()
      WHERE id = v_panel.request_id;

      -- Trigger disbursement edge function
      IF v_key IS NOT NULL AND v_key <> '' THEN
        PERFORM net.http_post(
          url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/ubi-disburse',
          headers := json_build_object(
                       'Content-Type', 'application/json',
                       'Authorization', 'Bearer ' || v_key
                     )::jsonb,
          body    := json_build_object('request_id', v_panel.request_id)::jsonb
        );
      END IF;

    ELSIF v_outcome = 'denied' THEN
      IF v_panel.vote_round = 1 THEN
        UPDATE ubi_withdrawal_requests
        SET status = 'denied', denied_at = NOW()
        WHERE id = v_panel.request_id;
      ELSE
        UPDATE ubi_withdrawal_requests
        SET status = 'revote_denied', denied_at = NOW(), revote_eligible = FALSE
        WHERE id = v_panel.request_id;
      END IF;

    ELSIF v_outcome = 'inconclusive' THEN
      -- Reassemble panel for the same round
      UPDATE ubi_voting_panels SET status = 'timed_out' WHERE id = v_panel.id;

      IF v_key IS NOT NULL AND v_key <> '' THEN
        PERFORM net.http_post(
          url     := 'https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/ubi-assemble-voting-panel',
          headers := json_build_object(
                       'Content-Type', 'application/json',
                       'Authorization', 'Bearer ' || v_key
                     )::jsonb,
          body    := json_build_object(
                       'request_id', v_panel.request_id,
                       'vote_round', v_panel.vote_round
                     )::jsonb
        );
      END IF;
    END IF;

  END LOOP;
END;
$$;

-- ── process_ubi_inactive_voters() ─────────────────────────────────────────────
-- Marks voters inactive past their personal_deadline and assigns one replacement.
-- Uses replaced_by_assignment_id (not a boolean 'replaced' column).

CREATE OR REPLACE FUNCTION process_ubi_inactive_voters()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_assignment          ubi_panel_assignments%ROWTYPE;
  v_replacement_user_id UUID;
  v_new_assignment_id   UUID;
BEGIN
  FOR v_assignment IN
    SELECT * FROM ubi_panel_assignments
    WHERE assignment_status IN ('pending', 'opened')
      AND personal_deadline < NOW()
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE ubi_panel_assignments
    SET assignment_status = 'inactive'
    WHERE id = v_assignment.id;

    -- Find a replacement: eligible voter not already assigned to this request
    SELECT ev.user_id INTO v_replacement_user_id
    FROM ubi_eligible_voters ev
    WHERE ev.user_id NOT IN (
      SELECT voter_user_id FROM ubi_panel_assignments
      WHERE request_id = v_assignment.request_id
    )
    ORDER BY RANDOM()
    LIMIT 1;

    IF v_replacement_user_id IS NULL THEN
      CONTINUE;
    END IF;

    INSERT INTO ubi_panel_assignments (
      panel_id, request_id, voter_user_id,
      assignment_status, is_replacement,
      replaced_inactive_assignment_id,
      notified_at, personal_deadline
    ) VALUES (
      v_assignment.panel_id,
      v_assignment.request_id,
      v_replacement_user_id,
      'pending',
      TRUE,
      v_assignment.id,
      NOW(),
      NOW() + INTERVAL '24 hours'
    )
    RETURNING id INTO v_new_assignment_id;

    -- Link the original assignment to its replacement
    UPDATE ubi_panel_assignments
    SET replaced_by_assignment_id = v_new_assignment_id
    WHERE id = v_assignment.id;

  END LOOP;
END;
$$;

-- ── pg_cron: vote deadline check (every 30 minutes) ──────────────────────────

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ubi-vote-deadline-check') THEN
    PERFORM cron.unschedule('ubi-vote-deadline-check');
  END IF;
END;
$$;

SELECT cron.schedule(
  'ubi-vote-deadline-check',
  '*/30 * * * *',
  $$SELECT process_ubi_vote_deadlines();$$
);

-- ── pg_cron: inactive voter check (every hour) ───────────────────────────────

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ubi-inactive-voter-check') THEN
    PERFORM cron.unschedule('ubi-inactive-voter-check');
  END IF;
END;
$$;

SELECT cron.schedule(
  'ubi-inactive-voter-check',
  '0 * * * *',
  $$SELECT process_ubi_inactive_voters();$$
);

-- ── Pool balance helpers ───────────────────────────────────────────────────────
-- Called by ubi-contribute and ubi-disburse edge functions.

CREATE OR REPLACE FUNCTION increment_ubi_sim_balance(p_amount BIGINT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE ubi_pool_balance_cache
  SET sim_balance_usd_cents = sim_balance_usd_cents + p_amount,
      last_synced_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION decrement_ubi_sim_balance(p_amount BIGINT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE ubi_pool_balance_cache
  SET sim_balance_usd_cents = GREATEST(0, sim_balance_usd_cents - p_amount),
      last_synced_at = NOW();
END;
$$;

-- Extend sim_usd_transactions.type to include ubi_disbursement
ALTER TABLE public.sim_usd_transactions
  DROP CONSTRAINT IF EXISTS sim_usd_transactions_type_check;

ALTER TABLE public.sim_usd_transactions
  ADD CONSTRAINT sim_usd_transactions_type_check
    CHECK (type IN (
      'seed', 'investment', 'refund', 'distribution',
      'secondary_purchase', 'secondary_sale', 'fee',
      'governance_release', 'ubi_disbursement'
    ));

-- Credit a user's sim_usd_balances for an approved emergency fund disbursement.
CREATE OR REPLACE FUNCTION increment_sim_balance(p_user_id UUID, p_amount BIGINT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM public.sim_seed_balance(p_user_id);

  UPDATE public.sim_usd_balances
  SET balance_usd_cents = balance_usd_cents + p_amount,
      updated_at = NOW()
  WHERE user_id = p_user_id;

  INSERT INTO public.sim_usd_transactions (user_id, type, amount_usd_cents, description)
  VALUES (p_user_id, 'ubi_disbursement', p_amount, 'Emergency Fund disbursement (simulated)');
END;
$$;
