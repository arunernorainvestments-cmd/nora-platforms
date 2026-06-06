# NORA Redesign — Ground Truth Reference
# Last updated: 2026-06-06 (Doc 1 applied)

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

## Doc 2 — Game Logic (pending)

Covers: `sync-platform-metrics`, `resolve-markets`, `process_battle_turn`,
`battle_start_match`, `arena_monday_rollover`, new `distribute_match_revenue` /
`battle_use_chit` functions. Hard Rule 21 update (Battle/Arena linkage).

---

## Doc 3 — Marketplace & Polls (pending)

Covers: `celebrity-integration-seed` edge function, poll edge functions,
marketplace edge functions.

---

## Doc 4 — Emergency Fund (pending)

Covers: `ubi_*` tables. Hard rules: AI never recommends, docs private forever,
votes private forever, Stripe Treasury sim-mode until app clears.
See memory: project_emergency_fund_hard_rules.md.
