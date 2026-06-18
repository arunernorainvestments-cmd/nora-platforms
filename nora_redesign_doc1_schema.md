# NORA Redesign — Doc 1: Schema & Data Model
# For Claude Code — Read in full before touching any file.
# Companion docs: doc2_game_logic.md | doc3_marketplace_polls.md

---

## Context

This document drives migrations 079–089. It replaces the Campaigns system
(migrations 072–078) with a Likeness Ownership system built around collectible
character cards and prediction markets. It also introduces stat sheets, battle
format flexibility, the Arena↔Battle link, weekly polls, and Battle Chits.

**Before starting:**
1. Read CLAUDE.md in full.
2. Read docs/campaigns-framework.md — you are replacing this system.
3. Read docs/scoring-and-db-spec.md — you are extending this system.
4. Read docs/battle-spec.md — you are modifying this system.
5. Run `flutter analyze` — zero issues required before and after every migration.

**Hard Rule update (add to CLAUDE.md after these migrations are applied):**
- REMOVE Rule 21: "Battle and Arena are entirely separate"
- REPLACE WITH: "Battle matches are the source of truth for linked Arena markets.
  Arena auto-opens on battle_start_match and resolves on battle resolution only.
  All Battle artifacts remain prefixed battle_. Arena artifacts remain unprefixed."

---

## Deprecation Strategy (Migration 088 — run last)

Do NOT delete campaign tables. Rename them to preserve data integrity.

| Current Name | Renamed To | Notes |
|---|---|---|
| campaigns | campaigns_archived | Set all status = 'closed', mode = 'simulated' |
| campaign_ownership_ledger | campaigns_archived_ledger | Append-only — do not alter rows |
| campaign_revenue_events | campaigns_archived_revenue | Archive only |
| campaign_distributions | campaigns_archived_distributions | Archive only |
| campaign_proposals | campaigns_archived_proposals | Archive only |
| campaign_votes | campaigns_archived_votes | Archive only |
| campaign_stake_listings | campaigns_archived_listings | Archive only |
| campaign_stake_sales | campaigns_archived_sales | Archive only |
| campaign_updates | campaigns_archived_updates | Archive only |
| campaign_unclaimed_balances | campaigns_archived_unclaimed | Archive only |

**sim_usd_balances and sim_usd_transactions**: keep as-is. They are reused by
the new simulated card purchase flow.

**kyc_verifications**: kept but simplified in migration 089. Remove all
Reg CF-specific columns. Keep identity verification fields only.

---

## Migration 079 — Creator Stat Sheets

File: `supabase/migrations/079_creator_stat_sheets.sql`

### New Table: creator_stat_sheets

```sql
-- One row per market maker. Updated by sync-stat-sheets edge function
-- (which runs after every sync-platform-metrics execution).
-- Stats are percentile-ranked globally across all market makers, then
-- normalized to a 300-point budget (50 average per stat).
-- weekly_poll_multiplier is applied on top as a temporary weekly modifier.

CREATE TABLE creator_stat_sheets (
  user_id                     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Six base stats (sum to 300 at calculation time; may vary slightly due to rounding)
  stat_power                  INTEGER NOT NULL DEFAULT 50
    CHECK (stat_power BETWEEN 0 AND 150),
  stat_charisma               INTEGER NOT NULL DEFAULT 50
    CHECK (stat_charisma BETWEEN 0 AND 150),
  stat_resilience             INTEGER NOT NULL DEFAULT 50
    CHECK (stat_resilience BETWEEN 0 AND 150),
  stat_agility                INTEGER NOT NULL DEFAULT 50
    CHECK (stat_agility BETWEEN 0 AND 150),
  stat_wit                    INTEGER NOT NULL DEFAULT 50
    CHECK (stat_wit BETWEEN 0 AND 150),
  stat_influence              INTEGER NOT NULL DEFAULT 50
    CHECK (stat_influence BETWEEN 0 AND 150),

  -- Weekly poll modifier (applied as multiplier, resets each Monday rollover)
  -- 1.00 = no modifier. 1.10 = +10% to all effective stats (1st place bonus).
  weekly_poll_rank            INTEGER,              -- 1 = winner
  weekly_poll_multiplier      DECIMAL(4,3) NOT NULL DEFAULT 1.000,

  -- Effective stats (base × poll multiplier) — used by Battle and Arena
  -- These are computed at read time in the application layer (not stored columns),
  -- but are cached here for fast Battle match lookups.
  effective_power             INTEGER NOT NULL DEFAULT 50,
  effective_charisma          INTEGER NOT NULL DEFAULT 50,
  effective_resilience        INTEGER NOT NULL DEFAULT 50,
  effective_agility           INTEGER NOT NULL DEFAULT 50,
  effective_wit               INTEGER NOT NULL DEFAULT 50,
  effective_influence         INTEGER NOT NULL DEFAULT 50,

  -- Snapshot taken at time of last calculation
  platform_count              INTEGER NOT NULL DEFAULT 0,
  calculated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_poll_applied_at        TIMESTAMPTZ
);

CREATE INDEX stat_sheets_power_idx     ON creator_stat_sheets (stat_power DESC);
CREATE INDEX stat_sheets_charisma_idx  ON creator_stat_sheets (stat_charisma DESC);
CREATE INDEX stat_sheets_influence_idx ON creator_stat_sheets (stat_influence DESC);
```

### New Table: creator_stat_history

```sql
-- One row per calculation run per user. Powers the stat trend chart
-- on the public profile screen (same pattern as score_history).

CREATE TABLE creator_stat_history (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  stat_power                  INTEGER NOT NULL,
  stat_charisma               INTEGER NOT NULL,
  stat_resilience             INTEGER NOT NULL,
  stat_agility                INTEGER NOT NULL,
  stat_wit                    INTEGER NOT NULL,
  stat_influence              INTEGER NOT NULL,
  weekly_poll_multiplier      DECIMAL(4,3) NOT NULL DEFAULT 1.000,
  recorded_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX stat_history_user_idx ON creator_stat_history (user_id, recorded_at DESC);
```

### New Function: calculate_stat_sheets()

