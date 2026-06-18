# NORA Redesign — Doc 2: Game Logic
# For Claude Code — Read in full before touching any file.
# Prerequisite: Apply migrations 079–089 from doc1_schema.md first.
# Companion docs: doc1_schema.md | doc3_marketplace_polls.md

---

## Overview of Changes

| System | Change |
|---|---|
| Stat Engine | New — `sync-stat-sheets` edge fn + `calculate_stat_sheets()` DB fn |
| Battle formats | 1v1 / 2v2 / 3v3 selectable; ownership gate on character selection |
| Battle damage | Now modified by stat sheet values (power, resilience, agility, wit) |
| Arena↔Battle | Arena auto-opens on `battle_start_match`; resolves on battle outcome |
| Arena resolution | Display Score path kept for legacy Markets; new battle_outcome path |
| Revenue distribution | New `distribute_match_revenue()` replaces Arena pool logic |
| Spotlight | Determined by cumulative Battle wins (not Round 3 bracket) |
| Monday rollover | Extended: apply poll stat modifiers + reset poll multipliers |

---

## 1. New Edge Function: sync-stat-sheets

File: `supabase/functions/sync-stat-sheets/index.ts`

This function is called at the end of every `sync-platform-metrics` execution.
Do NOT create a separate pg_cron job for it — call it inline from
`sync-platform-metrics` to keep stat sheets in sync with metric updates.

### Integration Point in sync-platform-metrics

At the end of `supabase/functions/sync-platform-metrics/index.ts`, after all
`platform_metrics` upserts complete, add:

```typescript
// Trigger stat sheet recalculation after metrics sync
const { error: statError } = await supabaseAdmin.rpc('calculate_stat_sheets');
if (statError) {
  console.error('[sync-stat-sheets] calculate_stat_sheets error:', statError);
  // Log and continue — never throw. Follows Hard Rule 8.
}
```

`calculate_stat_sheets()` is the PL/pgSQL function defined in migration 079.
It handles both regular market makers (from platform_metrics) and celebs
(from celeb_weekly_scores). No additional edge function file is needed.

---

## 2. Battle Format & Ownership Gate

### Modified RPC: battle_create_lobby

File: `supabase/functions/battle-tick-warmer/index.ts` — not relevant.
Modify the RPC directly in a new migration or add a wrapper function.

The `battle_create_lobby` RPC must:
1. Accept a `p_format TEXT` parameter (`'1v1' | '2v2' | '3v3'`).
2. Accept a `p_characters JSONB` parameter — array of character selections:
   ```json
   [
     { "creator_id": "uuid", "team": 1, "slot": 1 },
     { "creator_id": "uuid", "team": 1, "slot": 2 }
   ]
   ```
3. For each character in `p_characters`, call `check_battle_eligibility(auth.uid(), creator_id)`.
   If any character fails eligibility, raise an exception.
4. Insert into `battle_matches` with the selected format.
5. Insert `battle_participants` rows for the characters the host has selected.
   Set `likeness_card_id` to the card returned by `check_battle_eligibility`.

### Modified RPC: battle_join_lobby

When a user joins an existing lobby:
1. They must select a character from `get_eligible_characters(auth.uid())`.
2. Call `check_battle_eligibility` before inserting the participant.
3. Allow joining only if the match format has open slots.

Format slot counts:
- `'1v1'`: 1 participant per team (total 2)
- `'2v2'`: 2 participants per team (total 4)
- `'3v3'`: 3 participants per team (total 6) — existing behavior

### Solo Control of Multiple Slots

If a player chooses to control multiple characters on their team
(e.g., one person fills all 3 slots of team 1 in a 3v3):

- Insert multiple `battle_participants` rows with the same `user_id`.
- The Flutter UI should present separate action panels for each controlled character.
- `battle_turn_submissions` allows multiple rows for the same `user_id` in a turn
  (one per `participant_id`), so no schema change needed.
- The `battle_check_presence` cron already uses `last_seen_at` per participant —
  update all controlled participants when the user is active.

### Flutter UI: Battle Lobby Screen

In `battle_lobby_screen.dart` (create or modify existing), add:

1. **Format selector** (shown to host only):
   - Three buttons: 1v1 / 2v2 / 3v3
   - Default: 3v3 (existing behavior)

