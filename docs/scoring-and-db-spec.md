# NORA Platforms — Scoring & Database Engineering Spec
# Last updated: 2026-05-23

This document maps every scoring mechanism to its database tables, edge
functions, and RPC functions. It covers all three games and the celebrity
infrastructure, notes what is and isn't connected, and records known gaps.

---

## Score Hierarchy (quick reference)

| Score | Table.Column | Written By | Consumer |
|---|---|---|---|
| Display Score | `platform_metrics.display_score` | `sync-platform-metrics` only | Markets resolution, Top Movers |
| Heat Score | `platform_metrics.heat_score` | `sync-platform-metrics` (boost sum) + Monday rollover reset | Arena HeatInfluence, UI heat badge |
| Momentum Score | `platform_metrics.momentum_score` | Arena tick on match resolution | Arena MomentumCarry, Monday decay |
| Arena Rating | `platform_metrics.arena_rating` | Arena tick on Round 2 resolution | Round 2 matchmaker pairing |
| ArenaScore | `arena_state.score_p1/p2` | `process_arena_tick()` tick loop | Live match display only — never persisted |
| Arena Weekly Points | `arena_weekly_points.points` | Arena tick on match resolution | Round 3 bracket seeding |
| Buzz Score | `celeb_weekly_scores.points` | `hot-topic-fetch-and-score` | Hot Topic leaderboard, bet resolution |
| Composite Display Score | `score_history.composite_score` | `sync-platform-metrics` (sum of all `platform_metrics.display_score` for user) | Markets snapshot, Top Movers delta |

`resolution_score` was dropped in migration 019. `display_score` is the single
resolution metric for Markets.

---

## Game 1 — Markets

### Scoring Formula

Markets bet on whether a creator's composite Display Score goes up or down
between market open and market close.

**Display Score per platform:**
- YouTube / Twitch: `followers×1 + live_viewers×10 + 24h_growth×5`
- X (Twitter): `followers×1 + live_viewers×10 + post_views×0.1 + post_reposts×3 + post_likes×1`
- Spotify: `followers×1 + savedTracks×3 + savedAlbums×3`

**Composite Display Score** = `SUM(display_score)` across all `platform_metrics`
rows for a user (additive across platforms).

**Resolution logic:**
- `current > opening` → `above` → yes-position bettors win
- `current < opening` → `below` → no-position bettors win
- `current == opening` OR missing metrics → `refund`
- No bets on winning side → `refund`
- No bets at all → `voided`

**Pool split (applied to the losing pool):**
- 90% → distributed proportionally to winning bettors
- 5% → Market Maker (`markets.opened_by`)
- 5% → platform (burned, not credited)

### Database Tables

```
platform_connections (user_id, platform, access_token, platform_user_id)
       ↓ written by sync-platform-metrics
platform_metrics (user_id, platform, display_score, heat_score,
                  momentum_score, arena_rating, follower_count,
                  live_viewer_count, previous_follower_count, fetched_at)
       ↓ summed into
score_history (user_id, composite_score, recorded_at)

markets (id, creator_id, opened_by, title, status,
         opening_resolution_score,  ← snapshot at INSERT via trigger
         opening_heat_score,
         yes_pool, no_pool, end_at,
         resolution_result, resolved_at,
         platform_fee_collected, market_maker_fee_collected)
       ↑ bet pool totals updated by trigger on_bet_inserted_update_pools
       
bets (id, user_id, market_id, position [yes|no], amount, status,
      settled_at)

token_balances (user_id, available_tokens, lifetime_spent)
token_transactions (user_id, type, amount, reference_id, description)
  valid types: signup_bonus | bet_placed | bet_won | bet_lost | refund
               promoted | referral_bonus | purchase | purchased
               challenge_reward | passive_bonus
               arena_back | arena_trigger | arena_win
```

### Data Flow

```
1. OAuth connect → oauth-callback → sync-platform-metrics (user_id scoped)
                                          ↓
                                  platform_metrics upserted
                                  score_history inserted

2. User opens market on creator →
   INSERT bets → trigger: deduct tokens, update pool sizes
   INSERT markets → trigger: snapshot_scores_on_market_open()
                             reads SUM(display_score) → opening_resolution_score

3. pg_cron (every 5min) → sync-platform-metrics (all connections)
   pg_cron (every 15min) → resolve-markets edge function
                           → reads current SUM(display_score)
                           → compares to opening_resolution_score
                           → distributes winnings, sends notifications
                           → fires evaluate-challenges for bet_won/bet_lost events
```