```sql
-- Called by the sync-stat-sheets edge function after sync-platform-metrics completes.
-- Uses percentile ranking across ALL market makers to normalize stats.
-- Celebs (is_celeb = TRUE on profiles) use celeb_weekly_scores as their data source.
-- Regular market makers use platform_metrics.

CREATE OR REPLACE FUNCTION calculate_stat_sheets()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Step 1: Calculate raw stat values for regular market makers
  WITH regular_raw AS (
    SELECT
      pm.user_id,
      -- POWER: total follower reach across all connected platforms
      COALESCE(SUM(pm.follower_count), 0)::float AS raw_power,

      -- CHARISMA: weighted engagement rate (platform-adjusted)
      COALESCE(AVG(
        CASE
          WHEN pm.platform = 'x' THEN
            (COALESCE(pm.recent_post_views, 0) * 0.1
             + COALESCE(pm.reposts, 0) * 3
             + COALESCE(pm.likes, 0))::float
            / NULLIF(pm.follower_count, 0)
          WHEN pm.platform IN ('youtube', 'twitch') THEN
            COALESCE(pm.live_viewer_count, 0)::float
            / NULLIF(pm.follower_count, 0) * 50
          WHEN pm.platform = 'spotify' THEN
            -- recent_post_views = saved_tracks, reposts = saved_albums (column reuse per migration 020)
            (COALESCE(pm.recent_post_views, 0) * 3
             + COALESCE(pm.reposts, 0) * 3)::float
            / NULLIF(pm.follower_count, 0)
          ELSE 0
        END
      ), 0) AS raw_charisma,

      -- RESILIENCE: follower stability (inverse of churn)
      COALESCE(AVG(
        1.0 - GREATEST(0.0,
          (COALESCE(pm.previous_follower_count, pm.follower_count)
           - pm.follower_count)::float
          / NULLIF(pm.previous_follower_count, 0)
        )
      ), 0.5) AS raw_resilience,

      -- AGILITY: growth velocity + platform diversity bonus
      (COALESCE(AVG(
        GREATEST(0.0,
          (pm.follower_count
           - COALESCE(pm.previous_follower_count, pm.follower_count))::float
          / NULLIF(pm.previous_follower_count, 0)
        )
      ), 0) * 0.7
      + (COUNT(DISTINCT pm.platform)::float / 4.0) * 0.3) AS raw_agility,

      -- WIT: content depth and quality signal
      COALESCE(AVG(
        CASE
          WHEN pm.platform = 'x' THEN
            COALESCE(pm.likes, 0)::float / NULLIF(pm.recent_post_views, 0)
          WHEN pm.platform = 'spotify' THEN
            (COALESCE(pm.recent_post_views, 0)
             + COALESCE(pm.reposts, 0))::float
            / NULLIF(pm.follower_count, 0)
          WHEN pm.platform IN ('youtube', 'twitch') THEN
            COALESCE(pm.live_viewer_count, 0)::float
            / NULLIF(pm.follower_count, 0)
          ELSE 0
        END
      ), 0) AS raw_wit,

      -- INFLUENCE: average display_score per connected platform
      COALESCE(SUM(pm.display_score)::float
        / NULLIF(COUNT(DISTINCT pm.platform), 0), 0) AS raw_influence,

      COUNT(DISTINCT pm.platform) AS platform_count

    FROM platform_metrics pm
    JOIN profiles p ON p.id = pm.user_id
    WHERE p.is_market_maker = TRUE
      AND p.pending_opt_out = FALSE
      AND (p.is_celeb IS NULL OR p.is_celeb = FALSE)
      AND (p.is_test_account IS NULL OR p.is_test_account = FALSE)
    GROUP BY pm.user_id
  ),

  -- Step 2: Celeb stats derived from celeb_weekly_scores + celeb_score_history
  celeb_raw AS (
    SELECT
      p.id AS user_id,
      -- Power: story volume as proxy for reach
      COALESCE(cws.story_volume, 0)::float * 1000 AS raw_power,
      -- Charisma: ratio of positive scoring windows to total
      COALESCE(
        SUM(CASE WHEN csh.delta > 0 THEN 1 ELSE 0 END)::float
        / NULLIF(COUNT(csh.id), 0) * 100, 50
      ) AS raw_charisma,
      -- Resilience: recovery after negative deltas
      COALESCE(
        1.0 - (SUM(CASE WHEN csh.delta < -5 THEN 1 ELSE 0 END)::float
        / NULLIF(COUNT(csh.id), 0)), 0.5
      ) AS raw_resilience,
      -- Agility: scoring frequency (story volume this week)
      COALESCE(cws.story_volume, 0)::float / 10.0 AS raw_agility,
      -- Wit: average absolute delta (high delta = strong content signal)
      COALESCE(AVG(ABS(csh.delta)), 0)::float AS raw_wit,
      -- Influence: current rank (inverted — rank 1 = highest influence)
      COALESCE((26 - cws.rank)::float * 10, 50) AS raw_influence,
      1 AS platform_count  -- celebs are treated as single-platform
    FROM profiles p
    JOIN celebs c ON c.id = p.celeb_id
    LEFT JOIN celeb_weekly_scores cws ON cws.celeb_id = c.id
      AND cws.week_id = (
        SELECT id FROM celeb_weeks ORDER BY week_start DESC LIMIT 1
      )
    LEFT JOIN celeb_score_history csh ON csh.celeb_id = c.id
      AND csh.scored_at > NOW() - INTERVAL '7 days'
    WHERE p.is_celeb = TRUE
    GROUP BY p.id, cws.story_volume, cws.rank
  ),

  -- Step 3: Combine regular + celeb raw stats
  all_raw AS (
    SELECT * FROM regular_raw
    UNION ALL
    SELECT * FROM celeb_raw
  ),

  -- Step 4: Percentile-rank each stat globally (0–100 scale)
  percentiled AS (
    SELECT
      user_id,
      platform_count,
      PERCENT_RANK() OVER (ORDER BY raw_power)      * 100 AS pct_power,
      PERCENT_RANK() OVER (ORDER BY raw_charisma)   * 100 AS pct_charisma,
      PERCENT_RANK() OVER (ORDER BY raw_resilience) * 100 AS pct_resilience,
      PERCENT_RANK() OVER (ORDER BY raw_agility)    * 100 AS pct_agility,
      PERCENT_RANK() OVER (ORDER BY raw_wit)        * 100 AS pct_wit,
      PERCENT_RANK() OVER (ORDER BY raw_influence)  * 100 AS pct_influence
    FROM all_raw
  ),

  -- Step 5: Normalize to 300-point budget
  budgeted AS (
    SELECT
      user_id,
      platform_count,
      -- Guard against zero-sum edge case (new user with no data)
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_power / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_power,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_charisma / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_charisma,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_resilience / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_resilience,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_agility / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_agility,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_wit / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_wit,
      CASE
        WHEN (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence) = 0
        THEN 50 ELSE
        ROUND((pct_influence / (pct_power + pct_charisma + pct_resilience + pct_agility + pct_wit + pct_influence)) * 300)::INTEGER
      END AS stat_influence
    FROM percentiled
  )

  -- Step 6: Upsert into creator_stat_sheets
  INSERT INTO creator_stat_sheets (
    user_id,
    stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence,
    effective_power, effective_charisma, effective_resilience,
    effective_agility, effective_wit, effective_influence,
    platform_count, calculated_at
  )
  SELECT
    b.user_id,
    b.stat_power, b.stat_charisma, b.stat_resilience,
    b.stat_agility, b.stat_wit, b.stat_influence,
    -- Effective stats: apply existing poll multiplier if present, else 1.0
    ROUND(b.stat_power    * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_charisma * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_resilience * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_agility  * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_wit      * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    ROUND(b.stat_influence * COALESCE(css.weekly_poll_multiplier, 1.000))::INTEGER,
    b.platform_count,
    NOW()
  FROM budgeted b
  LEFT JOIN creator_stat_sheets css ON css.user_id = b.user_id
  ON CONFLICT (user_id) DO UPDATE SET
    stat_power      = EXCLUDED.stat_power,
    stat_charisma   = EXCLUDED.stat_charisma,
    stat_resilience = EXCLUDED.stat_resilience,
    stat_agility    = EXCLUDED.stat_agility,
    stat_wit        = EXCLUDED.stat_wit,
    stat_influence  = EXCLUDED.stat_influence,
    effective_power      = EXCLUDED.effective_power,
    effective_charisma   = EXCLUDED.effective_charisma,
    effective_resilience = EXCLUDED.effective_resilience,
    effective_agility    = EXCLUDED.effective_agility,
    effective_wit        = EXCLUDED.effective_wit,
    effective_influence  = EXCLUDED.effective_influence,
    platform_count  = EXCLUDED.platform_count,
    calculated_at   = EXCLUDED.calculated_at;

  -- Step 7: Snapshot to history table (for trend charts)
  INSERT INTO creator_stat_history (
    user_id, stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence, weekly_poll_multiplier
  )
  SELECT
    user_id, stat_power, stat_charisma, stat_resilience,
    stat_agility, stat_wit, stat_influence, weekly_poll_multiplier
  FROM creator_stat_sheets;

END;
$$;
```

