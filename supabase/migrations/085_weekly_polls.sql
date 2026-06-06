-- ─────────────────────────────────────────────────────────────────────────────
-- 085 — Weekly Polls (Redesign Doc 1, schema from Doc 3)
--
-- Weekly creator popularity poll. Public voting (registered + anonymous), with
-- anti-abuse logic enforced in the poll-vote edge function (see doc 3). Poll
-- results drive creator_stat_sheets.weekly_poll_multiplier each Monday rollover.
--
-- Vote weight: 1.000 registered user, 0.300 anonymous.
-- IP uniqueness is intentionally NOT a DB constraint (IPs can be shared in
-- households); rate limiting is enforced at the edge fn (3 votes per IP per poll,
-- 5 per device fingerprint) with silent flagging on excess.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE weekly_polls (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_start                  DATE NOT NULL UNIQUE,
  title                       TEXT NOT NULL,
  description                 TEXT,
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'open', 'closed', 'processed')),
  opens_at                    TIMESTAMPTZ NOT NULL,
  closes_at                   TIMESTAMPTZ NOT NULL,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE poll_options (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id) ON DELETE CASCADE,
  creator_id                  UUID REFERENCES auth.users(id),
  display_name                TEXT NOT NULL,
  image_url                   TEXT,
  archetype                   TEXT,
  weighted_vote_total         DECIMAL(10,3) NOT NULL DEFAULT 0,
  raw_vote_count              INTEGER NOT NULL DEFAULT 0,
  current_rank                INTEGER,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX poll_options_poll_idx ON poll_options (poll_id, weighted_vote_total DESC);

CREATE TABLE poll_votes (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id),
  poll_option_id              UUID NOT NULL REFERENCES poll_options(id),

  voter_user_id               UUID REFERENCES auth.users(id),

  ip_hash                     TEXT NOT NULL,
  device_fingerprint          TEXT,
  user_agent_hash             TEXT,

  vote_weight                 DECIMAL(4,3) NOT NULL DEFAULT 0.300,

  is_flagged                  BOOLEAN NOT NULL DEFAULT FALSE,
  flag_reason                 TEXT,

  voted_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (poll_id, voter_user_id)
);

CREATE INDEX poll_votes_poll_idx        ON poll_votes (poll_id, is_flagged);
CREATE INDEX poll_votes_ip_idx          ON poll_votes (poll_id, ip_hash);
CREATE INDEX poll_votes_fingerprint_idx ON poll_votes (poll_id, device_fingerprint);

CREATE TABLE poll_results (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id                     UUID NOT NULL REFERENCES weekly_polls(id),
  poll_option_id              UUID NOT NULL REFERENCES poll_options(id),
  creator_id                  UUID REFERENCES auth.users(id),
  final_rank                  INTEGER NOT NULL,
  weighted_vote_total         DECIMAL(10,3) NOT NULL,
  raw_vote_count              INTEGER NOT NULL,
  stat_multiplier_applied     DECIMAL(4,3),
  processed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (poll_id, poll_option_id)
);

-- ── create_weekly_poll ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_weekly_poll()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_poll_id UUID;
  v_week_start DATE := DATE_TRUNC('week', NOW())::DATE;
BEGIN
  IF EXISTS (SELECT 1 FROM weekly_polls WHERE week_start = v_week_start) THEN
    RETURN;
  END IF;

  INSERT INTO weekly_polls (week_start, title, description, status, opens_at, closes_at)
  VALUES (
    v_week_start,
    'Who ruled this week?',
    'Vote for the creator who made the biggest impact. Votes are public and open to everyone.',
    'open',
    NOW(),
    DATE_TRUNC('week', NOW()) + INTERVAL '6 days 23 hours 59 minutes'
  ) RETURNING id INTO v_poll_id;

  INSERT INTO poll_options (poll_id, creator_id, display_name, image_url, archetype)
  SELECT
    v_poll_id,
    p.id,
    COALESCE(p.display_name, p.username),
    p.avatar_url,
    LOWER(p.category_1)
  FROM profiles p
  WHERE p.is_market_maker = TRUE
    AND p.pending_opt_out = FALSE
    AND (p.is_test_account IS NULL OR p.is_test_account = FALSE)
    AND p.is_approved = TRUE;
