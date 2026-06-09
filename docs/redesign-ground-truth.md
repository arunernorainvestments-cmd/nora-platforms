# NORA Redesign — Ground Truth Reference
# Last updated: 2026-06-06 (Docs 1+2+3 applied)

This file is the authoritative record of what was actually pushed to the remote DB
during the Redesign sessions. It supersedes the raw `nora_redesign_doc*.md` notes
where the two differ. Update this file each session as Docs 2–4 land.

---

## Doc 1 — New Schema (migrations 080–090, pushed 2026-06-06)

### What Doc 1 covered
Introduced the Likeness Cards system to replace the Campaigns royalty framework,
added creator stat sheets for Battle/Arena, wired in the card marketplace, arena
battle linkage, weekly polls, battle chit collectibles, celebrity integration tables,
match revenue token distribution, campaign deprecation, and KYC simplification.

### Migration inventory

| # | File | What it does |
|---|------|-------------|
| 080 | `creator_stat_sheets.sql` | `creator_stat_sheets` + `creator_stat_history` tables. `calculate_stat_sheets()` SECURITY DEFINER function. Six percentile-ranked stats (Power, Charisma, Resilience, Agility, Wit, Influence) normalized to 300-pt budget. Called by `sync-platform-metrics` (wired in Doc 2). |
| 081 | `likeness_system.sql` | `likeness_offerings`, `likeness_cards` (rarity as generated column), `likeness_card_transfers` (append-only ledger). `likeness_mint_card()` RPC. Extends `sim_usd_transactions.type` CHECK to allow `card_purchase`/`card_sale`. |
| 082 | `card_marketplace.sql` | `card_marketplace_listings` (active listing per card, unique constraint). Secondary market buy/sell RPCs: `likeness_list_card()`, `likeness_buy_card()`. |
| 083 | `battle_format_ownership.sql` | Links likeness cards to Battle eligibility. `battle_format_rosters` and `battle_format_slots` or equivalent ownership tables so card holders can field a creator's character in Battle. |
| 084 | `arena_battle_link.sql` | Arena–Battle linkage tables. Connects arena sessions to battle match records where applicable. (Hard Rule 21 update pending Doc 2.) |
| 085 | `weekly_polls.sql` | `weekly_polls`, `weekly_poll_options`, `weekly_poll_votes`. Anti-abuse guard in `poll-vote` edge function preserved (see memory: feedback_poll_vote_anti_abuse). |
| 086 | `battle_chits.sql` | `battle_chit_definitions`, `battle_chit_inventory`, `battle_chit_uses`. Collectible economy scaffold (post-launch activation). |
| 087 | `celebrity_integration.sql` | Celeb-side tables for stat sheet integration: links `profiles.celeb_id` → `celebs`. Celebrity stat sheet inputs drawn from `celeb_weekly_scores` + `celeb_score_history`. |
| 088 | `match_revenue_tokens.sql` | `match_revenue_distributions` or similar. Token flow for match rewards: 90% backers / 5% platform / 5% winning creator. All movements logged in `token_transactions`. |
| 089 | `campaign_deprecation.sql` | Renames 7 live campaign tables to `campaigns_archived_*` prefix. Closes open campaigns. Unschedules `campaign-status-tick` and `governance-tick` cron jobs. |
| 090 | `kyc_simplification.sql` | Simplifies KYC verification flow for the Likeness Cards system. |

### Deviations from design doc (applied fixes)