### pg_cron Job: sync-stat-sheets

Add to the cron schedule (call from within `sync-platform-metrics` edge function
at the end of its execution, or as a separate job that runs 30 seconds after
sync-platform-metrics via an offset schedule):

```sql
-- Option A: Call from within sync-platform-metrics edge function (preferred)
-- At the end of the sync-platform-metrics Deno function, after all upserts:
--   await supabaseAdmin.rpc('calculate_stat_sheets');

-- Option B: Separate cron job (fallback)
SELECT cron.schedule(
  'sync-stat-sheets',
  '*/5 * * * *',  -- every 5 minutes (offset by 30s from sync-platform-metrics)
  $$SELECT calculate_stat_sheets();$$
);
```

---

## Migration 080 — Likeness Offerings & Cards

File: `supabase/migrations/080_likeness_system.sql`

### Framing Note for Claude Code
This system replaces the Campaigns royalty framework. The language throughout
must reflect collectible game assets, not financial instruments:
- "Offering" = a creator releasing cards for their character
- "Card" = a collectible with game utility (Battle eligibility + match reward share)
- "Match rewards" = game earnings from Battle/Arena, not "dividends" or "returns"
- Never use: "investment", "return", "yield", "dividend", "revenue share"

### New Table: likeness_offerings

```sql
-- A creator or celeb makes a limited print run of character cards available.
-- Owning a card gives the holder Battle eligibility for that character
-- and a proportional share of match rewards when that character plays.

CREATE TABLE likeness_offerings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  -- Character identity
  character_name              TEXT NOT NULL,         -- display name on the card
  character_image_url         TEXT,                  -- card art (can differ from profile avatar)
  archetype                   TEXT NOT NULL          -- matches battle archetypes
    CHECK (archetype IN (
      'athlete','musician','business','comedian','artist',
      'gamer','influencer','scientist','politician','actor',
      'healthcare','performer','educator','religion'
    )),

  -- Card structure
  total_pct_offered           DECIMAL(10,6) NOT NULL -- % of match rewards offered (e.g. 30.0)
    CHECK (total_pct_offered > 0 AND total_pct_offered <= 75),
  card_print_run              INTEGER NOT NULL        -- e.g. 100 cards total
    CHECK (card_print_run BETWEEN 1 AND 10000),
  pct_per_card                DECIMAL(10,6) NOT NULL, -- total_pct_offered / card_print_run

  -- Pricing
  price_per_card_usd_cents    BIGINT NOT NULL
    CHECK (price_per_card_usd_cents >= 100),         -- minimum $1.00

  -- State
  mode                        TEXT NOT NULL DEFAULT 'simulated'
    CHECK (mode IN ('simulated', 'live')),
  status                      TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'sold_out', 'closed')),

  -- Supply tracking
  cards_minted                INTEGER NOT NULL DEFAULT 0
    CHECK (cards_minted >= 0),

  -- Platform fee snapshot at time of offering creation (10%)
  platform_listing_fee_pct    DECIMAL(5,4) NOT NULL DEFAULT 0.1000,

  -- Creator receives 90% of initial sale proceeds (via Stripe for live mode)
  -- Platform retains 10% as listing fee
  -- No real Stripe call in simulated mode — sim_usd_balances used instead

  listed_at                   TIMESTAMPTZ,
  closed_at                   TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT pct_per_card_correct CHECK (
    ABS(pct_per_card - (total_pct_offered / card_print_run)) < 0.001
  )
);

CREATE INDEX offerings_creator_idx ON likeness_offerings (creator_id, status);
CREATE INDEX offerings_status_idx  ON likeness_offerings (status);
```

### New Table: likeness_cards

