# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.
Read it fully before making any changes.

---

## Project Overview

N.O.R.A. Platforms is a Flutter web application for a prediction market platform based
on creator popularity metrics. Backend is Supabase (PostgreSQL + Auth + Edge Functions).
Deployed to Vercel via GitHub Actions on push to main. Launch target: **July 4, 2026**.
DNS: Cloudflare → noraplatforms.com. Supabase project ref: cceisywxwhgljdpisjrl.

---

## Two-Game Architecture

NORA has two distinct games sharing one wallet and one creator pool, with separate scoring,
separate rewards, and separate Spotlight visibility.

### Game 1 — Markets (Prediction Loop) — built (Phases 1–5)
- Bet tokens on whether a creator's composite Display Score will be higher or lower at market close.
- Settled by composite Display Score from real platform APIs (sync-platform-metrics).
- Pool: 90% to winners, 5% platform, 5% to Market Maker.
- User role: predict. Creator is passive.
- Driven by display_score. Does not touch Arena state.

### Game 2 — Arena (Competitive Loop) — Phase B done; Phases C, D ahead
- Live 5-minute matches between two creators.
- Settled by ArenaScore (in-match composite, ephemeral).
- Pool: 90% to backers of winning creator, 5% platform, 5% creator.
- Two token actions only:
  - **Back** — at-risk allocation; feeds BaseFlow; 90% pool share on win, lost on loss.
  - **Trigger** — consumed token spend on archetype abilities; never returned.
- No third loop. No "bet on Arena outcome" mechanic.
- ArenaScore = BaseFlow + HeatInfluence + AbilityImpact + MomentumSpike + MomentumCarry − Suppression.
- Reads heat_score, never writes it. Reads category to determine archetype.

### Shared
- One wallet (`token_balances`). Eligibility: `is_market_maker=true AND pending_opt_out=false AND is_test_account=false`.
- One Heat Score (boost/promotion-modifiable only).
- Independent rewards across games.

---

## Dual Spotlight Architecture

Two distinct sections on the home page, each driven by one game.

### Arena Champions (5 slots, locked Monday 00:00 weekly)
- Populated by previous week's Round 3 winners.
- Slot 1 = Round 3 1st; Slots 2–5 = 2nd through 5th.
- Spotlight rotation rule: the Monday after holding a slot, `heat_score = 0` AND `momentum_score = 0`. Reward is visibility + points already earned, not compounding advantage.

### Top Movers (5 slots, updates continuously)
- Largest weekly composite Display Score growth from `score_history` deltas (trailing 7 days).
- Computed by `compute-spotlight` (current legacy logic uses token activity; Top Movers replaces this in Phase D).

Home page layout split: deferred TODO in `lib/features/home/screens/home_screen.dart` — implement in Phase D.

---

## Arena Visual Design

Canonical reference: Grok mockups Arena_1–5, April 2026 (not in repo). Base = Arena_5; power-up tracker from Arena_2/3/4.

**Pass 1 (shipped Phase A):** pulsing radial-gradient orbs; center beam (score ratio); corner power-up slots; event ticker; countdown timer; Back/Trigger buttons. No particles, waveform, shaders, or BackdropFilter.

**Pass 1.5 (shipped Phase B):** ability picker bottom sheet; active effect badges with depleting timers (badges rebuild once on init — per-second tick is Phase C polish); trigger event flash on orb.

**Pass 2 (post-Phase D):** particle bursts on Back; full power-up tracker bar; orb glow scaled by heat_influence; beam pulse animation.

**Pass 3 (post-launch):** match-data-driven waveform (CustomPainter, not audio FFT); lightning arcs; Ultimate screen flash; per-archetype orb theming.

**Do not attempt:** 3D orb effects; audio FFT; shader glow; real-time blur; real particle physics.

**Performance:** lerp ticks (3s); drive from `arena_state.tick`, not local time; coalesce concurrent effects to one flash + stack counter; pause on backgrounded tab; test Safari early; client never computes ArenaScore.

---

## Commands (run from `flutter_app/`)

```bash
flutter pub get
flutter analyze              # zero issues required before every commit
flutter build web --release --no-tree-shake-icons
```

Plain Riverpod only — `FutureProvider.autoDispose` / `Provider`. NO @riverpod, NO build_runner, NO code generation.

---

## Environment