### Passive Effects Hook
`resolve-markets` reads `user_passive_effects.token_earn_rate` and applies
a bonus on top of normal payout. This view is populated by the badge/challenge
system (migration 017–018).

---

## Game 2 — Arena

### Scoring Formula (in-memory ArenaScore)

ArenaScore is ephemeral — lives only in `arena_state` during the match.
Never written to `display_score`, `heat_score`, or any permanent column.

**Each tick:**
```
score_p1 += (flow_rate_p1 × trigger_flow_mult_p1 × passive_flow_mult_p1 × opp_eff_p1)
           + (heat_influence_p1 × trigger_heat_mult_p1 × passive_heat_mult_p1)
           - suppression_p1
score_p1 = MAX(0, score_p1)
```

Component definitions:
- `flow_rate` = cumulative Back action value with diminishing returns:
  `Σ (value_i × 0.9^i)` where i is the event index per tick per side
- `heat_influence = heat_score × 0.5` (reads live `platform_metrics.heat_score`)
- **Trigger stacking** (for trigger-type effects on `active_effects`):
  `Base × (1 + ln(1 + N))` where Base = geometric mean of N trigger values
- **Passive multiplication** (e.g. Conditioning): product of passive modifier values
- **OpponentEfficiency**: multiplicative product of `opponent_efficiency` effects,
  floored at 0.40 (60% suppression cap)
- Conditioning passive (Athlete only): ramps `+0.005 per 10s elapsed`, capped at `+0.15`
  re-injected into `active_effects` each tick with no `expires_at`

**Ability effects stored in `arena_state.active_effects` (JSONB array):**
```json
{
  "effect_id": "conditioning_p1",
  "ability_id": "athlete:conditioning",
  "target_player": 1,
  "modifier": "flow_rate_multiplier",  // or heat_influence_multiplier, opponent_efficiency, suppression_level, momentum_window
  "value": 1.05,
  "is_passive": true,
  "expires_at": "2026-05-23T12:00:00Z"  // null for passives
}
```

**Persistent score columns (survive match end):**
- `momentum_score`: winner gains round_weight points on resolution; loser decays 5%;
  Monday rollover: spotlight winners → 0, everyone else → ×0.5
- `arena_rating` (Elo, K=32): updated only on Round 2 resolution
- `arena_weekly_points`: Round1 win=+1pt, Round2=+2pts, Round3=+5pts; wiped Monday

### Database Tables

```
arena_matches (id, round, state [pending|pre_match|live|resolved],
               player_1_id, player_2_id,
               player_1_archetype, player_2_archetype,
               momentum_score_p1_at_start, momentum_score_p2_at_start,
               scheduled_start, actual_start, actual_end,
               winner_id, final_score_p1, final_score_p2)

arena_state (match_id PK, tick, score_p1, score_p2,
             flow_rate_p1, flow_rate_p2,
             heat_influence_p1, heat_influence_p2,
             active_effects [jsonb],    ← arena_trigger() writes here
             suppression_p1, suppression_p2,
             momentum_window_p1, momentum_window_p2,
             total_pool_p1, total_pool_p2)  ← updated by arena_back()

arena_events (id, match_id, user_id, target_id,
              type [back|trigger], value, metadata,
              processed, created_at)
  • back events: processed=false until tick loop consumes them
  • trigger events: inserted with processed=true (effects already in active_effects)

arena_abilities (id, name, target, modifier, value, duration_secs,
                 is_passive, archetype, description, token_cost, is_live)

arena_weekly_points (user_id, week_start, points)

arena_spotlight_assignments (week_start PK, slot_1..5_user_id)
arena_rollover_log (audit)

arena_round3_brackets (id, week_start, participant_ids[], state)
arena_round3_results  (bracket_id, match_id, round_in_bracket)
```

### Data Flow