```sql
-- One row per card in the print run. Minted on purchase.
-- card_number within the offering determines rarity:
--   #1       = legendary  (most sought after)
--   #2–10    = rare
--   #11+     = standard

CREATE TABLE likeness_cards (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),  -- denormalized for fast joins
  card_number                 INTEGER NOT NULL,      -- sequential within offering (1 to print_run)
  royalty_pct                 DECIMAL(10,6) NOT NULL, -- = offering.pct_per_card at mint time

  rarity                      TEXT NOT NULL DEFAULT 'standard'
    GENERATED ALWAYS AS (
      CASE
        WHEN card_number = 1 THEN 'legendary'
        WHEN card_number <= 10 THEN 'rare'
        ELSE 'standard'
      END
    ) STORED,

  -- Current owner (mutable — updated by trigger after each transfer)
  -- Source of truth is likeness_card_transfers; this is the cached current state.
  current_owner_id            UUID REFERENCES auth.users(id),

  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  minted_at                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (offering_id, card_number)
);

CREATE INDEX cards_owner_idx    ON likeness_cards (current_owner_id, is_active);
CREATE INDEX cards_creator_idx  ON likeness_cards (creator_id);
CREATE INDEX cards_offering_idx ON likeness_cards (offering_id);
```

### New Table: likeness_card_transfers

```sql
-- Append-only ledger. Never UPDATE rows here.
-- Mirrors the campaign_ownership_ledger pattern.
-- from_user_id NULL = initial mint from offering.

CREATE TABLE likeness_card_transfers (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),  -- denorm
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),          -- denorm

  from_user_id                UUID REFERENCES auth.users(id),  -- NULL = mint
  to_user_id                  UUID NOT NULL REFERENCES auth.users(id),

  usd_cents_paid              BIGINT NOT NULL DEFAULT 0,
  transfer_type               TEXT NOT NULL CHECK (transfer_type IN (
    'mint',                  -- initial purchase from offering
    'marketplace_sale',      -- secondary market sale between users
    'gift',                  -- gifted with no payment
    'platform_correction'    -- admin correction with audit trail
  )),

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id    TEXT,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX transfers_card_idx     ON likeness_card_transfers (card_id, created_at DESC);
CREATE INDEX transfers_to_user_idx  ON likeness_card_transfers (to_user_id, created_at DESC);
CREATE INDEX transfers_creator_idx  ON likeness_card_transfers (creator_id);
```

### Trigger: update likeness_cards.current_owner_id on transfer

```sql
CREATE OR REPLACE FUNCTION update_card_owner_on_transfer()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE likeness_cards
  SET current_owner_id = NEW.to_user_id
  WHERE id = NEW.card_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER after_card_transfer
  AFTER INSERT ON likeness_card_transfers
  FOR EACH ROW EXECUTE FUNCTION update_card_owner_on_transfer();
```

### New RPC: likeness_mint_card(offering_id, buyer_user_id)

```sql
-- Called by the likeness-purchase-card edge function.
-- Atomically mints the next available card in the offering.
-- Checks sim balance or triggers Stripe depending on offering.mode.

CREATE OR REPLACE FUNCTION likeness_mint_card(
  p_offering_id UUID,
  p_buyer_user_id UUID
)
RETURNS UUID  -- returns new card_id
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_offering      likeness_offerings%ROWTYPE;
  v_card_number   INTEGER;
  v_card_id       UUID;
BEGIN
  -- Lock offering row
  SELECT * INTO v_offering
  FROM likeness_offerings
  WHERE id = p_offering_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offering not found or not active: %', p_offering_id;
  END IF;

  IF v_offering.cards_minted >= v_offering.card_print_run THEN
    RAISE EXCEPTION 'Offering sold out';
  END IF;

  v_card_number := v_offering.cards_minted + 1;

  -- Deduct payment (sim mode uses sim_usd_balances)
  IF v_offering.mode = 'simulated' THEN
    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents - v_offering.price_per_card_usd_cents,
        lifetime_invested_cents = lifetime_invested_cents + v_offering.price_per_card_usd_cents,
        updated_at = NOW()
    WHERE user_id = p_buyer_user_id
      AND balance_usd_cents >= v_offering.price_per_card_usd_cents;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Insufficient sim balance';
    END IF;

    INSERT INTO sim_usd_transactions (
      user_id, type, amount_usd_cents, reference_id, description
    ) VALUES (
      p_buyer_user_id,
      'card_purchase',
      -v_offering.price_per_card_usd_cents,
      p_offering_id,
      'Card #' || v_card_number || ' — ' || v_offering.character_name
    );
  END IF;
  -- Live mode: Stripe payment intent already confirmed before calling this RPC.

  -- Mint the card
  INSERT INTO likeness_cards (
    offering_id, creator_id, card_number, royalty_pct, current_owner_id
  ) VALUES (
    p_offering_id,
    v_offering.creator_id,
    v_card_number,
    v_offering.pct_per_card,
    p_buyer_user_id
  ) RETURNING id INTO v_card_id;

  -- Write transfer log (mint event)
  INSERT INTO likeness_card_transfers (
    card_id, offering_id, creator_id,
    from_user_id, to_user_id,
    usd_cents_paid, transfer_type, is_simulated
  ) VALUES (
    v_card_id, p_offering_id, v_offering.creator_id,
    NULL,  -- mint from offering pool
    p_buyer_user_id,
    v_offering.price_per_card_usd_cents,
    'mint',
    v_offering.mode = 'simulated'
  );

  -- Increment minted count; check if sold out
  UPDATE likeness_offerings
  SET cards_minted = v_card_number,
      status = CASE WHEN v_card_number = card_print_run THEN 'sold_out' ELSE status END
  WHERE id = p_offering_id;

  RETURN v_card_id;
END;
$$;
```

---

## Migration 081 — Card Marketplace

File: `supabase/migrations/081_card_marketplace.sql`