2. **Character selector** (shown to host and each joining user):
   - Calls `get_eligible_characters(user_id)` via a FutureProvider.
   - Displays a grid of eligible characters with stat sheets visible.
   - If only one eligible character (owns no cards and isn't a market maker),
     auto-selects and disables the picker.

3. **Team slot assignment**:
   - After format selection, show team slots (e.g., Team 1: [?][?][?], Team 2: [?][?][?]).
   - Host fills their team slots; invites others to fill remaining slots via lobby code.
   - Host can toggle "Control myself" on any unfilled slot to claim multiple characters.

4. **Invite flow**:
   - Existing lobby code sharing mechanism — no change.
   - Joining users see the same character selector for their assigned slot.

---

## 3. Stat Modifiers in Battle

### Modified: process_battle_turn()

File: PL/pgSQL procedure (migration 067+070 applied it).

Add a stat snapshot lookup at the start of `process_battle_turn(match_id)`:

```sql
-- At the start of process_battle_turn, fetch stat sheets for all participants
-- in this match. Store in local variables for use in the damage formula.

-- Get stat snapshots from battle_participants.creator_id → creator_stat_sheets
-- These were snapshotted into the participant row at match start (see below).
-- Do NOT live-query creator_stat_sheets inside the tick loop — use the snapshot.
```

### Snapshot Stats at Match Start

In `battle_start_match()`, after inserting `battle_participants`, snapshot
the effective stats into the participant row:

```sql
ALTER TABLE battle_participants
  ADD COLUMN snap_power      INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_charisma   INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_resilience INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_agility    INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_wit        INTEGER NOT NULL DEFAULT 50,
  ADD COLUMN snap_influence  INTEGER NOT NULL DEFAULT 50;
```

In `battle_start_match()`:
```sql
UPDATE battle_participants bp
SET
  snap_power      = COALESCE(css.effective_power, 50),
  snap_charisma   = COALESCE(css.effective_charisma, 50),
  snap_resilience = COALESCE(css.effective_resilience, 50),
  snap_agility    = COALESCE(css.effective_agility, 50),
  snap_wit        = COALESCE(css.effective_wit, 50),
  snap_influence  = COALESCE(css.effective_influence, 50),
  speed = bp.speed  -- existing column; recalculate below
FROM creator_stat_sheets css
WHERE css.user_id = bp.creator_id
  AND bp.match_id = p_match_id;

-- Recalculate speed from snap_agility
-- base_speed comes from battle_abilities or archetype default
UPDATE battle_participants
SET speed = ROUND(
  base_archetype_speed(archetype)  -- new helper function, see below
  * (0.8 + (snap_agility::float / 300.0) * 0.4)
)
WHERE match_id = p_match_id;
```

### New Helper: base_archetype_speed(archetype)

```sql
CREATE OR REPLACE FUNCTION base_archetype_speed(p_archetype TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_archetype
    WHEN 'athlete'    THEN 90
    WHEN 'gamer'      THEN 85
    WHEN 'influencer' THEN 75
    WHEN 'actor'      THEN 70
    WHEN 'comedian'   THEN 65
    WHEN 'musician'   THEN 60
    WHEN 'artist'     THEN 55
    WHEN 'scientist'  THEN 50
    WHEN 'business'   THEN 45
    WHEN 'politician' THEN 40
    ELSE 50
  END;
$$;
```

### Modified Damage Formula in process_battle_turn()

The existing formula:
```
damage = base_damage × type_multiplier × map_multiplier
```

New formula:
```sql
-- power_mod: +/- 20% range based on attacker's snap_power (baseline 50 = 1.0x)
power_mod := 1.0 + (attacker.snap_power - 50.0) / 250.0;  -- 50→1.0, 100→1.2, 0→0.8

-- wit_mod: ability effectiveness (higher wit = abilities cost less, hit harder)
wit_mod := 1.0 + (attacker.snap_wit - 50.0) / 500.0;       -- 50→1.0, 100→1.1

-- resilience_reduction: damage received reduction (max 30% at stat=150)
resilience_reduction := defender.snap_resilience::float / 500.0;  -- max 0.30

-- New effective damage
v_damage := ROUND(
  base_damage
  * type_multiplier
  * map_multiplier
  * power_mod
  * wit_mod
  * (1.0 - resilience_reduction)
);
```

### Modified Arena HeatInfluence

In the Arena tick (process_arena_tick), the `heat_influence` component already reads
`platform_metrics.heat_score`. Now multiply by the charisma modifier:

```sql
-- Existing:
heat_influence_p1 := (SELECT heat_score FROM platform_metrics WHERE user_id = p1_id LIMIT 1) * 0.5;

-- New:
heat_influence_p1 := (SELECT heat_score FROM platform_metrics WHERE user_id = p1_id LIMIT 1)
  * 0.5
  * (0.8 + (SELECT COALESCE(effective_charisma, 50)::float FROM creator_stat_sheets WHERE user_id = p1_id) / 300.0 * 0.4);
```

### Modified Momentum Gain Rate in Arena

```sql
-- Existing influence_multiplier applied to momentum gain
-- In arena_state active_effects processing, when adding momentum events:
momentum_gain := base_momentum_gain
  * (0.8 + effective_influence::float / 300.0 * 0.4);
```

---

## 4. Arena↔Battle Integration

### Modified RPC: battle_start_match()

After the existing `battle_start_match` logic (select map, update status), add:

```sql
-- Auto-create a linked Arena prediction market
DECLARE
  v_arena_market_id UUID;
  v_match_title TEXT;
BEGIN
  -- Build the market title from team archetypes
  SELECT 'Battle: ' || p1.character_name || ' vs ' || p2.character_name
  INTO v_match_title
  FROM battle_participants p1, battle_participants p2
  WHERE p1.match_id = p_match_id AND p1.team_number = 1 AND p1.slot_position = 1
    AND p2.match_id = p_match_id AND p2.team_number = 2 AND p2.slot_position = 1;

  INSERT INTO markets (
    -- Use the first team's primary character as the "creator" (for display)
    creator_id,
    opened_by,
    title,
    status,
    opening_resolution_score,
    yes_pool,
    no_pool,
    end_at,
    -- New columns from migration 083:
    resolution_type,
    battle_match_id
  )
  SELECT
    bp.creator_id,              -- primary character creator
    p_initiating_user_id,       -- the user who started the match
    v_match_title,
    'open',
    0,                          -- no display_score resolution; 0 placeholder
    0,
    0,
    NOW() + INTERVAL '10 minutes',  -- Arena closes shortly after battle ends
    'battle_outcome',
    p_match_id
  FROM battle_participants bp
  WHERE bp.match_id = p_match_id AND bp.team_number = 1 AND bp.slot_position = 1
  RETURNING id INTO v_arena_market_id;

  -- NOTE: position 'yes' = team_1 wins, position 'no' = team_2 wins
  -- The Flutter Arena UI labels these 'Team 1' and 'Team 2' respectively.
  -- bets.position accepts 'team_1' and 'team_2' after migration 083.
  -- Update the market INSERT above to use the new labels if preferred,
  -- or keep 'yes'/'no' mapped to teams at the UI layer.
END;
```

### Modified: resolve-markets Edge Function

File: `supabase/functions/resolve-markets/index.ts`

The existing function resolves markets by comparing Display Score. Add a branch
for `resolution_type = 'battle_outcome'`:

```typescript
// In the main resolution loop, after fetching markets to resolve:
for (const market of marketsToResolve) {
  if (market.resolution_type === 'battle_outcome') {
    await resolveBattleOutcomeMarket(market, supabaseAdmin);
  } else {
    // Existing display_score resolution path — no changes
    await resolveDisplayScoreMarket(market, supabaseAdmin);
  }
}

async function resolveBattleOutcomeMarket(market: Market, supabase: SupabaseClient) {
  // Fetch the linked battle match
  const { data: battleMatch } = await supabase
    .from('battle_matches')
    .select('status, winner_team_number')
    .eq('id', market.battle_match_id)
    .single();

  if (!battleMatch || battleMatch.status !== 'resolved') {
    // Battle not yet resolved — skip this market for now.
    // extend market.end_at by 5 minutes to avoid premature resolution.
    await supabase.from('markets')
      .update({ end_at: new Date(Date.now() + 5 * 60 * 1000).toISOString() })
      .eq('id', market.id);
    return;
  }

  // Determine winning position based on winner_team_number
  // team_1 win → 'team_1' bets win; team_2 win → 'team_2' bets win
  const winningPosition = battleMatch.winner_team_number === 1 ? 'team_1' : 'team_2';
  const losingPosition  = battleMatch.winner_team_number === 1 ? 'team_2' : 'team_1';

  // Call distribute_match_revenue() — replaces the legacy pool split
  const { error } = await supabase.rpc('distribute_match_revenue', {
    p_market_id: market.id,
    p_battle_match_id: market.battle_match_id,
    p_winning_position: winningPosition,
    p_losing_position: losingPosition,
  });

  if (error) {
    console.error('[resolve-markets] distribute_match_revenue error:', error);
    return;
  }

  // Mark market resolved
  await supabase.from('markets').update({
    status: 'resolved',
    resolution_result: winningPosition,
    resolved_at: new Date().toISOString(),
  }).eq('id', market.id);
}
```

---

## 5. Revenue Distribution

### New Function: distribute_match_revenue()

File: Add to a new migration or `087_match_revenue_tokens.sql` (from doc1).

```sql
-- Distributes the Arena pool for a battle-linked market using Option B split:
--   75% → winning betters (proportional to bet amount)
--   10% → active participants on winning team (equal split)
--    5% → original market makers of ALL chars in match (equal split per creator)
--    5% → passive card holders for ALL chars in match (proportional to royalty_pct)
--    5% → platform (burned)

CREATE OR REPLACE FUNCTION distribute_match_revenue(
  p_market_id      UUID,
  p_battle_match_id UUID,
  p_winning_position TEXT,
  p_losing_position  TEXT
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_market            markets%ROWTYPE;
  v_total_pool        BIGINT;
  v_losing_pool       BIGINT;
  v_winner_pool       BIGINT;
  v_active_pool       BIGINT;
  v_creator_pool      BIGINT;
  v_passive_pool      BIGINT;
  v_platform_pool     BIGINT;

  v_config            RECORD;
  v_winner_betters    RECORD;
  v_total_winning_bet BIGINT;
  v_payout            BIGINT;

  v_active_participants  INT;
  v_active_payout_each   BIGINT;

  v_unique_creators      INT;
  v_creator_payout_each  BIGINT;

  v_total_royalty_pct    DECIMAL(10,6);
  v_card_holder          RECORD;
  v_passive_payout       BIGINT;
BEGIN
  -- Fetch market
  SELECT * INTO v_market FROM markets WHERE id = p_market_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found: %', p_market_id; END IF;

  -- Load revenue config
  SELECT
    (SELECT config_value FROM match_revenue_config WHERE config_key = 'winner_betters_pct')    AS betters_pct,
    (SELECT config_value FROM match_revenue_config WHERE config_key = 'active_participants_pct') AS active_pct,
    (SELECT config_value FROM match_revenue_config WHERE config_key = 'creator_pct')            AS creator_pct,
    (SELECT config_value FROM match_revenue_config WHERE config_key = 'passive_owners_pct')     AS passive_pct,
    (SELECT config_value FROM match_revenue_config WHERE config_key = 'platform_pct')           AS platform_pct
  INTO v_config;

  -- Total pool = yes_pool + no_pool (all bets placed)
  v_total_pool  := v_market.yes_pool + v_market.no_pool;
  v_losing_pool := CASE p_losing_position
    WHEN 'team_2' THEN v_market.no_pool
    WHEN 'team_1' THEN v_market.yes_pool
    ELSE v_market.no_pool
  END;

  -- If no losing pool, nothing to distribute (voided)
  IF v_losing_pool = 0 THEN
    UPDATE markets SET status = 'voided', resolved_at = NOW() WHERE id = p_market_id;
    UPDATE bets SET status = 'refunded' WHERE market_id = p_market_id;
    RETURN;
  END IF;

  -- Calculate pool slices from the TOTAL pool (all funds in play)
  v_winner_pool  := ROUND(v_total_pool * v_config.betters_pct);
  v_active_pool  := ROUND(v_total_pool * v_config.active_pct);
  v_creator_pool := ROUND(v_total_pool * v_config.creator_pct);
  v_passive_pool := ROUND(v_total_pool * v_config.passive_pct);
  v_platform_pool:= v_total_pool - v_winner_pool - v_active_pool - v_creator_pool - v_passive_pool;

  -- ── PART 1: Winning betters (proportional) ──
  SELECT SUM(amount) INTO v_total_winning_bet
  FROM bets
  WHERE market_id = p_market_id AND position = p_winning_position AND status = 'active';

  IF v_total_winning_bet > 0 THEN
    FOR v_winner_betters IN
      SELECT b.user_id, b.amount, b.id AS bet_id
      FROM bets b
      WHERE b.market_id = p_market_id
        AND b.position = p_winning_position
        AND b.status = 'active'
    LOOP
      v_payout := ROUND(
        v_winner_pool::float * v_winner_betters.amount::float / v_total_winning_bet::float
      ) + v_winner_betters.amount;  -- return original bet + winnings

      PERFORM increment_token_balance(v_winner_betters.user_id, v_payout);
      INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
      VALUES (v_winner_betters.user_id, 'bet_won', v_payout, p_market_id, 'Battle prediction win');

      UPDATE bets SET status = 'won', settled_at = NOW() WHERE id = v_winner_betters.bet_id;
    END LOOP;
  END IF;

  -- Mark losing bets
  UPDATE bets SET status = 'lost', settled_at = NOW()
  WHERE market_id = p_market_id AND position = p_losing_position AND status = 'active';

  -- ── PART 2: Active battle participants (winning team, equal split) ──
  SELECT COUNT(DISTINCT COALESCE(bts.user_id, bp.user_id))
  INTO v_active_participants
  FROM battle_participants bp
  LEFT JOIN (
    SELECT DISTINCT participant_id, user_id
    FROM battle_turn_submissions
    WHERE match_id = p_battle_match_id
  ) bts ON bts.participant_id = bp.id
  WHERE bp.match_id = p_battle_match_id AND bp.team_number = (
    CASE p_winning_position WHEN 'team_1' THEN 1 ELSE 2 END
  );

  IF v_active_participants > 0 THEN
    v_active_payout_each := ROUND(v_active_pool::float / v_active_participants::float);

    FOR v_winner_betters IN
      SELECT DISTINCT COALESCE(bts.user_id, bp.user_id) AS player_user_id
      FROM battle_participants bp
      LEFT JOIN (
        SELECT DISTINCT participant_id, user_id
        FROM battle_turn_submissions
        WHERE match_id = p_battle_match_id
      ) bts ON bts.participant_id = bp.id
      WHERE bp.match_id = p_battle_match_id AND bp.team_number = (
        CASE p_winning_position WHEN 'team_1' THEN 1 ELSE 2 END
      )
    LOOP
      PERFORM increment_token_balance(v_winner_betters.player_user_id, v_active_payout_each);
      INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
      VALUES (v_winner_betters.player_user_id, 'match_active_reward', v_active_payout_each, p_market_id, 'Battle win reward');
    END LOOP;
  END IF;

  -- ── PART 3: Original market makers of ALL characters in this match (equal split) ──
  SELECT COUNT(DISTINCT bp.creator_id)
  INTO v_unique_creators
  FROM battle_participants bp
  WHERE bp.match_id = p_battle_match_id;

  IF v_unique_creators > 0 THEN
    v_creator_payout_each := ROUND(v_creator_pool::float / v_unique_creators::float);

    FOR v_winner_betters IN
      SELECT DISTINCT bp.creator_id AS creator_user_id
      FROM battle_participants bp
      WHERE bp.match_id = p_battle_match_id
    LOOP
      -- Check if this creator has a managed wallet (is_celeb)
      IF EXISTS (
        SELECT 1 FROM profiles WHERE id = v_winner_betters.creator_user_id AND managed_by_platform = TRUE
      ) THEN
        -- Credit to celeb's managed wallet instead of token_balances
        UPDATE celebs SET managed_wallet_usd_cents = managed_wallet_usd_cents + v_creator_payout_each
        WHERE profile_id = v_winner_betters.creator_user_id;
      ELSE
        PERFORM increment_token_balance(v_winner_betters.creator_user_id, v_creator_payout_each);
        INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
        VALUES (v_winner_betters.creator_user_id, 'match_creator_reward', v_creator_payout_each, p_market_id, 'Character in battle reward');
      END IF;
    END LOOP;
  END IF;

  -- ── PART 4: Passive card holders for ALL characters in this match ──
  -- All card holders (regardless of which team won) share the passive pool
  -- proportional to their royalty_pct stake for the character in play.

  SELECT COALESCE(SUM(lc.royalty_pct), 0)
  INTO v_total_royalty_pct
  FROM battle_participants bp
  JOIN likeness_cards lc ON lc.creator_id = bp.creator_id
  WHERE bp.match_id = p_battle_match_id
    AND lc.is_active = TRUE;

  IF v_total_royalty_pct > 0 THEN
    FOR v_card_holder IN
      SELECT
        lc.current_owner_id AS owner_user_id,
        SUM(lc.royalty_pct) AS total_stake
      FROM battle_participants bp
      JOIN likeness_cards lc ON lc.creator_id = bp.creator_id
      WHERE bp.match_id = p_battle_match_id AND lc.is_active = TRUE
      GROUP BY lc.current_owner_id
    LOOP
      v_passive_payout := ROUND(
        v_passive_pool::float
        * v_card_holder.total_stake::float
        / v_total_royalty_pct::float
      );

      IF v_passive_payout > 0 THEN
        PERFORM increment_token_balance(v_card_holder.owner_user_id, v_passive_payout);
        INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
        VALUES (v_card_holder.owner_user_id, 'match_passive_reward', v_passive_payout, p_market_id, 'Card holder match reward');
      END IF;
    END LOOP;
  END IF;

  -- Platform pool is burned (not credited to any account).
  -- Log for auditing.
  INSERT INTO token_transactions (user_id, type, amount, reference_id, description)
  VALUES (
    (SELECT id FROM profiles WHERE username = 'platform' LIMIT 1),  -- platform audit account
    'platform_fee', v_platform_pool, p_market_id, 'Battle market platform fee'
  ) ON CONFLICT DO NOTHING;

END;
$$;
```

---

## 6. Battle Chit Usage in process_battle_turn()

### When a Chit is Activated

Add a new RPC `battle_use_chit(match_id, participant_id, chit_definition_id)`:

```sql
CREATE OR REPLACE FUNCTION battle_use_chit(
  p_match_id          UUID,
  p_participant_id    UUID,
  p_chit_def_id       UUID
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_chit  battle_chit_definitions%ROWTYPE;
  v_user_id UUID;
BEGIN
  SELECT user_id INTO v_user_id FROM battle_participants
  WHERE id = p_participant_id AND match_id = p_match_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Participant not found'; END IF;
  IF v_user_id != auth.uid() THEN RAISE EXCEPTION 'Not your participant'; END IF;

  SELECT * INTO v_chit FROM battle_chit_definitions WHERE id = p_chit_def_id AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chit not found'; END IF;

  -- Check inventory
  UPDATE user_battle_chits
  SET quantity = quantity - 1
  WHERE user_id = v_user_id AND chit_definition_id = p_chit_def_id AND quantity > 0;
  IF NOT FOUND THEN RAISE EXCEPTION 'No chits of this type in inventory'; END IF;

  -- Apply effect to arena_state.active_effects (same pattern as arena_trigger)
  -- Chit effects are processed by process_battle_turn on the next tick.
  UPDATE arena_state
  SET active_effects = active_effects || jsonb_build_object(
    'effect_id', gen_random_uuid()::text,
    'chit_id', p_chit_def_id::text,
    'source', 'chit',
    'participant_id', p_participant_id::text,
    'effect_type', v_chit.effect_type,
    'value', v_chit.effect_value,
    'target', v_chit.effect_target,
    'stat_target', v_chit.stat_target,
    'duration_turns', v_chit.effect_duration_turns,
    'applied_at_turn', (SELECT current_turn FROM battle_matches WHERE id = p_match_id)
  )
  WHERE match_id = p_match_id;

  -- Log the event
  INSERT INTO battle_events (
    match_id, turn_number, sequence_in_turn,
    event_type, actor_participant_id, chit_id, animation_key
  )
  SELECT
    p_match_id,
    current_turn,
    999,  -- high sequence = processed last in turn display
    'chit_used',
    p_participant_id,
    p_chit_def_id,
    v_chit.effect_type || '_chit'
  FROM battle_matches WHERE id = p_match_id;

END;
$$;
```

### RNG Chit Drop on Match Win

At the end of `process_battle_turn()` when a match resolves, add:

```sql
-- For each winning team participant, roll RNG for chit drops
FOR v_winner IN
  SELECT DISTINCT COALESCE(bts.user_id, bp.user_id) AS winner_user_id
  FROM battle_participants bp
  LEFT JOIN battle_turn_submissions bts ON bts.participant_id = bp.id AND bts.match_id = p_match_id
  WHERE bp.match_id = p_match_id AND bp.team_number = v_winning_team
LOOP
  -- Roll against each RNG-eligible chit
  FOR v_chit IN
    SELECT * FROM battle_chit_definitions
    WHERE can_earn_from_match_rng = TRUE
      AND rng_drop_rate IS NOT NULL
      AND is_active = TRUE
    ORDER BY rarity DESC  -- rare drops checked first
  LOOP
    IF random() < v_chit.rng_drop_rate THEN
      INSERT INTO user_battle_chits (user_id, chit_definition_id, quantity, acquired_via)
      VALUES (v_winner.winner_user_id, v_chit.id, 1, 'match_rng')
      ON CONFLICT (user_id, chit_definition_id)
        DO UPDATE SET quantity = user_battle_chits.quantity + 1;

      -- Only drop one chit per winner per match (break after first hit)
      EXIT;
    END IF;
  END LOOP;
END LOOP;
```

---

## 7. Spotlight Update

### From Round 3 Bracket → Battle Win Leaderboard

The existing `compute-spotlight` edge function populates `Arena Champions` from
`arena_spotlight_assignments` (set by `arena_monday_rollover`).

**Change:** `arena_monday_rollover` should now determine the Arena Champions
slot from cumulative Battle wins this week, not Round 3 bracket results.

In `arena_monday_rollover()`:

```sql
-- Find top 5 market makers by battle wins this week
INSERT INTO arena_spotlight_assignments (week_start, slot_1_user_id, slot_2_user_id,
  slot_3_user_id, slot_4_user_id, slot_5_user_id)
SELECT
  DATE_TRUNC('week', NOW()),
  MAX(CASE WHEN rn = 1 THEN creator_id END),
  MAX(CASE WHEN rn = 2 THEN creator_id END),
  MAX(CASE WHEN rn = 3 THEN creator_id END),
  MAX(CASE WHEN rn = 4 THEN creator_id END),
  MAX(CASE WHEN rn = 5 THEN creator_id END)
FROM (
  SELECT
    bp.creator_id,
    ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) AS rn
  FROM battle_participants bp
  JOIN battle_matches bm ON bm.id = bp.match_id
  WHERE bm.status = 'resolved'
    AND bm.started_at >= DATE_TRUNC('week', NOW()) - INTERVAL '7 days'
    AND bp.team_number = bm.winner_team_number  -- only count wins
  GROUP BY bp.creator_id
  HAVING COUNT(*) > 0
) ranked
WHERE rn <= 5
ON CONFLICT (week_start) DO UPDATE SET
  slot_1_user_id = EXCLUDED.slot_1_user_id,
  slot_2_user_id = EXCLUDED.slot_2_user_id,
  slot_3_user_id = EXCLUDED.slot_3_user_id,
  slot_4_user_id = EXCLUDED.slot_4_user_id,
  slot_5_user_id = EXCLUDED.slot_5_user_id;
```

**Poll Winners strip**: The `compute-spotlight` edge function should also return a
`poll_winners` array (top 5 from the most recently closed weekly poll).
In Flutter, `dualSpotlightProvider` should expose this as a third list:
`champions`, `top_movers`, and `poll_winners`. Display `poll_winners` adjacent
to the spotlight on the home screen. See doc3 for poll data structure.

---

## 8. Monday Rollover — Poll Modifier Application

In `arena_monday_rollover()`, after existing heat/momentum resets, add:

```sql
-- Apply weekly poll results to stat sheets
PERFORM process_poll_results();
-- (defined in doc3 — migration 084)

-- Reset weekly poll multipliers for everyone
-- (new multipliers will be applied by process_poll_results for the new week)
UPDATE creator_stat_sheets
SET weekly_poll_multiplier = 1.000,
    weekly_poll_rank = NULL,
    last_poll_applied_at = NULL;

-- Recalculate effective stats after multiplier reset
UPDATE creator_stat_sheets SET
  effective_power      = stat_power,
  effective_charisma   = stat_charisma,
  effective_resilience = stat_resilience,
  effective_agility    = stat_agility,
  effective_wit        = stat_wit,
  effective_influence  = stat_influence;
```

---

## 9. Flutter Provider Updates

### New Providers to Create

```dart
// In features/battle/providers/battle_providers.dart

// Returns characters the current user can field in Battle
final eligibleCharactersProvider = FutureProvider.autoDispose<List<EligibleCharacter>>((ref) async {
  final supabase = Supabase.instance.client;
  final userId = supabase.auth.currentUser?.id;
  if (userId == null) return [];
  
  final response = await supabase.rpc('get_eligible_characters', params: {'p_user_id': userId});
  return (response as List).map((e) => EligibleCharacter.fromJson(e)).toList();
});

// Stat sheet for a specific creator (public profile display)
final creatorStatSheetProvider = FutureProvider.autoDispose.family<StatSheet?, String>((ref, userId) async {
  final response = await Supabase.instance.client
    .from('creator_stat_sheets')
    .select()
    .eq('user_id', userId)
    .maybeSingle();
  return response != null ? StatSheet.fromJson(response) : null;
});

// Arena market linked to a specific battle match
final battleArenaMarketProvider = FutureProvider.autoDispose.family<Market?, String>((ref, battleMatchId) async {
  final response = await Supabase.instance.client
    .from('markets')
    .select()
    .eq('battle_match_id', battleMatchId)
    .maybeSingle();
  return response != null ? Market.fromJson(response) : null;
});
```

### Modified Providers

- `dualSpotlightProvider`: extend to also fetch `poll_winners` from the
  most recently closed `weekly_polls` result. The provider currently calls
  `compute-spotlight` — extend that edge function's response to include
  `poll_winners: List<userId>`.

- `arenaMatchProvider`: the Arena match detail screen should detect when
  `resolution_type = 'battle_outcome'` and:
  - Replace "YES / NO" bet labels with "TEAM 1 / TEAM 2"
  - Show live Battle scoreboard in a panel below the Arena prediction pool bars
  - Subscribe to `battle_events` Realtime stream for the linked `battle_match_id`

### New Flutter Models

Create `lib/models/stat_sheet.dart`:
```dart
class StatSheet {
  final String userId;
  final int statPower;
  final int statCharisma;
  final int statResilience;
  final int statAgility;
  final int statWit;
  final int statInfluence;
  final int effectivePower;
  final int effectiveCharisma;
  final int effectiveResilience;
  final int effectiveAgility;
  final int effectiveWit;
  final int effectiveInfluence;
  final double weeklyPollMultiplier;
  final int? weeklyPollRank;
  final DateTime calculatedAt;

  // Computed: overall rating (average of effective stats, 0–150 scale)
  int get overallRating =>
    (effectivePower + effectiveCharisma + effectiveResilience +
     effectiveAgility + effectiveWit + effectiveInfluence) ~/ 6;
}
```

Create `lib/models/eligible_character.dart`:
```dart
class EligibleCharacter {
  final String creatorId;
  final String characterName;
  final String archetype;
  final String? characterImageUrl;
  final String eligibilityType;  // 'self' | 'owner'
  final String? cardId;
  final int? cardNumber;
  final String? rarity;
  final StatSheet stats;
}
```

---

## 10. New Routes

Add to the GoRouter configuration in `lib/router.dart`:

```dart
GoRoute(path: '/marketplace',
  builder: (_, __) => const MarketplaceScreen()),  // doc3
GoRoute(path: '/marketplace/card/:cardId',
  builder: (_, state) => CardDetailScreen(cardId: state.pathParameters['cardId']!)),
GoRoute(path: '/marketplace/offering/:offeringId',
  builder: (_, state) => OfferingDetailScreen(offeringId: state.pathParameters['offeringId']!)),
GoRoute(path: '/poll/:pollId',
  builder: (_, state) => PollScreen(pollId: state.pathParameters['pollId']!)),  // public
GoRoute(path: '/poll/:pollId/embed',
  builder: (_, state) => PollEmbedScreen(pollId: state.pathParameters['pollId']!)),  // public
```

Add `/marketplace` and `/poll/:pollId` to the router as public routes
(no auth redirect). Add to `docs/infra.md` routing table.

---

## 11. New Edge Functions Required

Add these to `docs/infra.md`:

```
### Likeness & Cards
likeness-create-offering     — creator submits an offering for their character card
likeness-purchase-card       — calls likeness_mint_card RPC; Stripe for live mode
likeness-list-card           — creates a card_marketplace_listing
likeness-buy-listed-card     — calls card_marketplace_purchase RPC
celebrity-integration-seed   — one-time: creates system auth users for 25 celebs (admin only)

### Chits
chit-marketplace-list        — creates a chit_marketplace_listing
chit-marketplace-buy         — processes chit purchase from marketplace
```

All deployed `--no-verify-jwt`. All follow Hard Rule 8 (log 429s, never throw).