```
pg_cron (5min) → arena_matchmake(5)
  → pairs eligible is_market_maker creators by category
  → INSERT arena_matches (state=pre_match, scheduled_start=now+30s)
  → INSERT arena_state (zeros)

Flutter RPC → arena_back(match_id, target_id, amount)
  → deduct tokens from token_balances
  → INSERT arena_events (type=back, processed=false)
  → UPDATE arena_state.total_pool_p1/p2

Flutter RPC → arena_trigger(match_id, ability_id, target_id)
  → deduct tokens
  → append effect to arena_state.active_effects
  → INSERT arena_events (type=trigger, processed=true)

pg_cron (1min, target 3s) → process_arena_tick()
  → flip pre_match → live at scheduled_start
  → for each live match:
      read heat_score from platform_metrics
      expire trigger effects (by expires_at)
      inject/update Conditioning passive for Athlete
      compute trigger log-stacking + passive product multipliers
      accumulate BaseFlow from unprocessed back events
      compute new scores with full formula
      UPDATE arena_state (Realtime broadcasts delta)
      mark back events processed=true
  → resolve matches past 5 minutes:
      determine winner
      distribute 90% pool to winning backers proportionally
      credit 5% to winning creator
      burn 5% platform fee
      UPDATE arena_matches state=resolved

pg_cron (Monday 00:00 UTC) → arena_monday_rollover()
  → find last week's Round 3 bracket → extract top 5 finalists
  → INSERT arena_spotlight_assignments
  → reset finalists: heat_score=0, momentum_score=0
  → decay all others: momentum_score × 0.5
  → DELETE arena_weekly_points for prior weeks
  → INSERT arena_rollover_log
```

### Pool Split
- 90% → winning backers (proportional to amount backed)
- 5% → winning creator
- 5% → platform (burned)

---

## Game 3 — Battle

### Turn Resolution Algorithm

Battle is turn-based. `process_battle_turn(match_id)` runs every 3 seconds
via pg_cron and resolves one turn if all submissions are in OR the deadline
has passed.

**Per-turn sequence:**
1. Expire status effects with `expires_at_turn < current_turn`
2. Guard: require participants on both teams
3. Guard: check force_skip effects → consume and log skip event
4. Auto-select for non-submitters (highest-damage affordable ability)
5. Regen 5 AP for all non-fainted participants
6. **Phase 1** — voluntary swaps in speed order (before any attacks)
7. **Phase 2** — attacks in effective speed order:
   `effective_speed = base_speed + (speed_priority × 1000)`, ties by RANDOM()

**Damage formula:**
```
damage = base_damage × type_multiplier
type_multiplier = battle_type_chart[attacker_archetype][defender_archetype]
                  (default 1.0 if not found)
map_multiplier = 1.0  ← stub until Phase D (affinity_archetypes wiring)
```

**Momentum:**
- +10 per attack dealt
- +25 bonus if type_multiplier ≥ 1.5 (super effective)
- Capped at 100; resets to 0 when ultimate (slot 5) is used
- Ultimate requires `momentum = 100` AND `ap >= ap_cost`

**Status effects** (`battle_participant_status_effects`):
- `speed_debuff`: reduces effective_speed this turn
- `force_skip`: skips the participant's action (consumed on use)
- `save_state`: blocks the next hit below threshold HP damage
- `double_damage`: next damage ability deals ×2
- `type_reversed`: type multipliers inverted this turn
- `forced_ability`: must use lowest-damage ability
- `encore`: must repeat last ability used

### Database Tables

```
battle_matches (id, lobby_code, status [lobby|active|resolved|abandoned],
                map_id, host_user_id, current_turn,
                turn_deadline, turn_duration_seconds,
                winner_team_number, spectator_pool,
                started_at, resolved_at)

battle_participants (id, match_id, user_id, team_number [1|2],
                     slot_position [1|2|3],  ← 1=starts active, 2-3=bench
                     archetype, character_name,
                     max_hp, max_ap, speed,
                     current_hp, current_ap, momentum,
                     is_active, is_fainted, is_automated, last_seen_at)

battle_turn_submissions (match_id, turn_number, participant_id, user_id,
                          ability_id XOR swap_to_participant_id,
                          was_auto_selected)
  ← NOT in Realtime (private until resolution)

battle_events (match_id, turn_number, sequence_in_turn,
               event_type [swap_voluntary|swap_forced|ability_used|
                           ultimate_used|ko|momentum_gained|ultimate_ready|
                           auto_selected|match_end],
               actor_participant_id, target_participant_id,
               ability_id, damage_dealt, hp_after, ap_after, momentum_after,
               type_multiplier, map_multiplier, animation_key)
  ← Realtime — Flutter reads this stream to drive animations

battle_participant_status_effects (match_id, participant_id,
                                    applied_by_participant_id,
                                    effect_type, effect_value,
                                    applied_at_turn, expires_at_turn,
                                    consumed, indicator_key)
  ← Realtime — Flutter shows active effect badges

battle_abilities (id, archetype, name, ability_slot [1-5],
                  ap_cost, requires_momentum, base_damage, speed_priority,
                  effect_type, effect_value, effect_target,
                  is_ultimate, animation_key)

battle_type_chart (attacker_type, defender_type, multiplier [0.5|1.0|1.5])
  ← 100% data-driven; rebalance via SQL UPDATE only

battle_maps (id, name, affinity_archetypes[], background_key, active)
  ← map_multiplier (1.15 for affinity archetypes) wired in Phase D

battle_spectator_bets (match_id, user_id, team_number, tokens_wagered,
                        status, payout)

battle_animation_keys (ability_id PK → animation_key, animation_duration_ms,
                        requires_target)

battle_match_telemetry (match_id, turn_count, winning_archetypes[],
                         losing_archetypes[], map_id, ultimates_used,
                         auto_selections, status_effects_applied,
                         match_duration_seconds)
```