```sql
-- Secondary market for likeness cards.
-- Buy-now listings only (MVP). No open order book.

CREATE TABLE card_marketplace_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  offering_id                 UUID NOT NULL REFERENCES likeness_offerings(id),  -- denorm
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),          -- denorm

  asking_price_usd_cents      BIGINT NOT NULL CHECK (asking_price_usd_cents > 0),
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'sold', 'cancelled')),

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sold_at                     TIMESTAMPTZ,

  -- Only one active listing per card at a time
  CONSTRAINT one_active_listing_per_card EXCLUDE (card_id WITH =)
    WHERE (status = 'active')
);

CREATE TABLE card_marketplace_sales (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id                  UUID NOT NULL REFERENCES card_marketplace_listings(id),
  card_id                     UUID NOT NULL REFERENCES likeness_cards(id),
  buyer_user_id               UUID NOT NULL REFERENCES auth.users(id),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  creator_id                  UUID NOT NULL REFERENCES auth.users(id),

  price_paid_usd_cents        BIGINT NOT NULL,
  platform_fee_usd_cents      BIGINT NOT NULL DEFAULT 0,   -- 5% of price
  seller_proceeds_usd_cents   BIGINT NOT NULL DEFAULT 0,   -- 95% of price

  is_simulated                BOOLEAN NOT NULL DEFAULT FALSE,
  stripe_payment_intent_id    TEXT,
  completed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX listings_creator_idx  ON card_marketplace_listings (creator_id, status);
CREATE INDEX listings_seller_idx   ON card_marketplace_listings (seller_user_id, status);
CREATE INDEX sales_buyer_idx       ON card_marketplace_sales (buyer_user_id);
CREATE INDEX sales_seller_idx      ON card_marketplace_sales (seller_user_id);
```

### New RPC: card_marketplace_purchase(listing_id, buyer_user_id)

```sql
CREATE OR REPLACE FUNCTION card_marketplace_purchase(
  p_listing_id UUID,
  p_buyer_user_id UUID
)
RETURNS UUID  -- returns sale_id
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_listing     card_marketplace_listings%ROWTYPE;
  v_fee         BIGINT;
  v_proceeds    BIGINT;
  v_sale_id     UUID;
BEGIN
  SELECT * INTO v_listing
  FROM card_marketplace_listings
  WHERE id = p_listing_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Listing not found or already sold'; END IF;
  IF v_listing.seller_user_id = p_buyer_user_id THEN
    RAISE EXCEPTION 'Cannot purchase your own listing';
  END IF;

  v_fee      := ROUND(v_listing.asking_price_usd_cents * 0.05);
  v_proceeds := v_listing.asking_price_usd_cents - v_fee;

  -- Sim mode: deduct from buyer, credit seller
  IF v_listing.is_simulated THEN
    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents - v_listing.asking_price_usd_cents,
        updated_at = NOW()
    WHERE user_id = p_buyer_user_id
      AND balance_usd_cents >= v_listing.asking_price_usd_cents;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient sim balance'; END IF;

    UPDATE sim_usd_balances
    SET balance_usd_cents = balance_usd_cents + v_proceeds,
        lifetime_returned_cents = lifetime_returned_cents + v_proceeds,
        updated_at = NOW()
    WHERE user_id = v_listing.seller_user_id;
  END IF;

  -- Update listing status
  UPDATE card_marketplace_listings
  SET status = 'sold', sold_at = NOW()
  WHERE id = p_listing_id;

  -- Write transfer log
  INSERT INTO likeness_card_transfers (
    card_id, offering_id, creator_id,
    from_user_id, to_user_id,
    usd_cents_paid, transfer_type, is_simulated
  ) VALUES (
    v_listing.card_id, v_listing.offering_id, v_listing.creator_id,
    v_listing.seller_user_id, p_buyer_user_id,
    v_listing.asking_price_usd_cents, 'marketplace_sale',
    v_listing.is_simulated
  );

  -- Record sale
  INSERT INTO card_marketplace_sales (
    listing_id, card_id, buyer_user_id, seller_user_id, creator_id,
    price_paid_usd_cents, platform_fee_usd_cents, seller_proceeds_usd_cents,
    is_simulated
  ) VALUES (
    p_listing_id, v_listing.card_id, p_buyer_user_id,
    v_listing.seller_user_id, v_listing.creator_id,
    v_listing.asking_price_usd_cents, v_fee, v_proceeds,
    v_listing.is_simulated
  ) RETURNING id INTO v_sale_id;

  RETURN v_sale_id;
END;
$$;
```

---

## Migration 082 — Battle Format & Ownership Gate

File: `supabase/migrations/082_battle_format_ownership.sql`

```sql
-- Add format column to battle_matches
ALTER TABLE battle_matches
  ADD COLUMN format TEXT NOT NULL DEFAULT '3v3'
    CHECK (format IN ('1v1', '2v2', '3v3'));

-- Link participants to the card they're fielding (NULL if original creator battling as self)
ALTER TABLE battle_participants
  ADD COLUMN likeness_card_id UUID REFERENCES likeness_cards(id),
  ADD COLUMN creator_id UUID REFERENCES auth.users(id);
  -- creator_id: the market maker this participant represents
  -- likeness_card_id: the card granting eligibility (NULL if creator = user_id)
```

### New Function: check_battle_eligibility

```sql
-- Returns TRUE if user is eligible to field this creator in Battle.
-- Eligibility requires EITHER:
-- 1. user_id IS the creator (battling as themselves), OR
-- 2. user_id owns at least one active likeness_card for this creator.

CREATE OR REPLACE FUNCTION check_battle_eligibility(
  p_user_id    UUID,
  p_creator_id UUID
)
RETURNS TABLE (
  is_eligible     BOOLEAN,
  card_id         UUID,    -- the card being used (NULL if self)
  eligibility_type TEXT    -- 'self' | 'owner'
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Check self (creator battling as themselves)
  IF p_user_id = p_creator_id THEN
    RETURN QUERY SELECT TRUE, NULL::UUID, 'self'::TEXT;
    RETURN;
  END IF;

  -- Check card ownership
  RETURN QUERY
    SELECT
      TRUE,
      lc.id,
      'owner'::TEXT
    FROM likeness_cards lc
    JOIN likeness_offerings lo ON lo.id = lc.offering_id
    WHERE lc.current_owner_id = p_user_id
      AND lo.creator_id = p_creator_id
      AND lc.is_active = TRUE
    LIMIT 1;

  -- If nothing returned, user is not eligible
  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'none'::TEXT;
  END IF;
END;
$$;
```

### New Function: get_eligible_characters(user_id)