`.env` in `flutter_app/`, copied from `.env.example`, loaded as asset via flutter_dotenv.

---

## Routing (GoRouter, PathUrlStrategy — clean URLs, no #)

| Route | Screen | Auth |
|-------|--------|------|
| `/` | LaunchScreen | public; redirects logged-in to /home |
| `/home` | HomeScreen (Shell) | public |
| `/news` | CelebrityHeatScreen | public |
| `/explore` | → /news | redirect |
| `/hot-topic` | HotTopicScreen | public placeholder |
| `/markets` | MarketsScreen (Shell) | required |
| `/markets/:id` | MarketDetailScreen | public |
| `/markets/mybets` | → /mybets | redirect |
| `/mybets` | MyBetsScreen | required |
| `/profile` | ProfileScreen (Shell) | required |
| `/wallet` | WalletScreen (Shell) | required |
| `/search` | SearchScreen (Shell) | public |
| `/dashboard` | ScoreDashboardScreen | auth |
| `/challenges` | ChallengesScreen | auth |
| `/u/:username` | PublicProfileScreen | public |
| `/login` `/signup` `/forgot-password` | auth screens | public |
| `/pending-approval` | PendingApprovalScreen | public (beta gate) |
| `/join` | ReferralScreen (?ref=code) | public |
| `/privacy` `/terms` `/tiktok-verification` | static HTML | public |
| `/plan` | PlanScreen | placeholder |
| `/arena` | ArenaLobbyScreen | required |
| `/arena/:matchId` | ArenaMatchScreen | required |
| `/w/:token` | LaunchScreen with token param | public (waitlist) |

Auth redirects: unauth + protected → /login (destination in `pendingNavigationProvider`); logged in + unapproved → /pending-approval; logged in + approved on auth/launch page → /home.

---

## Score Architecture — DO NOT MODIFY WITHOUT FULL UNDERSTANDING

`platform_metrics` has two active score columns (migration 019 dropped `resolution_score`):