### Data Flow

```
Flutter RPC → battle_create_lobby()  → INSERT battle_matches (status=lobby)
Flutter RPC → battle_join_lobby(code) → INSERT battle_participants
Flutter RPC → battle_start_match()    → SELECT random map_id
                                        → UPDATE battle_matches (status=active, started_at)
Flutter RPC → battle_forfeit()        → resolve match immediately, no bet settlement

pg_cron (3s) → process_all_battle_turns()
  → for each active battle_match:
      process_battle_turn(match_id)
      → expire status effects
      → force_skip handling
      → auto-select missing submissions
      → AP regen
      → Phase 1: voluntary swaps
      → Phase 2: attacks in speed order
          damage = base_damage × type_chart_multiplier
          apply non-damage effects (heal, drain_ap, momentum_boost, debuffs)
          INSERT battle_events (animation_key for Flutter)
          INSERT battle_participant_status_effects for debuff abilities
          KO check → faint + auto-swap
          ultimate_ready check at momentum=100
      → win condition: all 3 on a team fainted
          settle spectator_bets (90% pool equal split to winners)
          INSERT battle_match_telemetry
          UPDATE battle_matches (status=resolved)

pg_cron (60s) → battle_check_presence()
  → flip is_automated=TRUE for participants with stale last_seen_at

pg_cron (10min) → cleanup_abandoned_battle_matches()
  → lobby→abandoned after 30min with no start
  → active→abandoned after 2h (runaway match)

pg_cron (30s) → call_battle_tick_warmer()  [migration 071]
  → HTTP POST to battle-tick-warmer edge function (connection keep-alive)
```

### Pool Split (spectator bets)
- 90% → all winning-side bettors (equal split, not proportional)
- 10% → platform (retained in spectator_pool, not credited)

---

## Celebrity / Hot Topic Infrastructure

### Scoring Formula

Hot Topic tracks 25 public celebrities (not platform creators). Their scores
are independent of the `platform_metrics` / `display_score` system.

**Weekly lifecycle:**
- Monday 11:00 UTC: `initialize_hot_topic_week()` seeds all active celebs at 1000 pts
- 11:00 UTC + 22:00 UTC daily: `hot-topic-fetch-and-score` runs
- Saturday 00:00 UTC: `hot-topic-resolve-week` finalizes weekly bets

**Per scoring run:**
1. Fetch last 24h news from Currents API for each celeb (by name + aliases, up to 10 stories)
2. Pass all 25 celebs + their stories to Claude (claude-sonnet-4-6) in one batch
3. Claude assigns a tier and delta to each celeb:
   `Good 4 (+10)` → `Good 1 (+1)` → `Neutral (0)` → `Bad 1 (-1)` → `Bad 4 (-10)`
4. Volume multiplier: if `story_volume > 5` AND tier is `Good 4 / Good 3 / Bad 4 / Bad 3`
   → multiply delta by 1.5× or 1.2×
5. `hot_topic_score_celeb()` RPC: first run inserts at `1000 + delta`,
   subsequent runs increment: `points += delta`
6. Resolve pending simple bets for this celeb + this scoring window
7. Recompute and write ranks for all celebs in the week

**Bet types:**
- `simple`: `up` or `down` on a single celeb per scoring window
  - Resolves after each scoring run
  - `delta > 0` → up wins; `delta < 0` → down wins; `delta = 0` → all lose
  - Pool split: 90% to winners (equal), 10% platform
- `weekly`: `person_of_week | top_riser | big_boo | top_5`
  - Resolves Friday 8PM ET (Saturday 00:00 UTC) via `hot-topic-resolve-week`

### Database Tables