```sql
-- Returns all characters a user can field in Battle:
-- their own profile (if market maker) + all cards they own.

CREATE OR REPLACE FUNCTION get_eligible_characters(p_user_id UUID)
RETURNS TABLE (
  creator_id          UUID,
  character_name      TEXT,
  archetype           TEXT,
  character_image_url TEXT,
  eligibility_type    TEXT,   -- 'self' | 'owner'
  card_id             UUID,
  card_number         INTEGER,
  rarity              TEXT,
  stat_power          INTEGER,
  stat_charisma       INTEGER,
  stat_resilience     INTEGER,
  stat_agility        INTEGER,
  stat_wit            INTEGER,
  stat_influence      INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Self (if market maker)
  RETURN QUERY
    SELECT
      p.id, p.username, p.category,
      p.avatar_url,
      'self'::TEXT,
      NULL::UUID, NULL::INTEGER, NULL::TEXT,
      COALESCE(css.effective_power, 50),
      COALESCE(css.effective_charisma, 50),
      COALESCE(css.effective_resilience, 50),
      COALESCE(css.effective_agility, 50),
      COALESCE(css.effective_wit, 50),
      COALESCE(css.effective_influence, 50)
    FROM profiles p
    LEFT JOIN creator_stat_sheets css ON css.user_id = p.id
    WHERE p.id = p_user_id
      AND p.is_market_maker = TRUE
      AND p.pending_opt_out = FALSE;

  -- Owned cards
  RETURN QUERY
    SELECT
      lo.creator_id,
      lo.character_name,
      lo.archetype,
      lo.character_image_url,
      'owner'::TEXT,
      lc.id, lc.card_number, lc.rarity,
      COALESCE(css.effective_power, 50),
      COALESCE(css.effective_charisma, 50),
      COALESCE(css.effective_resilience, 50),
      COALESCE(css.effective_agility, 50),
      COALESCE(css.effective_wit, 50),
      COALESCE(css.effective_influence, 50)
    FROM likeness_cards lc
    JOIN likeness_offerings lo ON lo.id = lc.offering_id
    LEFT JOIN creator_stat_sheets css ON css.user_id = lo.creator_id
    WHERE lc.current_owner_id = p_user_id
      AND lc.is_active = TRUE
      AND lo.status IN ('active', 'sold_out');
END;
$$;
```

---

## Migration 083 — Arena↔Battle Link & Resolution Type

File: `supabase/migrations/083_arena_battle_link.sql`

```sql
-- Link arena_matches to the battle_match that triggered them.
-- When battle_match_id IS NOT NULL, resolution_type must be 'battle_outcome'.
-- When battle_match_id IS NULL, resolution_type defaults to 'display_score' (legacy Markets).

ALTER TABLE arena_matches
  ADD COLUMN battle_match_id  UUID REFERENCES battle_matches(id),
  ADD COLUMN resolution_type  TEXT NOT NULL DEFAULT 'display_score'
    CHECK (resolution_type IN ('display_score', 'battle_outcome')),
  ADD CONSTRAINT battle_link_requires_outcome CHECK (
    (battle_match_id IS NULL) OR (resolution_type = 'battle_outcome')
  );

CREATE INDEX arena_battle_link_idx ON arena_matches (battle_match_id)
  WHERE battle_match_id IS NOT NULL;

-- Update bets position constraint to allow team positions for battle-linked markets
ALTER TABLE bets DROP CONSTRAINT IF EXISTS bets_position_check;
ALTER TABLE bets ADD CONSTRAINT bets_position_check
  CHECK (position IN ('yes', 'no', 'team_1', 'team_2'));

-- NOTE: existing Markets still use 'yes'/'no'. Battle-linked Arena markets use 'team_1'/'team_2'.
-- The resolve-markets edge function must branch on arena_matches.resolution_type.
-- See doc2_game_logic.md for the resolution logic changes.
```

---

## Migration 084 — Weekly Polls

File: `supabase/migrations/084_weekly_polls.sql`
(Full SQL in doc3_marketplace_polls.md — referenced here for migration ordering.)

Tables created: `weekly_polls`, `poll_options`, `poll_votes`, `poll_results`

---

## Migration 085 — Battle Chits System

File: `supabase/migrations/085_battle_chits.sql`