END;
$$;

-- ── close_and_snapshot_poll ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION close_and_snapshot_poll()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_poll  weekly_polls%ROWTYPE;
  v_option RECORD;
BEGIN
  SELECT * INTO v_poll FROM weekly_polls WHERE status = 'open' ORDER BY closes_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;

  UPDATE weekly_polls SET status = 'closed' WHERE id = v_poll.id;

  FOR v_option IN
    SELECT po.*, ROW_NUMBER() OVER (ORDER BY po.weighted_vote_total DESC) AS rn
    FROM poll_options po
    WHERE po.poll_id = v_poll.id
  LOOP
    INSERT INTO poll_results (
      poll_id, poll_option_id, creator_id,
      final_rank, weighted_vote_total, raw_vote_count
    ) VALUES (
      v_poll.id, v_option.id, v_option.creator_id,
      v_option.rn, v_option.weighted_vote_total, v_option.raw_vote_count
    );

    UPDATE poll_options SET current_rank = v_option.rn WHERE id = v_option.id;
  END LOOP;

  UPDATE weekly_polls SET status = 'processed' WHERE id = v_poll.id;
END;
$$;

-- ── process_poll_results ────────────────────────────────────────────────────
-- Called from arena_monday_rollover (modified in doc 2).
-- Applies the weekly_poll_multiplier to creator_stat_sheets based on prior week.
CREATE OR REPLACE FUNCTION process_poll_results()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_poll_id UUID;
  v_result RECORD;
  v_multiplier DECIMAL(4,3);
BEGIN
  -- Get the most recently processed poll.
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
      WHEN v_result.final_rank = 1 THEN 1.150
      WHEN v_result.final_rank = 2 THEN 1.100
      WHEN v_result.final_rank = 3 THEN 1.060
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

    -- token_transactions ledger row (amount=0). This requires type
    -- 'poll_boost_applied' to be in the type CHECK — added in migration 088.
    -- Guarded with EXCEPTION block so migration order doesn't fail the rollover.
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
      -- 088 not yet applied. Log the boost in poll_results.stat_multiplier_applied only.
      NULL;
    END;
  END LOOP;
END;
$$;

-- ── increment_poll_option_votes ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION increment_poll_option_votes(
  p_option_id UUID,
  p_weight DECIMAL(4,3)
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE poll_options
  SET
    weighted_vote_total = weighted_vote_total + p_weight,
    raw_vote_count      = raw_vote_count + 1
  WHERE id = p_option_id;
END;
$$;

-- ── pg_cron jobs ────────────────────────────────────────────────────────────
-- Mon 00:05 UTC — create new poll (5 min after arena_monday_rollover)
-- Sun 23:59 UTC — close and snapshot poll
SELECT cron.schedule(
  'create-weekly-poll',
  '5 0 * * 1',
  $$SELECT create_weekly_poll();$$
)
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'create-weekly-poll');

SELECT cron.schedule(
  'close-weekly-poll',
  '59 23 * * 0',
  $$SELECT close_and_snapshot_poll();$$
)
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'close-weekly-poll');

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE weekly_polls  ENABLE ROW LEVEL SECURITY;
ALTER TABLE poll_options  ENABLE ROW LEVEL SECURITY;
ALTER TABLE poll_votes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE poll_results  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "polls_public_read"   ON weekly_polls FOR SELECT USING (TRUE);
CREATE POLICY "options_public_read" ON poll_options FOR SELECT USING (TRUE);
CREATE POLICY "results_public_read" ON poll_results FOR SELECT USING (TRUE);

-- poll_votes: no client read; inserts via service role only (poll-vote edge fn).
-- Voter privacy: which user voted for which option is not exposed to anyone.