```
celebs (id, name, aliases[], category, image_url, active)
  ← 25 rows seeded in migration 057
  ← image_url is NULL for all celebs (not yet populated — pre-launch gap)
  ← no FK to profiles or platform_metrics; entirely separate from creator system

celeb_weekly_scores (id, week_id, celeb_id,
                      points, rank, story_volume,
                      last_delta, last_tier, reason_text, updated_at)
  UNIQUE (week_id, celeb_id)

celeb_score_history (id, week_id, celeb_id,
                      tier, delta, story_volume, reason_text,
                      scoring_window, scored_at)
  ← powers /news feed and celebrity profile sparkline

weekly_bets (id, user_id, week_id,
              bet_category [simple|weekly],
              weekly_bet_type [person_of_week|top_riser|big_boo|top_5],
              simple_direction [up|down],
              celeb_id, scoring_window,
              tokens_wagered, status, payout, placed_at)
  UNIQUE INDEX: one simple bet per user+celeb+window+direction
  UNIQUE INDEX: one weekly bet per user+week+weekly_bet_type
```

### Data Flow

```
Flutter → hot-topic-place-bet edge function
  → validate tokens, INSERT weekly_bets, deduct token_balances

pg_cron (11:00 UTC daily) → call_hot_topic_fetch_and_score()
pg_cron (22:00 UTC daily) → call_hot_topic_fetch_and_score()
  → hot-topic-fetch-and-score edge function:
      Currents API → news per celeb
      Anthropic API (claude-sonnet-4-6) → tier + delta per celeb
      hot_topic_score_celeb() RPC → upsert celeb_weekly_scores
      INSERT celeb_score_history
      resolve pending simple bets for this window
      recompute all ranks for the week

pg_cron (Monday 11:00 UTC) → call_hot_topic_reset_week()
  → hot-topic-reset-week edge function
  → initialize_hot_topic_week() → seed new week at 1000 pts

pg_cron (Saturday 00:00 UTC) → call_hot_topic_resolve_week()
  → hot-topic-resolve-week edge function
  → resolve weekly bets (person_of_week, top_riser, big_boo, top_5)
```

### Flutter Screens → Data Sources

| Screen | Route | Provider | Data Source |
|---|---|---|---|
| Hot Topic leaderboard | `/hot-topic` | `hotTopicLeaderboardProvider` | `celeb_weekly_scores` JOIN `celebs` |
| Breaking News panel on home | `/home` | `breakingNewsPreviewProvider` | `celeb_score_history` (top 3) |
| News feed | `/news` | `newsfeedProvider` | `celeb_score_history` (50 most recent) |
| Celebrity profile | `/news/:celebId` | `celebProfileProvider(celebId)` | `celebs` + `celeb_weekly_scores` + `celeb_score_history` |
| My bet (weekly) | within `/hot-topic` | `currentUserWeeklyBetProvider` | `weekly_bets` |

---

## Cross-Game Token Economy

All token movements share `token_balances` (source of truth) and
`token_transactions` (immutable ledger). The constraint enforces valid types:

```
token_transactions.type ∈ {
  signup_bonus        — new user creation trigger
  bet_placed          — Markets: wager deducted (negative impact)
  bet_won             — Markets + Hot Topic: payout
  bet_lost            — Markets + Hot Topic: record (amount=0)
  refund              — Markets: voided market refund
  promoted            — Market Maker fee credit
  referral_bonus      — signup with referral token
  purchase            — Stripe IAP (via stripe-webhook)
  purchased           — legacy alias
  challenge_reward    — challenge completion payout
  passive_bonus       — badge earn_rate bonus on win
  arena_back          — Arena: Back action deduction
  arena_trigger       — Arena: Trigger ability deduction
  arena_win           — Arena: match resolution payout (backer + creator)
}
```

`increment_token_balance(p_user_id, p_amount)` is the single write path to
`token_balances.available_tokens`. Called from SECURITY DEFINER functions only.

---

## Spotlight Architecture

The Home screen Dual Spotlight is computed by `compute-spotlight` edge function
(called by `dualSpotlightProvider` in Flutter):

**Arena Champions (5 slots):**
- Source: `arena_spotlight_assignments` for current `week_start`
- Locked Monday 00:00 UTC by `arena_monday_rollover()`
- Populated from Round 3 bracket finalists (winner, finalist, top 4 semi-losers by seed)
- Empty if no Round 3 completed last week

**Top Movers (5 slots):**
- Source: `score_history` — trailing 7-day composite Display Score growth
- Dynamic: recomputed on every call
- Filters: `is_market_maker=true`, `pending_opt_out=false`, `is_test_account=false`
- Requires at least one `score_history` row older than 7 days for a creator to qualify