```sql
-- Chit definitions: the master catalog of all chit types.
-- Effects are applied in process_battle_turn() when a chit is activated.
-- Rarity tiers: common | uncommon | rare | epic | legendary | mythic

CREATE TABLE battle_chit_definitions (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                        TEXT NOT NULL UNIQUE,
  description                 TEXT NOT NULL,
  rarity                      TEXT NOT NULL CHECK (rarity IN (
    'common', 'uncommon', 'rare', 'epic', 'legendary', 'mythic'
  )),
  effect_type                 TEXT NOT NULL CHECK (effect_type IN (
    'stat_boost',        -- +N to a specific stat for this match
    'damage_shield',     -- block next X damage received
    'momentum_surge',    -- instantly gain +N momentum
    'counter',           -- reflect next ability back to attacker
    'type_override',     -- ignore type multiplier for this turn
    'speed_burst',       -- +N to speed for 2 turns
    'aura',              -- passive effect lasting full match
    'disruption',        -- remove one random opponent active effect
    'wild_card'          -- swap one team member mid-match (bypasses normal swap rules)
  )),
  effect_value                DECIMAL(10,4) NOT NULL DEFAULT 0,  -- magnitude of effect
  effect_target               TEXT NOT NULL DEFAULT 'self'
    CHECK (effect_target IN ('self', 'opponent', 'all')),
  effect_duration_turns       INTEGER,   -- NULL = instant, 0 = permanent for match
  stat_target                 TEXT CHECK (stat_target IN (
    'power','charisma','resilience','agility','wit','influence','all'
  )),

  -- Acquisition paths (can be true for multiple)
  can_earn_from_challenges    BOOLEAN NOT NULL DEFAULT TRUE,
  can_buy_in_marketplace      BOOLEAN NOT NULL DEFAULT FALSE,  -- only uncommon+
  can_earn_from_match_rng     BOOLEAN NOT NULL DEFAULT FALSE,  -- only rare+
  can_receive_as_gift         BOOLEAN NOT NULL DEFAULT FALSE,  -- only epic+

  -- RNG drop rates (from match wins)
  -- Probability a winning player receives this chit after a match
  -- NULL = not available via RNG
  rng_drop_rate               DECIMAL(6,5),  -- e.g. 0.05000 = 5%

  marketplace_price_tokens    INTEGER,       -- platform price to buy (NULL if not buyable)
  is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed initial chit catalog (add more as needed)
INSERT INTO battle_chit_definitions
  (name, description, rarity, effect_type, effect_value, effect_target,
   effect_duration_turns, stat_target, can_earn_from_challenges,
   can_buy_in_marketplace, can_earn_from_match_rng, can_receive_as_gift,
   rng_drop_rate, marketplace_price_tokens)
VALUES
  ('Bronze Shield', 'Block the next 20 damage received.', 'common', 'damage_shield', 20, 'self', NULL, NULL, TRUE, FALSE, FALSE, FALSE, NULL, 50),
  ('Silver Shield', 'Block the next 40 damage received.', 'uncommon', 'damage_shield', 40, 'self', NULL, NULL, TRUE, TRUE, FALSE, FALSE, NULL, 120),
  ('Power Surge', '+15 to Power stat for this match.', 'common', 'stat_boost', 15, 'self', 0, 'power', TRUE, FALSE, FALSE, FALSE, NULL, 60),
  ('Momentum Crystal', '+40 instant momentum.', 'uncommon', 'momentum_surge', 40, 'self', NULL, NULL, TRUE, TRUE, FALSE, FALSE, NULL, 100),
  ('Counter Stance', 'Reflect the next ability back to attacker.', 'rare', 'counter', 1, 'self', 1, NULL, FALSE, FALSE, TRUE, FALSE, 0.10000, 250),
  ('Speed Burst', '+30 to speed for 2 turns.', 'rare', 'speed_burst', 30, 'self', 2, NULL, FALSE, FALSE, TRUE, FALSE, 0.08000, 200),
  ('Charisma Aura', '+20% to all Charisma-based calculations for this match.', 'rare', 'aura', 1.20, 'self', 0, 'charisma', FALSE, FALSE, TRUE, FALSE, 0.07000, 220),
  ('Disruptor', 'Remove one random active effect from an opponent.', 'epic', 'disruption', 1, 'opponent', NULL, NULL, FALSE, FALSE, TRUE, FALSE, 0.03000, NULL),
  ('Type Breaker', 'Ignore type multiplier for your next attack.', 'epic', 'type_override', 1, 'self', 1, NULL, FALSE, FALSE, TRUE, FALSE, 0.02500, NULL),
  ('Wild Card', 'Swap any team member mid-match, bypassing normal swap rules.', 'legendary', 'wild_card', 1, 'self', NULL, NULL, FALSE, FALSE, TRUE, FALSE, 0.00500, NULL),
  ('NORA Aura', 'All stats +25 for the entire match. Passive.', 'mythic', 'aura', 1.50, 'self', 0, 'all', FALSE, FALSE, FALSE, TRUE, NULL, NULL);


-- User inventory
CREATE TABLE user_battle_chits (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chit_definition_id          UUID NOT NULL REFERENCES battle_chit_definitions(id),
  quantity                    INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  acquired_via                TEXT NOT NULL CHECK (acquired_via IN (
    'challenge_reward', 'match_rng', 'marketplace_purchase', 'gift', 'event'
  )),
  acquired_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, chit_definition_id)
);

-- Chit marketplace listings (separate tab from card marketplace)
CREATE TABLE chit_marketplace_listings (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_user_id              UUID NOT NULL REFERENCES auth.users(id),
  chit_definition_id          UUID NOT NULL REFERENCES battle_chit_definitions(id),
  quantity_listed             INTEGER NOT NULL DEFAULT 1 CHECK (quantity_listed > 0),
  price_per_unit_tokens       INTEGER NOT NULL CHECK (price_per_unit_tokens > 0),
  status                      TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'sold', 'cancelled')),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Track chit usage in battles
ALTER TABLE battle_events
  ADD COLUMN chit_id UUID REFERENCES battle_chit_definitions(id);
-- Null unless event_type = 'chit_used'
-- Add 'chit_used' to the battle_events.event_type CHECK constraint.

ALTER TABLE battle_events DROP CONSTRAINT IF EXISTS battle_events_event_type_check;
ALTER TABLE battle_events ADD CONSTRAINT battle_events_event_type_check
  CHECK (event_type IN (
    'swap_voluntary','swap_forced','ability_used','ultimate_used',
    'ko','momentum_gained','ultimate_ready','auto_selected','match_end','chit_used'
  ));
```

---

## Migration 086 — Celebrity Integration

File: `supabase/migrations/086_celebrity_integration.sql`

```sql
-- Pull the 25 Hot Topic celebs into the full market maker system.
-- Each celeb gets a system-managed profiles row.
-- They cannot log in. Their likeness offerings are managed by the platform.
-- Revenue earned by their character accumulates in celebs.managed_wallet_usd_cents
-- until the real person joins and claims it (future feature).

ALTER TABLE profiles
  ADD COLUMN is_celeb             BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN celeb_id             UUID REFERENCES celebs(id),
  ADD COLUMN managed_by_platform  BOOLEAN NOT NULL DEFAULT FALSE;
  -- managed_by_platform = TRUE: no login, platform controls offerings

ALTER TABLE celebs
  ADD COLUMN profile_id           UUID REFERENCES profiles(id),
  ADD COLUMN managed_wallet_usd_cents BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN is_integrated        BOOLEAN NOT NULL DEFAULT FALSE;

-- Create system profile rows for all 25 celebs
-- NOTE: Run this block manually or as a seeded migration.
-- For each celeb in the celebs table, create a corresponding profile.

DO $$
DECLARE
  v_celeb RECORD;
  v_new_profile_id UUID;
  v_system_user_id UUID;
BEGIN
  -- Create a deterministic UUID for each celeb profile
  -- using celeb.id as a seed so this is idempotent
  FOR v_celeb IN SELECT * FROM celebs WHERE is_integrated = FALSE LOOP
    v_new_profile_id := gen_random_uuid();

    -- Insert into auth.users (system user, no login)
    -- NOTE: In Supabase, creating auth users programmatically requires the service role.
    -- The edge function `celebrity-integration-seed` handles this — do not run raw SQL here.
    -- See edge function: supabase/functions/celebrity-integration-seed/index.ts

    -- Insert profile (will be wired to auth.users by the edge function)
    INSERT INTO profiles (
      id, username, bio, category, is_market_maker, pending_opt_out,
      is_celeb, celeb_id, managed_by_platform, is_test_account, is_approved
    ) VALUES (
      v_new_profile_id,
      lower(regexp_replace(v_celeb.name, '[^a-zA-Z0-9]', '_', 'g')),
      v_celeb.name || ' — managed character card',
      v_celeb.category,
      TRUE,  -- market makers
      FALSE,
      TRUE,
      v_celeb.id,
      TRUE,
      FALSE,
      TRUE
    ) ON CONFLICT DO NOTHING;

    UPDATE celebs
    SET profile_id = v_new_profile_id, is_integrated = TRUE
    WHERE id = v_celeb.id;

  END LOOP;
END;
$$;
```

