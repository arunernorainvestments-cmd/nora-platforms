-- ─────────────────────────────────────────────────────────────────────────────
-- 092 — Restore process_poll_results() (clobbered by 091 stub)
--
-- Migration 085 created the real process_poll_results() implementation.
-- Migration 091 created a no-op stub (CREATE OR REPLACE) that overwrote it.
-- This migration restores the real function.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION process_poll_results()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_poll_id    UUID;
  v_result     RECORD;
  v_multiplier DECIMAL(4,3);
BEGIN
  SELECT id INTO v_poll_id
  FROM weekly_polls
  WHERE status = 'processed'
  ORDER BY closes_at DESC
  LIMIT 1;

  IF v_poll_id IS NULL THEN RETURN; END IF;

  FOR v_result IN
    SELECT pr.*
    FROM poll_results pr
    WHERE pr.poll_id = v_poll_id
    ORDER BY pr.final_rank ASC
  LOOP
    v_multiplier := CASE
      WHEN v_result.final_rank = 1  THEN 1.150
      WHEN v_result.final_rank = 2  THEN 1.100
      WHEN v_result.final_rank = 3  THEN 1.060
      WHEN v_result.final_rank <= 5 THEN 1.030
      WHEN v_result.final_rank <= 10 THEN 1.010
      ELSE 1.000
    END;

    CONTINUE WHEN v_result.creator_id IS NULL;

    UPDATE creator_stat_sheets
    SET
      weekly_poll_rank       = v_result.final_rank,
      weekly_poll_multiplier = v_multiplier,
      effective_power        = ROUND(stat_power      * v_multiplier)::INTEGER,
      effective_charisma     = ROUND(stat_charisma   * v_multiplier)::INTEGER,
      effective_resilience   = ROUND(stat_resilience * v_multiplier)::INTEGER,
      effective_agility      = ROUND(stat_agility    * v_multiplier)::INTEGER,
      effective_wit          = ROUND(stat_wit        * v_multiplier)::INTEGER,
      effective_influence    = ROUND(stat_influence  * v_multiplier)::INTEGER,
      last_poll_applied_at   = NOW()
    WHERE user_id = v_result.creator_id;

    UPDATE poll_results
    SET stat_multiplier_applied = v_multiplier
    WHERE id = v_result.id;

    BEGIN
      INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
      VALUES (
        v_result.creator_id,
        'poll_boost_applied',
        0,
        v_poll_id,
        'Weekly poll rank ' || v_result.final_rank || ' — stat multiplier ' || v_multiplier || 'x'
      );
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
  END LOOP;
END;
$$;