1. **`081` — `rarity` column**: Design spec wrote `DEFAULT 'standard' GENERATED ALWAYS AS (...)` which is illegal in PostgreSQL (can't have both DEFAULT and GENERATED). Fixed: removed `DEFAULT 'standard'`; the GENERATED expression covers all cases including the 'standard' default.

2. **`089` — missing Phase 4 tables**: Design doc listed `campaign_stake_listings`, `campaign_stake_sales`, and `campaign_unclaimed_balances` as tables to rename. None of these were ever created (they belong to Campaigns Phase 4 — Secondary Market, which is queued). Those three rename statements were removed from the migration.

3. **`070_rename_rive_to_animation.sql` deleted**: Two local files shared version prefix `070`, which the Supabase CLI cannot reconcile with a single remote `070` entry. The rename file's content was already applied to the remote DB via the legacy stale-entry path. Deleted the local file to resolve the duplicate; the DB schema is correct.

4. **`070–079` stale schema_migrations entries**: The remote `schema_migrations` table had 11 non-standard entries (e.g. `079_recruiter_badge`, `078_campaign_updates`, etc.) that the modern CLI couldn't parse. Fixed via `supabase db query --linked` to DELETE the stale entries and INSERT proper numeric-version rows (`071`–`079`), then pushed 080–090 cleanly.

### Campaign tables — before → after

| Before | After |
|--------|-------|
| `campaigns` | `campaigns_archived` |
| `campaign_ownership_ledger` | `campaigns_archived_ledger` |
| `campaign_revenue_events` | `campaigns_archived_revenue` |
| `campaign_distributions` | `campaigns_archived_distributions` |
| `campaign_proposals` | `campaigns_archived_proposals` |
| `campaign_votes` | `campaigns_archived_votes` |
| `campaign_updates` | `campaigns_archived_updates` |
| `campaign_stake_listings` | *(never created — Phase 4 queued)* |
| `campaign_stake_sales` | *(never created — Phase 4 queued)* |
| `campaign_unclaimed_balances` | *(never created)* |

### Flutter campaigns UI (same commit)
- `campaigns_providers.dart` — repointed at `campaigns_archived_*` tables (read-only)
- `campaigns_list_screen.dart` — shows deprecation banner; all write actions throw deprecation message

### Stat sheets — current state
`calculate_stat_sheets()` returns 0 rows in the dev environment because all 20
market makers with `platform_metrics` rows are flagged `is_test_account = TRUE`
(Hard Rule #15 filter). Will populate with real users in production.
Celebrity stat sheets need the `celebrity-integration-seed` edge function to run
first (Doc 3 session).

---

## Doc 2 — Game Logic (migration 091, pushed 2026-06-06, commit dbf1f37)

### What Doc 2 covered
Wired creator stat sheets into battle damage calculations, added prediction market
auto-creation at battle start, built the match revenue distribution flow for card
holders/betters/creators, scaffolded chit usage in Battle, updated Spotlight source
to battle-wins leaderboard, and added marketplace/poll route stubs.

### Migration 091 inventory

| Change | What it does |
|--------|-------------|
| `markets.resolution_type` | 'display_score' (default) or 'battle_outcome'; index on `battle_match_id` |
| `battle_participants.snap_*` | Six INTEGER snap columns (power/charisma/resilience/agility/wit/influence), DEFAULT 50 |
| `effect_type` CHECK extended | Added: stat_boost, damage_shield, speed_burst, counter, type_override, aura, disruption |
| `process_poll_results()` | Stub — no-op until Doc 3 applies full implementation |
| `distribute_match_revenue()` | 75%→winner betters / 10%→active players / 5%→creators / 5%→card holders / 5% platform |
| `battle_use_chit()` | Validates ownership, decrements inventory, writes to `battle_participant_status_effects` (not arena_state) |
| `battle_start_match()` | Format-aware validation (1v1/2v2/3v3), stat snapshot, speed recalc, auto-creates market |
| `process_battle_turn()` | Stat damage mods (power ±20%, wit ±10%, resilience up to −30%), market settlement on resolve, chit RNG drop |
| `arena_monday_rollover()` | Spotlight from battle-wins leaderboard (top 5 this week); poll multiplier reset |

### Edge function changes
- **`sync-platform-metrics`**: calls `calculate_stat_sheets()` RPC after each sync run (before final return)
- **`resolve-markets`**: `Market` interface gains `resolution_type` + `battle_match_id`; `resolveBattleOutcomeMarket()` added as 24h cron safety net — calls `distribute_match_revenue()` if match is resolved

### Flutter changes
- `battle_models.dart`: `StatSheet` + `EligibleCharacter` models added
- `battle_providers.dart`: `eligibleCharactersProvider`, `creatorStatSheetProvider`, `battleArenaMarketProvider` added
- `app_router.dart`: `/marketplace`, `/marketplace/card/:cardId`, `/marketplace/offering/:offeringId`, `/poll/:pollId`, `/poll/:pollId/embed` routes with stub screens

### Deviations from design doc

1. **`battle_use_chit` → `battle_participant_status_effects`**: Doc 2 specified writing chit effects to `arena_state.active_effects`. Corrected to `battle_participant_status_effects` — `arena_state` is the live Arena game's mutable row; chits are Battle artifacts (Hard Rule #21).

2. **`base_archetype_speed()` → `battle_get_archetype_speed()`**: Doc 2 referenced `base_archetype_speed()` but the existing function from migration 062 is named `battle_get_archetype_speed()`. Used the existing name.

3. **`process_poll_results()` stub**: Doc 2 calls this from `arena_monday_rollover()`; Doc 3 implements the full function. Stub created here to prevent rollover failure. Weekly poll multiplier reset IS live (effective_* restored to stat_* values).

4. **Chit post-launch**: `battle_use_chit` writes effects to DB but `process_battle_turn` does not yet read/apply chit status effects (post-launch). RNG chit drop on win IS live.

5. **`distribute_match_revenue` pool columns**: `yes_pool` maps to team_1 bets, `no_pool` maps to team_2 bets (semantic reuse of existing columns). Bet placement for team_1/team_2 positions needs Flutter UI work (not yet done).

---

## Doc 3 — Marketplace & Polls (migration 092, commit e1f25eb, pushed 2026-06-06)

### Migration
- `092_restore_process_poll_results.sql`: Restores the real `process_poll_results()` overwritten by the stub in 091. Applies poll multipliers: rank 1 → 1.150×, rank 2 → 1.100×, rank 3 → 1.060×, rank ≤5 → 1.030×, rank ≤10 → 1.010×, else 1.000×. Updates `creator_stat_sheets.effective_*` and `poll_results.stat_multiplier_applied`. Logs zero-amount `token_transactions` with type `poll_boost_applied`.

### Edge Functions (new)
- `poll-vote/index.ts`: Public (no JWT). IP rate-limit 3/poll (SHA-256 hashed), device fingerprint rate-limit 5/poll. Registered users weight 1.0, anonymous 0.3. Calls `increment_poll_option_votes` RPC.
- `celebrity-integration-seed/index.ts`: Admin-gated (`x-admin-key` = `ADMIN_SEED_KEY`). Creates Supabase auth users with managed emails, inserts `profiles` rows (`is_celeb=TRUE, managed_by_platform=TRUE`), marks `celebs.is_integrated=TRUE`.
- `likeness-create-offering/index.ts`: Auth required. Validates `is_market_maker=TRUE, pending_opt_out=FALSE`. Enforces one active offering per creator. Calculates `pct_per_card`.
- `likeness-purchase-card/index.ts`: Auth required. Sim mode only. Calls `likeness_mint_card` RPC. Notifies buyer + creator.
- `likeness-list-card/index.ts`: Auth required. Verifies caller owns card. Prevents duplicate active listings.
- `likeness-buy-listed-card/index.ts`: Auth required. Sim mode only. Calls `card_marketplace_purchase` RPC. Notifies buyer + seller.
- `chit-marketplace-list/index.ts`: Auth required. Validates `can_buy_in_marketplace=TRUE`. Decrements seller inventory, rolls back on insert failure.
- `chit-marketplace-buy/index.ts`: Auth required. Deducts tokens from buyer, credits seller via `increment_token_balance` RPC. Logs `chit_purchase` + `chit_sale` in `token_transactions`.

### Flutter Changes
- `flutter_app/pubspec.yaml`: Added `crypto: ^3.0.3`
- `flutter_app/lib/core/utils/device_fingerprint.dart` (new): SHA-256 browser signal hash using `package:web`. Returns null on non-web.
- `flutter_app/lib/features/polls/models/poll_models.dart` (new): `WeeklyPoll`, `PollOption` models.
- `flutter_app/lib/features/polls/providers/poll_providers.dart` (new): `currentOpenPollProvider`, `pollOptionsStreamProvider` (Realtime), `pollLeadersProvider`, `hasVotedProvider`.
- `flutter_app/lib/features/polls/screens/poll_screen.dart` (real implementation): Countdown timer, real-time vote stream, weighted vote progress bars, anti-abuse submit via `poll-vote` edge function, share link copy.
- `flutter_app/lib/features/marketplace/providers/marketplace_providers.dart` (new): 7 providers — offerings, listings, my cards, offering detail, card detail, card transfers, chit listings, chit definitions, my chits.
- `flutter_app/lib/features/marketplace/screens/marketplace_screen.dart` (new): Two-tab screen (Characters: offerings + secondary + my cards; Chits: Earn/Browse/My sub-tabs). `OfferingDetailScreen`, `CardDetailScreen` with transfer history.
- `flutter_app/lib/core/router/app_router.dart`: `/marketplace` now uses `MarketplaceScreen` from new path. Old `card_marketplace_screen.dart` stub deleted.
- `flutter_app/lib/features/home/screens/home_screen.dart`: Added `_PollLeadersStrip` SliverToBoxAdapter after dual-spotlight section (5-chip horizontal scroll of top poll options). `pollLeadersProvider` + `currentOpenPollProvider` invalidated on refresh.
- `flutter_app/lib/features/profile/screens/public_profile_screen.dart`: Added `_StatSheetCard` section (market makers only) showing 6 stats (base + effective), poll multiplier banner, "View Likeness Cards" CTA.

### Deviations from design doc
None — all DB work was in migration 085 (Doc 1). Doc 3's DB layer is only the 092 fix.

---

## Doc 4 — Emergency Fund (migrations 093–097, applied)

Covers: `ubi_*` tables. Hard rules: AI never recommends, docs private forever,
votes private forever, Stripe Treasury sim-mode until app clears.
See memory: project_emergency_fund_hard_rules.md.

---

## Post-Doc-4 session (2026-06-07)

### Home Community Cards (Flutter only)
- `home_screen.dart`: new `_CommunitySection` after the Poll Leaders strip —
  `_MarketplaceCard` (→/marketplace, live active-offering count badge) and
  `_EmergencyFundCard` (→/emergency-fund, live pool balance via stream +
  AnimatedSwitcher + "Simulated" badge).
- `ubi_providers.dart`: `ubiPoolBalanceStreamProvider` (StreamProvider.autoDispose
  on `ubi_pool_balance_cache`). `emergency_fund_screen.dart` switched to it.
- `marketplace_providers.dart`: `activeOfferingsCountProvider`
  (`count(CountOption.exact)` on `likeness_offerings` where status='active').

### Migration 098 — `ubi_pool_balance_realtime.sql` (applied)
Adds `ubi_pool_balance_cache` to the `supabase_realtime` publication so the
Flutter `.stream()` on the pool balance delivers live updates (not just a
snapshot). Idempotent DO-block, matches the 054 idiom.

### Migration 099 — `fix_battle_market_timeframe.sql` (applied)
Bug fix: `battle_start_match()` (091) inserted the auto-created battle market
without `timeframe`, which is NOT NULL with no default → every real match start
raised a NOT NULL violation (masked because the battle screen uses a `test-match`
placeholder that never calls the RPC). Now sets `timeframe='24h'`,
`duration_label='1day'`. Body otherwise verbatim from 091.

### Battle-market bet UI (Flutter, Doc 2 deviation #5 closed)
- `markets_providers.dart`: `openMarketsProvider` now filters
  `resolution_type='display_score'` (battle markets no longer leak into the
  creator list / can't crash on a null creator_id). Added `BattleMarket` model +
  `battleMarketsProvider` (open battle_outcome markets).
- `markets/widgets/battle_bet_sheet.dart` (new): `showBattleBetSheet` — pick
  team 1 (yes pool) / team 2 (no pool) → amount → confirm; inserts a `bets` row
  (existing trigger handles pools/tokens/notify). Team labels parsed from the
  "Battle: X vs Y" title.
- `markets_screen.dart`: `_BattleMarketsSection` sliver on the "All" view —
  renders nothing until a real battle market exists, then lists them with a
  "Back a team" CTA.
- NOTE: battle markets can't be exercised end-to-end yet because the battle
  combat screen is still a `test-match` placeholder (Phase C/D). The bet UI is
  ready and correct for when real matches run.

### Deliberately NOT done
- **Chit status-effect application** in `process_battle_turn` — Doc 2 deviation
  #4 marks this post-launch; left untouched (core turn logic, Hard Rule #21).
- **Campaigns removal** — user chose "keep as-is" (already archived + read-only).

---

## Battle end-to-end: matchmaking + Arena spectating + market (2026-06-07)

Goal: matchmaking (1v1/2v2/3v3), battle auto-goes-live to Arena spectators/bettors,
prediction market opens at go-live, likeness cards field characters.

### Migration 100 — `battle_bet_pool_mapping.sql` (applied)
`handle_bet_pool_update` (trigger from 004) now maps `team_1→yes_pool`,
`team_2→no_pool` (in addition to yes/no). Battle bets previously never
accumulated into a pool → markets always voided. `distribute_match_revenue`
already pays `WHERE position='team_1'/'team_2'` (confirmed: `process_battle_turn`
091 line 968 passes `'team_'||winner`). Bet sheet now inserts `team_1`/`team_2`.

### Migration 101 — `battle_matchmaking.sql` (applied + smoke-tested)
- Refactor: `battle_start_match` → host-checked wrapper + `battle_start_match_internal`
  (no auth check) so matchmaking can auto-start.
- `battle_matchmaking_queue` table (user, format, creator_id, likeness_card_id,
  archetype, character_name, status, matched_match_id) + realtime publication +
  public-read RLS (writes via SECURITY DEFINER RPCs only).
- `battle_enqueue(format, creator_id)` — validates via `check_battle_eligibility`,
  resolves archetype/name (self=profile, owner=card's offering), queues, tries match.
- `battle_try_matchmake(format)` — when `slots*2` queued, creates match, assigns
  teams (first half→team1), inserts participants with creator_id+likeness_card_id,
  calls `_internal` start (snap stats + opens market).
- `battle_leave_queue()`.
- SMOKE TEST (rolled back via RAISE): 2 queued → match + 1 participant/team +
  market "Battle: Alpha vs Bravo". Chain verified at DB level.

### Flutter
- `battle_providers.dart`: `myBattleQueueProvider` (stream, watch for matched),
  `battleQueueCountsProvider`, `battleMatchmakingProvider` (enqueue/leave).
- `battle_matchmaking_screen.dart` (new) at `/battle/matchmaking` — format cards
  w/ live queue counts + eligible character picker (`eligibleCharactersProvider`,
  empty-state → marketplace) + searching state; navigates to `/battle/:id` on match.
- `battle_lobby_screen.dart`: "Quick Match" entry card → matchmaking.
- `arena_screen.dart`: `_LiveBattlesSection` — lists open battle markets (live
  battles) with Watch (→/battle/:id) + Back a team (battle_bet_sheet). This is the
  "battle goes live in Arena for spectators/bettors" surface.

### Still placeholder / next
- Battle **combat screen** (`battle_match_screen.dart`) is still `test-match`
  placeholder — spectator "Watch" navigates there but it isn't a real live view yet.
- No **bot-fill**: matchmaking needs real players to queue for each format
  (1v1=2, 2v2=4, 3v3=6). Solo testing needs N browser sessions.
- Legacy `battle_spectator_bets`/`spectator_pool` (062) still exists, unused by
  the redesign market path — candidate for later cleanup.

---

## Arena/Battle market integrity + Battle Chit framework (2026-06-08)

Spec: `docs/battle-chits-and-arena-integrity.md`. Continuity hygiene before the
Antigravity-assisted animation phase. Establishes the **one-role-per-match** invariant
(combatant uses chits / cannot bet; spectator bets / cannot influence) and builds out
the Battle Chit framework so animation production has stable effect + `animation_key`
definitions.

### Migration 102 — `arena_battle_market_integrity.sql` (APPLIED 2026-06-08)
- `kyc_verifications.identity_hash` + partial UNIQUE index (one approved human → one
  staking identity; NULLs in sim ignored).
- `platform_integrity_settings` singleton: `enforce_one_role_per_match` (default TRUE),
  `require_kyc_for_staking` / `require_kyc_for_combatant` (default FALSE, flip at live).
- Helpers: `is_kyc_verified`, `identity_linked_users` (alts of same verified human),
  `is_match_combatant`.
- `enforce_bet_integrity` BEFORE INSERT on `bets` — rejects a battle-market bet from a
  combatant (or KYC-linked alt); KYC gate when flag on. Runs ahead of the 004 AFTER
  pool/token triggers, so a rejected bet never moves tokens.
- `enforce_arena_event_integrity` BEFORE INSERT on `arena_events` — a backer can't
  `trigger` and a triggerer can't `back` the same legacy-Arena match (retires the
  audience-influence-while-staked path without touching the big arena RPCs).
- `enforce_combatant_kyc` BEFORE INSERT on `battle_participants` — flag-gated, no-op
  until live launch.

### Migration 103 — `battle_chit_framework.sql` (APPLIED 2026-06-08)
- `battle_chit_definitions` += `animation_key` (e.g. `chit_bronze_shield`),
  `requires_target`, `per_match_use_limit` (1 for legendary/mythic).
- `battle_chit_uses` ledger (per-turn/per-match cap enforcement + spectator animations).
- `battle_use_chit` rewritten (drops the 091 3-arg overload; new 4th arg
  `p_target_participant_id`): integrity guard (no chit while holding a stake), 1 chit/
  participant/turn cap, per-chit per-match cap, target validation, and effect resolution:
  - immediate: `momentum_surge`, `stat_boost` (snap_*+=), `aura` (snap_*×), `disruption`
    (remove random opponent effect), `wild_card` (immediate bench swap).
  - mapped: `damage_shield`→`save_state`, `speed_burst`→positive `speed_debuff`.
  - **deferred**: `counter`, `type_override` stored + animated but not yet consumed by
    `process_battle_turn` (rare/epic only; see spec §6).

### Flutter
- `battle_models.dart`: `ChitInventoryItem` model.
- `battle_providers.dart`: `chitInventoryProvider`, `useChitProvider`/`UseChit`.
- `battle/widgets/chit_sheet.dart` (new): inventory sheet + target picker; uses the RPC
  in a live match, previews read-only in the `test-match` placeholder.
- `battle_match_screen.dart`: `_onChit` now opens `ChitSheet` (preview mode).
- `markets/widgets/battle_bet_sheet.dart`: surfaces combatant/KYC integrity errors.

### Migrations 104 + 105 — settlement bugfixes (APPLIED 2026-06-09)
Found by the pipeline smoke test (`supabase/tests/battle_market_pipeline_smoke.sql`).
Both were **pre-existing 091 bugs** that broke EVERY battle-market settlement and were
masked by `process_battle_turn`'s `EXCEPTION WHEN OTHERS` (match resolved, market left
`open`, winning bettors never paid):
- **104** `increment_token_balance_bigint.sql`: `distribute_match_revenue` calls
  `increment_token_balance(uuid, bigint)` (its payout vars are BIGINT) but only the
  `(uuid, integer)` definition existed → "function does not exist". Added a BIGINT
  overload delegating to the INTEGER version.
- **105** `markets_resolution_result_battle.sql`: `distribute_match_revenue` sets
  `resolution_result='team_1'|'team_2'` but `markets_resolution_result_check` only
  allowed `above|below|refund`. Extended the CHECK to include the battle outcomes.

### Smoke test — PASSING (2026-06-09)
`supabase/tests/battle_market_pipeline_smoke.sql` (BEGIN/ROLLBACK; reuses seeded test
accounts) — all 9 checks green via the Management API `/database/query` endpoint:
market opens parallel to live match · live bet → pool · combatant bet blocked · chit
applied + ledger + event · per-turn cap · arena backer≠trigger · identity_hash unique ·
KYC staking gate · **match resolution → market settled (winner paid, loser settled)**.

### Migration 106 + stripe-webhook — deferred items closed (APPLIED 2026-06-09)
- **106** `battle_chit_combat_hooks.sql`: `process_battle_turn` + `battle_use_chit`
  re-pulled via `pg_get_functiondef` and edited surgically (no hand-reproduction).
  Adds the three previously-inert chit hooks: `type_override` (floor type mult at 1.0),
  `damage_shield` (absorb up to N, carry remainder; now stored under its own type, not
  `save_state`), `counter` (reflect dealt damage to attacker + attacker faint/forced
  swap). Validated in a rolled-back turn; full pipeline smoke test still 9/9 after push.
- **stripe-webhook** (deployed `--no-verify-jwt`): new `identity.verification_session.verified`
  branch → SHA-256(name+DOB) into `kyc_verifications.identity_hash`; 23505 collision →
  account `rejected`. Inert until the client creates VerificationSessions (live mode).

### Status / not yet done
- **`flutter analyze`: clean** (No issues found, 2026-06-08; no Dart changed since).
- **Migrations 102–106 pushed** + smoke-tested green; stripe-webhook deployed (2026-06-09).
- Remaining (spec §6): client KYC VerificationSession flow, `aura` on charisma/influence,
  live combat screen, acquisition flows (challenge/pack/gift), bench/target UX wiring.