---

## Migration 087 — Match Revenue Token Types

File: `supabase/migrations/087_match_revenue_tokens.sql`

```sql
-- Extend token_transactions type constraint to include new match reward types.
-- The distribute_match_revenue() function (see doc2_game_logic.md) writes these.

ALTER TABLE token_transactions DROP CONSTRAINT IF EXISTS token_transactions_type_check;
ALTER TABLE token_transactions ADD CONSTRAINT token_transactions_type_check
  CHECK (type IN (
    -- Existing types (do not remove any)
    'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost', 'refund',
    'promoted', 'referral_bonus', 'purchase', 'purchased',
    'challenge_reward', 'passive_bonus',
    'arena_back', 'arena_trigger', 'arena_win',
    -- New types added by this migration
    'card_purchase',          -- token payment for marketplace card (token-priced offerings only)
    'card_sale',              -- tokens received for selling a card
    'match_active_reward',    -- reward to owners who actively played in a won match
    'match_creator_reward',   -- reward to original market maker of characters in match
    'match_passive_reward',   -- reward to passive card holders for characters in match
    'chit_earn',              -- chit RNG drop converted to token equivalent (for ledger)
    'chit_purchase',          -- token purchase of a chit
    'chit_sale',              -- tokens received for selling a chit
    'poll_boost_applied'      -- stat boost applied from poll result (token record, amount=0)
  ));

-- Match revenue configuration (platform-level constants, stored for auditability)
CREATE TABLE match_revenue_config (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key                  TEXT NOT NULL UNIQUE,
  config_value                DECIMAL(6,4) NOT NULL,
  description                 TEXT,
  effective_from              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO match_revenue_config (config_key, config_value, description) VALUES
  ('winner_betters_pct',     0.7500, 'Winning betters share of Arena pool'),
  ('active_participants_pct',0.1000, 'Winning team owners/creators who played'),
  ('creator_pct',            0.0500, 'Original market makers of all chars in match, split equally'),
  ('passive_owners_pct',     0.0500, 'All card holders for chars in match, proportional to stake'),
  ('platform_pct',           0.0500, 'Platform fee (burned)');
```

---

## Migration 088 — Campaign Deprecation

File: `supabase/migrations/088_campaign_deprecation.sql`

```sql
-- Archive campaign tables. Do NOT drop them.
-- All FKs remain intact. Data is preserved for historical reference.

ALTER TABLE campaigns              RENAME TO campaigns_archived;
ALTER TABLE campaign_ownership_ledger RENAME TO campaigns_archived_ledger;
ALTER TABLE campaign_revenue_events   RENAME TO campaigns_archived_revenue;
ALTER TABLE campaign_distributions    RENAME TO campaigns_archived_distributions;
ALTER TABLE campaign_proposals        RENAME TO campaigns_archived_proposals;
ALTER TABLE campaign_votes            RENAME TO campaigns_archived_votes;
ALTER TABLE campaign_stake_listings   RENAME TO campaigns_archived_listings;
ALTER TABLE campaign_stake_sales      RENAME TO campaigns_archived_sales;
ALTER TABLE campaign_updates          RENAME TO campaigns_archived_updates;
ALTER TABLE campaign_unclaimed_balances RENAME TO campaigns_archived_unclaimed;

-- Mark all archived campaigns as closed
UPDATE campaigns_archived SET status = 'closed', closed_at = NOW()
WHERE status NOT IN ('closed', 'failed');

-- Drop the process_campaign_status_tick cron job
SELECT cron.unschedule('campaign-status-tick')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'campaign-status-tick'
);
SELECT cron.unschedule('governance-tick')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'governance-tick'
);
```

---

## Migration 089 — KYC Simplification

File: `supabase/migrations/089_kyc_simplification.sql`

```sql
-- Remove Reg CF-specific columns from kyc_verifications.
-- Keep identity verification (needed for live mode marketplace purchases).

ALTER TABLE kyc_verifications
  DROP COLUMN IF EXISTS annual_income_usd_cents,
  DROP COLUMN IF EXISTS net_worth_usd_cents,
  DROP COLUMN IF EXISTS is_accredited_investor,
  DROP COLUMN IF EXISTS reg_cf_invested_ytd_cents,
  DROP COLUMN IF EXISTS reg_cf_limit_year;
-- Keep: verified_legal_name, date_of_birth, identity_document_type,
-- pep_status, sanctions_screened_at, sanctions_result, trusted_contact_*
-- These are still needed for marketplace fraud prevention and AML.
```

---

## CLAUDE.md Updates Required

After applying all migrations, update CLAUDE.md:

1. Remove Hard Rule 21 and replace as specified at top of this document.
2. Add to **Games** section:
   ```
   - **Likeness Cards**: Collectible character cards. Owners field cards in Battle,
     share match rewards. Original creator always eligible to battle as themselves.
   ```
3. Add to **Queued** section: remove "Battle Chit collectible economy (post-launch)" and move to **Games** as active.
4. Update `docs/infra.md` with new edge functions (see doc2 and doc3).
5. Add new token types to the token type list in CLAUDE.md.
6. Add `sync-stat-sheets` (runs after sync-platform-metrics, every 5 min) to pg_cron table.

---

## RLS Notes

Apply row-level security to all new tables:
- `creator_stat_sheets`: public read, no direct write (SECURITY DEFINER functions only)
- `creator_stat_history`: public read, no direct write
- `likeness_offerings`: public read for status=active/sold_out; creator can CRUD their own
- `likeness_cards`: public read; write via SECURITY DEFINER RPCs only
- `likeness_card_transfers`: no direct RLS write; insert via RPCs only; read by owner/creator
- `card_marketplace_listings`: public read for status=active; seller can cancel own
- `card_marketplace_sales`: read by buyer/seller only
- `user_battle_chits`: user reads their own
- `chit_marketplace_listings`: public read for status=active
- `creator_stat_sheets`: public read (displayed on profile)
- `weekly_polls`: public read; write via edge function only
- `poll_votes`: insert via edge function only (anti-abuse enforced there); no direct user insert