### display_score — bigint, additive raw points
Per-platform total. Sum across rows = composite Display Score. Adding a platform always increases total. NEVER modified by promotions or any user action. Used for market resolution: resolve-markets sums all rows vs `markets.opening_resolution_score` (snapshot at open — name is legacy; it's the additive composite).

**Point values:** 1 follower = 1 pt; 1 live viewer = 10 pts; 24h growth = 5 pts/follower; X view = 0.1; X repost = 3; X like = 1; Spotify saved track/album = 3 each.

**Spotify column reuse:** `recent_post_views` = saved tracks; `recent_post_reposts` = saved albums. Not X-exclusive — check platform context.

### heat_score — 0–100, boost-only, baseline 0
What UI and Spotlight read. Modified only by promotions/power-ups via `active_boosts`. Computed: `CLAMP(SUM(active boost deltas where not expired/cancelled), 0, 100)`.

### Dropped (do not reference): `resolution_score`, `power_up_cooldowns`, `platform_metrics.spotlight_pinned_until`, `profiles.accepts_new_markets`, `profiles.token_balance`. See docs/ARCHIVE.md.

---

## Score Hierarchy & Roles

| Score | Storage | Modified by | Role |
|-------|---------|-------------|------|
| Display Score | `platform_metrics.display_score` (bigint, sum) | sync-platform-metrics only | Market resolution; Top Movers Spotlight. NOT in Arena. |
| Heat Score | `platform_metrics.heat_score` (0–100) | promotions/power-ups only | UI popularity; Arena reads for HeatInfluence. |
| Momentum Score | `platform_metrics.momentum_score` (Phase D) | Arena wins + weekly decay + Spotlight reset | Persistent Arena win-streak; feeds MomentumCarry. Resets to 0 on Spotlight win. |
| ArenaScore | `arena_state.score_p1`/`score_p2` | tick loop only | Live in-match. Ephemeral. |
| Weekly Arena Points | new column/table (Phase D) | match wins + Monday reset | Round 3 qualification. |
| Round 3 placement | `arena_matches` outcomes | Round 3 results | Arena Champions Spotlight slots. |

---

## Supabase Schema

All tables RLS-enabled. Migrations run in order. Recent additions:

| Migration | What |
|-----------|------|
| 022 | waitlist (email UNIQUE, anon INSERT, no anon SELECT) |
| 023 | public_platform_connections view |
| 024 | Two-tier category system (category_1 + subcategory) |
| 025 | is_test_account on profiles + platform_connections; protect_is_test_account trigger |
| 026 | Seeded 20 test creators (2 per primary category, UUIDs `1000…0001`–`…0020`) |
| 027 | Teardown migration (committed, NOT applied — pre-launch reset) |
| 028 | Trigger patch (allow postgres/supabase_admin contexts) |
| 029 | arena_matches + arena_events + arena_state + Realtime publication |
| 030 | arena_back RPC |
| 031 | arena-tick + arena-matchmaker pg_cron + warmer |
| 032 | arena_abilities config table (6-modifier CHECK) + 5 Athlete abilities seeded |
| 033 | arena_ability_uses (cooldown tracking + audit log) |
| 034 | arena_trigger() RPC + arena_trigger token type |
| 035 | process_arena_tick() v2 — full ability-effect processing in PL/pgSQL |

### Token transaction types (final, migration 034)
```
'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost', 'refund',
'promoted', 'referral_bonus', 'purchase', 'purchased',
'challenge_reward', 'passive_bonus', 'arena_trigger'
```

### Key table notes
- `profiles`: `is_creator`, `is_market_maker`, `is_approved`, `is_test_account` (separate flags).
- `token_balances`: separate table. Holds `available_tokens` (integer).
- `active_boosts`: cooldown enforcement (no separate cooldown table).
- `arena_state.active_effects`: JSONB array. Effects pushed directly by `arena_trigger()` for immediate Realtime broadcast (bypasses event queue because Sprint 8s / Defense 10s would expire before next tick).
- `arena_events` for trigger events: inserted with `processed=true` (audit log + ticker feed only — not consumed by tick loop).
- `score_history`: time-series snapshots. user_id, composite_score (bigint), recorded_at.

### Tick loop (PL/pgSQL, not edge function)
`process_arena_tick()` is a PL/pgSQL function called by pg_cron every 3 seconds. No edge function deploy needed for tick processing. The function:
- Pulls unprocessed `arena_events` (Back actions only — triggers write effects directly).
- Decays expired effects from `arena_state.active_effects`.
- Computes per-tick scores.
- Resolves matches at +5min.

### Stacking math (Phase B, finalized)
- Trigger effects: `Base × (1 + ln(1 + N))` with geometric mean.
- Passives: multiplicative product (no log).
- `opponent_efficiency`: multiplicative product with 0.4 floor (NOT log — log inverts direction for values <1).
- Suppression cap: 60%.
- Per-user flow cap via diminishing returns.

### user_passive_effects view (migration 017)
`visibility_multiplier` (additive sum), `token_earn_rate` (additive sum), `promotion_discount` (max), `referral_bonus` (max tier). Read-only at query time.

---

## Platform Integrations

| Platform | Status |
|----------|--------|
| YouTube | ✅ Live (Google verification in review — whitelist only) |
| Twitch | ✅ Live |
| X | ✅ Live |
| Spotify | ✅ Live |
| TikTok | Submitted; secrets NOT in Supabase. Do not build until approved. |
| Instagram | Blocked on Meta SMS. Retry from mobile browser. |
| Kick | Deferred (no API). |

OAuth redirect: `noraplatforms.com/auth/callback`.

---

## Edge Functions (deploy: `--no-verify-jwt`)

| Function | Purpose |
|----------|---------|
| oauth-initiate / oauth-callback / disconnect-platform | OAuth lifecycle |
| sync-platform-metrics | All 4 platforms in one function (do not split). Token refresh. 4-min cooldown. Skips `is_test_account=true`. |
| resolve-markets | Sums display_score; distributes payouts (10% rake); fires evaluate-challenges; applies passive bonuses |
| apply-promotion | Power-up catalogue; cooldown enforcement via active_boosts |
| evaluate-challenges | Condition engine (count_threshold/snapshot/streak/composite/manual); idempotent |
| compute-spotlight | Token-activity scoring (legacy; Phase D rewrites for dual rankings) |
| create-checkout-session / stripe-webhook | Stripe purchases |

**pg_cron jobs:**
- `main-character-check` — hourly; calls `evaluate_main_character_badge()` (#1 heat for 24h).
- `arena-matchmaker` — every 5 min; pairs Round 1 (Phase A); Round 2/3 added Phase D.
- `process_arena_tick` — every 3 sec; PL/pgSQL.
- `arena-tick-warmer` — every 30 sec; cold-start mitigation.

**Deploy:**
```bash
export SUPABASE_ACCESS_TOKEN=your_token
npx supabase functions deploy <name> --project-ref cceisywxwhgljdpisjrl --no-verify-jwt
```
Never paste tokens into Claude Code. Rotate at supabase.com/dashboard/account/tokens.

**Secrets** (Supabase Dashboard → Edge Functions → Secrets): YOUTUBE/TWITCH/X/SPOTIFY client ID + secret pairs; APP_URL=`https://noraplatforms.com`; OAUTH_STATE_SECRET; STRIPE keys; SYNC_SECRET.

---

## Theme Colors (AppTheme)

primary `#6C63FF` · secondary `#03DAC6` · success `#00C896` · danger `#FF4757` · bg `#0A0A0F` · surface `#1A1A2E` · surfaceLight `#16213E` · text white / `#8B8FA8` · cardBorder `#2A2A3E`.

---

## Test Account System

`profiles.is_test_account` and `platform_connections.is_test_account` (migration 025). Trigger blocks client-side flips; allows postgres/supabase_admin (migration 028). 20 test creators seeded (migration 026).

**Filter rule:** test accounts EXCLUDED from all user-facing surfaces by default. Edge functions check `INCLUDE_TEST_ACCOUNTS === 'true'` to opt in (MUST NOT be true in production). Flutter providers always `.eq('is_test_account', false)`.

**Filtered surfaces:** `marketMakersProvider`, `risingCreatorsProvider`, `compute-spotlight` (profiles query), `sync-platform-metrics` (connections query), `evaluate-challenges` (early exit), `evaluate_main_character_badge()`.

**NOT filtered (by design):** `/u/:username`, `resolve-markets`, `marketDetailProvider`, Arena queries (Phase A treats dev as filter-off).

**Teardown:** `027_teardown_test_accounts.sql` — committed, not applied. Run as part of pre-launch reset.

---

## Phase Roadmap (queued work)

### Phase C — Roll out remaining 9 archetypes + subcategory modifiers + balance tooling
- Migration 036+: seed Musician, Healthcare, Performer, Gamer, Influencer, Educator, Politician, Religion, Business abilities.
- Subcategory ±5–10% modifier layer (one stat per subcategory).
- `ability_effectiveness` modifier implementation (declared in 032 schema but not wired in 035 tick logic).
- Per-second effect badge countdown rebuild (Pass 1.5 polish from Phase B).
- Match telemetry table for balance analysis.
- Dev-only `arena-dev-force-match` endpoint (env-gated `ALLOW_DEV_TOOLS=true`).
- Special-case abilities to flag during build: Healthcare Resuscitate (baseline reset), Performer Standing Ovation (ramping), Business Invest (scheduled effect), Politician Debate (ability lockout), Business Monopoly (flow ceiling), Religion Revival (effect re-activation).

### Phase D — Round 2 + Round 3 + Momentum + Weekly Points + Spotlight wiring
- `momentum_score` column on `platform_metrics`; MomentumCarry term in tick loop; locked at match start.
- `arena_weekly_points` table (user_id, week_start, points). Resets Monday.
- `arena_rating` column on `platform_metrics` (Elo-style, K=32, Round 2 only).
- `arena_round3_brackets` + `arena_round3_results`; bracket auto-advances; top 5 finalists fill Spotlight.
- `arena_spotlight_assignments` table (locked Monday 00:00).
- Round 2 cross-category MMR matchmaker; Round 3 Friday 7 PM bracket.
- Champions Power-up Lockout: in Round 3, `arena_trigger` rejects creator-self triggers.
- `arena-monday-rollover` edge function (UTC) — Spotlight winner reset; momentum decay (×0.5) for others; weekly points wipe; audit log.
- `compute-spotlight` rewrite: returns `{ champions, top_movers }`; legacy token-activity fallback removed.
- Home page Spotlight split implementation (TODO from Phase A).
- Round 3 readiness UI on Arena lobby.

### Robinhood-style Waitlist
- Extend existing `waitlist` table (migration 042+): add `id` (uuid PK), `referral_token` (unique), `referred_by` (immutable via trigger), `referral_count` (int).
- Two edge functions: `waitlist-signup` (anon-callable, returns user + queue position + total + referral link), `waitlist-position` (token lookup, 60s cache).
- Optional `waitlist-count` for total-only.
- Three-state LaunchScreen: Anonymous (current form), Just Signed Up (queue position + share link), Returning (auto-detect via URL or shared_preferences).
- Queue scoring: `score = -created_at_unix + (referral_count × REFERRAL_BOOST)` where REFERRAL_BOOST starts at 86400.
- Token generation server-side only (10-char URL-safe base64 from random bytes).
- Self-referral prevented; `referred_by` immutable post-insert.
- New route: `/w/:token` → LaunchScreen with token param.
- Logged-in users still redirect to `/home` from both `/` and `/w/:token`.

---

## Pre-Launch Full Reset (run manually before July 4, 2026)

Each step gated. Confirm before next.

1. Run `027_teardown_test_accounts.sql`.
2. Truncate Arena tables: `arena_matches`, `arena_events`, `arena_state`, `arena_ability_uses`.
3. Reset real user tokens: zero `token_balances`, truncate `token_transactions`, truncate `token_purchases`. (Confirm pre-launch users are beta testers first.)
4. Truncate `user_badges`, `user_challenge_progress`, `user_streaks`.
5. Truncate `bets`, `markets`, `score_history`.
6. Truncate `active_boosts`, `promotion_banners`.
7. Keep `profiles`, `platform_connections`, `waitlist`.
8. Do NOT re-run OG/Early Adopter cutoff migration (already set: OG=`2026-07-04T04:00:00Z`, Early Adopter=`2026-08-03T04:00:00Z`).
9. Re-grant signup bonuses: `increment_token_balance(user_id, 100)` for every real user.

---

## Hard Implementation Rules

1. Plain Riverpod only — no codegen, no @riverpod, no build_runner.
2. `sync-platform-metrics` stays a single Edge Function — never split per platform.
3. Never modify `display_score` outside `sync-platform-metrics`. Never modify `heat_score` outside `sync-platform-metrics` (which sums active_boosts) — except `arena-monday-rollover` which resets Spotlight winners (Phase D, single sanctioned exception).
4. All token movements logged in `token_transactions` with type + reference_id.
5. ON CONFLICT DO NOTHING wherever badges are inserted (UNIQUE(user_id, badge_id)).
6. Passive effects are read-only at query time.
7. Handle HTTP 429 gracefully — log and skip, don't throw.
8. Never hardcode API keys. Use Supabase secrets / Vercel env vars.
9. `noraplatforms.com` everywhere — no `vercel.app` references.
10. Read every file in full before modifying.
11. `flutter analyze` zero issues before every commit.
12. `accepts_new_markets` does not exist — use `is_market_maker=true AND pending_opt_out=false`.
13. `power_up_cooldowns` does not exist — cooldowns via `active_boosts`.
14. `spotlight_pinned_until` does not exist on platform_metrics — use `active_boosts` (`spotlight_entry`).
15. Test accounts (`is_test_account=true`) filtered from all ranking/discovery queries. Flutter `.eq('is_test_account', false)`. Edge functions check `INCLUDE_TEST_ACCOUNTS` env (default off). Never set true in production.
16. Arena and Markets are independent reward loops. No cross-game progress grants.
17. Arena does not modify `display_score`, `heat_score`, or `token_balances` outside: (a) Back action, (b) Trigger action, (c) Match resolution writes to `momentum_score` + weekly Arena points.
18. ArenaScore is in-memory match-only. Do not persist post-match. Only `winner_id` + final scores recorded in `arena_matches`.
19. Spotlight has two distinct sections (Arena Champions, Top Movers). `compute-spotlight` produces both rankings independently.
20. `arena_trigger()` writes effects directly to `arena_state.active_effects` (bypasses event queue) so short-duration effects (Sprint 8s, Defense 10s) don't expire before the 3s tick reads them. Audit row in `arena_events` is `processed=true` from insert.
21. Trigger effect stacking: `Base × (1 + ln(1 + N))` with geometric mean. Passives multiply directly. `opponent_efficiency` uses multiplicative product with 0.4 floor — NOT log stacking (would invert for values <1).
22. `INCLUDE_TEST_ACCOUNTS` filter pass not yet swept across all surfaces — Slice 2 work tracked separately. Phase A/B Arena treats dev as filter-off; subsequent phases respect filter.