Legacy `spotlight_scores` table still exists but is no longer updated. The
`spotlightCreatorsProvider` in `home_providers.dart` queries it (stale, returns
empty in practice) — this is dead code.

---

## Gaps, Issues, and Suggestions

### Fixed in this session

| Fix | What changed |
|---|---|
| `arena-tick-warmer` edge function missing | Created `supabase/functions/arena-tick-warmer/index.ts` |
| `battle-tick-warmer` edge function missing | Created `supabase/functions/battle-tick-warmer/index.ts` |
| Tick warmer cron jobs had no migration | Created `supabase/migrations/071_tick_warmer_cron.sql` |
| `arena_win` missing from CLAUDE.md token types | Added to CLAUDE.md |
| CLAUDE.md referenced stale model `claude-sonnet-4-20250514` | Updated to `claude-sonnet-4-6` |

### Known gaps (pre-launch items)

1. **Celebrity `image_url` all NULL** — `celebs.image_url` column exists in
   schema but no images are populated. Profile screen falls back to color
   initials gracefully. Fix: seed URLs in a migration or admin script before
   launch.

2. **Duplicate migration 070 prefix** — Both `070_battle_2player_dev.sql` and
   `070_rename_rive_to_animation.sql` carry the `070_` prefix. Supabase CLI
   tracks by full filename so both are applied separately, but the naming
   collision is risky on fresh installs if tooling sorts differently. Since
   both are already applied to the live DB, renaming would create a "missing
   migration" mismatch. Leave as-is; note for post-launch schema audit.

3. **`spotlightCreatorsProvider` dead code** — Queries `spotlight_scores` with
   `tier=on_fire`. The `compute-spotlight` function no longer writes to
   `spotlight_scores`. The provider always returns empty. Safe to remove.

4. **`celebrity_profile_screen.dart` in wrong feature directory** — Lives under
   `features/explore/` but imports providers from `features/hot_topic/`. Works
   fine, but the file should be moved to `features/hot_topic/screens/` for
   consistency.

5. **Hot Topic simple bet payout is equal-split not proportional** — Current
   logic divides `prizePool / winnerCount`. This means a user who bet 100
   tokens and a user who bet 10 tokens receive the same payout. Proportional
   distribution (same as Markets) may be the intended design.

6. **`battle_match_telemetry.status_effects_applied`** — Added in migration 065
   but the current `process_battle_turn` (migration 067+070) never writes it.
   The column increments `v_effects_applied` locally but does not include it
   in the telemetry INSERT. Phase D should wire this.

7. **Map affinity multiplier is a stub** — `battle_maps.affinity_archetypes`
   and `map_multiplier` column in `battle_events` are placeholder 1.0 until
   Phase D. No code writes a non-1.0 map multiplier yet.

8. **`arena-tick-warmer` pg_cron calls an edge function via `net.http_post`**
   but the migration 071 wrapper requires `app.service_role_key` to be set
   in the database config. This must be set before deploy:
   `ALTER DATABASE postgres SET app.service_role_key TO 'your-key';`

### Suggestions

- **Hot Topic: proportional bet payouts** — Mirror the Markets formula
  (90% of losing pool distributed proportionally to winners by stake) to
  reward larger bettors. The current equal-split may feel unfair at scale.

- **Celebrity profiles + betting from profile page** — `celebrity_profile_screen`
  has the scoring UI but no bet placement CTA. Adding a "Place Bet" button
  here (linking to `bet_bottom_sheet.dart`) would complete the loop.

- **Weekly bet resolution: link winning celeb data to celeb name** — The
  current `hot-topic-resolve-week` function (not read in full here) should
  display the winning celebrity's name in the notification body. Verify
  this is wired.

- **Arena rating vs. Arena Weekly Points** — Rating (Elo, Round 2 only) and
  Weekly Points (all rounds) serve different purposes. Consider exposing both
  on the profile dashboard — rating for skill signal, weekly points for
  current-week hype.

- **Battle spectator bets: equal split vs. proportional** — Same issue as
  Hot Topic. Winning bettors currently share the pool equally regardless
  of stake. Consider proportional distribution for consistency with Markets.

- **`is_test_account` filter sweep (Slice 2)** — CLAUDE.md tracks this as
  incomplete. Several queries in Arena and Markets providers may surface
  test accounts in ranking/discovery. A systematic grep for `is_market_maker`
  / `is_test_account` across providers is the next step.
