# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.
Read it fully before making any changes.

---

## Project Overview

N.O.R.A. Platforms is a Flutter web application for a prediction market platform based
on creator popularity metrics. The backend is Supabase (PostgreSQL + Auth). Deployed
to Vercel via GitHub Actions on push to main. Launch target: **July 4, 2026** (~69 days
as of 2026-04-26). DNS: Cloudflare → noraplatforms.com. Supabase project ref: cceisywxwhgljdpisjrl.

---

## Two-Game Architecture

NORA has two distinct games sharing one wallet and one creator pool, but with separate scoring,
separate reward loops, and separate Spotlight visibility.

### Game 1 — Markets (Prediction Loop)

Already built. Phases 1–5 complete.

- Users place token bets on whether a creator's composite Display Score will be higher or lower
  at market close than at market open.
- Settled by composite Display Score from real platform APIs (sync-platform-metrics).
- Creator is passive — markets resolve based on real-world metric movement.
- Pool split: 90% to winning bettors, 5% platform rake, 5% to the Market Maker (creator).
- User role: predict. Place bet, wait, win or lose.
- Time horizon: hours to days.
- Driven by display_score. Does not interact with Arena state.

### Game 2 — Arena (Competitive Loop)

To be built (Phase A onward).

- Users participate in live 5-minute matches between two creators.
- Settled by ArenaScore, an in-match composite that exists only during the match.
- Creator is the avatar/champion; the audience drives the outcome through token actions.
- Pool split: 90% to backers of the winning creator, 5% platform rake, 5% to the winning creator.
- User role: participate. Two token actions:
  - **Back** — allocate tokens to a side. Feeds BaseFlow, contributes to ArenaScore. Backed tokens
    are at-risk and resolve to 90% pool share if your side wins, or are lost if your side loses.
  - **Trigger** — spend tokens on power-ups or archetype abilities. Spent tokens are consumed; they
    cause ability effects but are not returned. This is the primary token sink.
- There is no separate "bet on Arena match winner" mechanic. Backing IS the participation.
  Predicting outcomes is the Markets game's job. Do not introduce a third loop.
- Time horizon: 5 minutes per match.
- Driven by ArenaScore (BaseFlow + HeatInfluence + AbilityImpact + MomentumSpike + MomentumCarry −
  Suppression). Does not modify display_score. Does not modify heat_score directly.

### Shared Infrastructure

- **One wallet** (`token_balances`). Same tokens flow through both games.
- **One creator pool.** Eligibility for both games: `is_market_maker = true AND pending_opt_out = false AND is_test_account = false` (in production).
- **One Heat Score.** Both games can read it; only promotions and power-ups can modify it.
- **Independent rewards.** A win in one game does not directly grant rewards in the other.

### Shared but Read-Only

- Arena reads `heat_score` to compute HeatInfluence term in ArenaScore. Arena does not write `heat_score`.
- Arena reads creator category to determine archetype. Arena does not write category.

---

## Dual Spotlight Architecture

The home page Spotlight is split into two distinct sections, each driven by one game.

### Section 1 — Arena Champions

- Five slots on the home page (1st through 5th).
- Populated by Round 3 winners from the previous week.
- Round 3 = Champions bracket, runs Friday 7 PM through Sunday midnight, 5-minute matches;
  weekly top points earners qualify.
- Slot 1 = Round 3 1st place finisher. Slots 2–5 = 2nd through 5th place.
- Slots are locked Monday 00:00 and held for the full week.
- The Monday after a creator holds a Spotlight slot, their `heat_score` resets to 0 AND their
  `momentum_score` resets to 0. Spotlight reward is the public visibility plus points already
  earned — not a compounding advantage into the next week. This is the rotation rule.

### Section 2 — Top Movers

- Five slots on the home page (1st through 5th).
- Populated by creators with the largest weekly composite Display Score growth.
- Computed from `score_history` deltas over the trailing 7 days.
- Updated continuously throughout the week (not locked weekly like Champions).
- This is what `compute-spotlight` should evolve toward — token-activity ranking is the current
  legacy implementation; Top Movers is the canonical replacement when we wire it up.

### Home Page Layout

The current single Spotlight strip (carousel + 2nd–5th rank sidebar) must eventually become two
strips, both labeled. Do not implement the layout change now — it ships with Phase A Arena UI.
See TODO comment in `lib/features/home/screens/home_screen.dart`.

---

## Arena Visual Design

Canonical reference: Grok mockups Arena_1–5, April 2026 (not in repo). Base = Arena_5; power-up tracker from Arena_2/3/4.

**Base layout:** two radial-gradient orbs (left/right); center beam (score ratio — leans toward loser); score % above each orb; four corner power-up slots; player name + MM label below. Bg: #0A0A0F → #1A1A2E.

**Pass 1 — ships with Phase A:**
- Pulsing orbs: AnimationController + ScaleTransition + RadialGradient
- Center beam: animated Container by score ratio; corner slots (AnimatedOpacity + AnimatedScale); event ticker (ListView + SlideTransition); countdown timer
- Action buttons: Back P1 | Back P2 | Trigger Ability
- No particles, waveform, shaders, or BackdropFilter

**Pass 2 (post-Phase A):** particle bursts on Back (CustomPainter ≤100/orb); power-up tracker with timer rings + stack counters; orb glow by heat_influence; beam pulse.

**Pass 3 (post-launch):** waveform (CustomPainter, match data — not audio FFT); lightning arcs on high flow; Ultimate screen flash; per-archetype orb theming.

**Do not attempt:** 3D orb effects; audio FFT; shader glow (static gradients + animated opacity); real-time blur on moving orbs; real particle physics (directional bursts).

**Performance:** lerp ticks (3s, no snap); drive from `arena_state.tick` not local time; cap to one flash + stack counter per tick; pause when tabbed out; BackdropFilter sparingly; test Safari early.

**Animation source-of-truth:** derives from server `arena_state` only. Client never computes ArenaScore or predicts timing.

---

## Commands

All Flutter commands run from the `flutter_app/` directory:

```bash
# Install dependencies
cd flutter_app && flutter pub get

# Lint — must pass zero issues before every commit
cd flutter_app && flutter analyze

# Build for web (production)
cd flutter_app && flutter build web --release --no-tree-shake-icons
```

Note: This project uses plain Riverpod (FutureProvider.autoDispose / Provider).
There is NO code generation — do not use @riverpod annotations or run build_runner.

---

## Environment Setup

Copy .env.example to .env in flutter_app/ and fill in values:
```
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
```
The .env file is loaded as an asset at runtime via flutter_dotenv.

---

## Architecture

**State management:** Plain Riverpod — FutureProvider.autoDispose and Provider only.
No @riverpod annotations, no build_runner, no code generation.

**Routing:** GoRouter with PathUrlStrategy (clean URLs, no #). Unauthenticated users
redirect to /login for protected routes; authenticated + unapproved users redirect to
/pending-approval; authenticated + approved users land on /home.
Shell: `lib/core/shell/main_shell.dart` wraps shell routes with the bottom nav bar.

Complete route map:

| Route | Screen | Auth | Notes |
|-------|--------|------|-------|
| `/` | LaunchScreen | public | pre-launch countdown; redirects logged-in to /home |
| `/home` | HomeScreen | public | ShellRoute (bottom nav); header differs by auth state |
| `/news` | CelebrityHeatScreen | public | canonical route |
| `/explore` | — | public | redirects to /news (backwards compat) |
| `/hot-topic` | HotTopicScreen | public | placeholder; no bottom nav |
| `/mybets` | MyBetsScreen | **required** | standalone, no bottom nav |
| `/markets/mybets` | — | — | redirects to /mybets (backwards compat) |
| `/markets` | MarketsScreen | **required** | ShellRoute |
| `/profile` | ProfileScreen | **required** | ShellRoute |
| `/wallet` | WalletScreen | **required** | ShellRoute |
| `/search` | SearchScreen | public | ShellRoute |
| `/login` | LoginScreen | public | |
| `/signup` | SignupScreen | public | |
| `/forgot-password` | ForgotPasswordScreen | public | |
| `/pending-approval` | PendingApprovalScreen | public | beta gate |
| `/dashboard` | ScoreDashboardScreen | auth | no bottom nav |
| `/challenges` | ChallengesScreen | auth | no bottom nav |
| `/u/:username` | PublicProfileScreen | public | |
| `/markets/:id` | MarketDetailScreen | public | |
| `/join` | ReferralScreen | public | ?ref=code |
| `/privacy` | PrivacyPolicyScreen | public | |
| `/terms` | TermsOfServiceScreen | public | |
| `/plan` | PlanScreen | public | roadmap placeholder; no bottom nav |

Auth redirects: unauth + protected → /login (destination stored in pendingNavigationProvider);
logged in + unapproved → /pending-approval; logged in + approved on auth/launch page → /home.

**HomeScreen header** (`lib/features/home/screens/home_screen.dart`):
- Logged-out: hamburger | logo | Expanded(centered OutlinedButton "Learn more about Phase 2 and Phase 3" → /plan) | Login | Sign Up
- Logged-in: hamburger | logo | [Spacer] | notification bell (opens sheet) | "Get Tokens" (opens `BuyTokensSheet` in place, does NOT navigate away)

**"Explore All →"** in category tabs routes to `/markets` (not explore/news).

**HomeScreen sections** (scroll order):
1. `_WideSpotlightLayout` / `_NarrowSpotlightLayout` — wide (≥900px): carousel (flex 5) | rank sidebar (flex 2) | news+tokens panel (flex 2); narrow stacks vertically. Both use `creatorsAsync.valueOrNull ?? []`; placeholder cards fill empty slots; layout never collapses. Breaking News is static.
2. `_RisingSection` — horizontal scroll of creator tiles; 3 placeholder tiles when empty.
3. `_WhoIsLiveSection` — vertical live stream list; "No creators are live right now" when empty.
4. `_FooterLinks`

**Token purchase sheet**: `BuyTokensSheet` in `lib/features/wallet/widgets/buy_tokens_sheet.dart`.
Invoke via `showBuyTokensSheet(context)`. Used by wallet screen and home screen header.

**Feature structure:** Each feature lives in `lib/features/<name>/` with subdirectories
screens/, widgets/, providers/, and models/.

**Supabase calls:** Direct client calls inline in providers. Mutation logic uses action
classes (e.g. ProfileActions, NotificationActions). No edge functions called from providers
except OAuth initiation.

**Widgets:** Private classes (_WidgetName) defined at bottom of screen file.

**Error handling:** try/catch with if (mounted) guard + ScaffoldMessenger snackbar.

**Domains:** All profile share links and referral links use `noraplatforms.com`.
Do not use `nora-platforms.vercel.app` anywhere.

**React landing app** — deleted. Flutter's HomeScreen is the sole home page. Vercel catch-all routes everything except `/privacy`, `/terms`, `/tiktok-verification` to `/index.html`.

**Burger Menu** (`_SideDrawer` in `home_screen.dart`): user card (logged-in → `/profile`, guest → `/login`); NAVIGATE items: Dashboard (`/dashboard`), Profile (`/profile`), My Bets (`/markets/mybets`), Wallet (`/wallet`), Hot Topic (`/explore`), Challenges (`/challenges`). Auth-required items redirect to `/login` with `pendingNavigationProvider`. Support: Settings + Help (placeholder). All nav via `context.go()`.

---

## Creator Category System

Two-tier structure. The flat 14-category list is fully retired as of migration 024.

**profiles table columns:**
- `category_1` TEXT — one of 10 primary categories (CHECK constraint). Nullable.
- `subcategory` TEXT — role-specific label within the primary. No CHECK constraint. Nullable.
- `category_2` — column exists but is always NULL; ignored by all app code.

**10 primary categories and their subcategories:**

| Primary | Subcategories |
|---------|--------------|
| Athlete | Basketball, Football, Golf, Tennis, Baseball, Lacrosse |
| Musician | Guitarist, Singer, Drummer, Violinist, DJ, Pianist |
| Healthcare | Geneticist, Nurse, Surgeon, Hospitalist, Doctor General, Researcher |
| Performer | Comedian, Dancer, Magician, Podcaster |
| Gamer | Competitive, Developer, Streamer, Tabletop, PC, Console |
| Influencer | Fitness, Travel, Vlog, Food, Prankster, Journalist, Commentator |
| Educator | Author, Teacher, Professor, Expert |
| Politician | City Council, State Senate, Congress, Governor, Other |
| Religion | Bishop, Deacon, Minister, Priest, Pastor, Rabbi, Guru, Yogi |
| Business | Startup, Retail, Non Profit, Small Business, Niche, Handmade, Corporation |

`kPrimaryCategories` and `kSubcategories` constants live in `lib/core/constants/creator_categories.dart`.

**Markets Screen** (`lib/features/markets/screens/markets_screen.dart`): filter tabs (Live Now | All | 10 primary categories); vertically scrolling subcategory sections each with a horizontal scroll of circular creator cards; 90px CircleAvatar with username-hash color; live ring = `Border.all(color: Color(0xFFFF4757), width: 3)` + LIVE chip; tap → `/u/:username`. Live Now tab: single horizontal row of all live MMs.

---

## Score Architecture — DO NOT MODIFY WITHOUT FULL UNDERSTANDING

`platform_metrics` has two active score columns (migration 019 dropped `resolution_score`):

### display_score — bigint, additive raw points
- Per-platform point total. Each connected platform has its own row.
- Sum across all a creator's `platform_metrics` rows = their composite Display Score.
- Adding a new platform always increases the total (never normalized or averaged).
- NEVER modified by promotions, power-ups, or any user action.
- Used as the resolution metric: resolve-markets sums all platform_metrics.display_score rows
  for the creator and compares to `opening_resolution_score` (the snapshot taken at market open).

**Point values per metric (all platforms):**

| Metric | Points |
|--------|--------|
| 1 follower / subscriber | 1 pt |
| 1 live viewer | 10 pts |
| 24h follower growth | 5 pts per new follower |
| 1 X post view | 0.1 pts |
| 1 X repost | 3 pts |
| 1 X like | 1 pt |
| 1 Spotify saved track | 3 pts |
| 1 Spotify saved album | 3 pts |

YouTube/Twitch: followers×1 + live_viewers×10 + 24h_growth×5
X (Twitter): followers×1 + post_views×0.1 + post_reposts×3 + post_likes×1
Spotify: followers×1 + saved_tracks×3 + saved_albums×3

**Spotify column reuse:** `recent_post_views` stores saved tracks count; `recent_post_reposts`
stores saved albums count. These columns are NOT X-exclusive — always check platform context.

### heat_score — 0–100, boost-only, baseline 0
- Baseline is 0. Only active boost deltas from `active_boosts` move it.
- What all UI and spotlight reads. CAN be modified by promotions/power-ups.
- Computed as: `CLAMP(SUM(active boost deltas where not expired/cancelled), 0, 100)`
- Spotlight trigger fires on `heat_score` updates (not display_score).

Dropped columns (do not reference): `resolution_score` (dropped migration 019), `power_up_cooldowns` table, `platform_metrics.spotlight_pinned_until`, `profiles.accepts_new_markets`, `profiles.token_balance`. See docs/ARCHIVE.md for context.

### markets table snapshots at open:
- `opening_resolution_score` — stores the composite display_score (bigint sum) at market creation.
  Despite the name, this is the additive Display Score snapshot, not the old resolution_score.
  Locked forever after market open.
- `opening_heat_score` — heat_score at time of market creation. Locked forever.

### Market resolution logic:
resolve-markets sums all `platform_metrics.display_score` rows for the creator at resolution time.
Compares current composite vs `opening_resolution_score`. above/below/tie→refund.
Void conditions: missing metrics, tied score, or no bets on the winning side → full refund.

---

## Score Hierarchy & Roles

How every score in the system relates to every game. Read this before touching any score logic.

| Score | Where stored | Modified by | Role |
|-------|-------------|-------------|------|
| Display Score (composite) | `platform_metrics.display_score` (bigint, sum across platforms) | `sync-platform-metrics` only | Drives Market resolution. Drives Top Movers Spotlight. NOT used in Arena. |
| Heat Score | `platform_metrics.heat_score` (0–100) | Promotions and power-ups only | UI-facing popularity number. Read by Arena to compute HeatInfluence term. Not modified by Arena. |
| Momentum Score | `platform_metrics.momentum_score` (to be added) | Arena match wins/losses + weekly decay + Spotlight reset | Persistent Arena win-streak signal. Feeds MomentumCarry term in ArenaScore. Resets to 0 on Spotlight win. |
| ArenaScore | In-memory `arena_state.score_p1` / `score_p2` | Tick loop only | Live in-match score. Decides match winner. Does not persist after match end. |
| Weekly Arena Points | New table or column (to be added) | Match win deposits + Monday reset | Determines Round 3 qualification. Resets weekly. |
| Round 3 placement | `arena_matches` (Round 3 match outcomes) | Round 3 match outcomes | Directly determines Arena Champions Spotlight slots. |

`resolution_score` no longer exists. It was dropped in migration 019. Composite Display Score
absorbed its job for Market resolution. Do not reference `resolution_score` in any new code,
comment, or documentation.

---

## Supabase Schema

All tables have RLS enabled. Migrations run in order:

| Migration | Key additions |
|-----------|--------------|
| 001 | profiles (with is_creator), social_connections, markets, bets, balances, transactions |
| 002 | token_balances, token_transactions, spotlight_scores; triggers |
| 003 | notifications; is_market_maker, pending_opt_out, referral_code, referred_by on profiles |
| 004 | bet constraints; triggers: pool update, token deduct, notify |
| 005 | platform_connections, platform_metrics; RLS |
| 006 | heat_score + resolution_score on platform_metrics (later dropped); opening_resolution_score + opening_heat_score on markets |
| 007 | token_purchases table for Stripe integration |
| 008 | Bug fixes and schema corrections |
| 009 | resolved_at, resolution_result, resolved_outcome on markets; 'refund' token type |
| 010 | duration_label on markets |
| 011 | Re-applies token_transactions type constraint with 'refund' |
| 012 | market_series, market_event, market_identifier, category_1, category_2 on markets + profiles |
| 013 | Rename score columns: heat_score↔display_score swap + opening_display_score→opening_heat_score |
| 014 | active_boosts table for Phase 6 promotions |
| 015 | promotion_banners table (Realtime-enabled) |
| 016 | badge_definitions, challenge_definitions, user_badges, user_challenge_progress, user_streaks; 19 challenges + 21 badges seeded; 'challenge_reward' token type |
| 017 | user_passive_effects view |
| 018 | 'passive_bonus' token type; heat_score_leader_since on platform_metrics; evaluate_main_character_badge() DB function + hourly pg_cron job 'main-character-check' |
| 019 | display_score → bigint; previous_follower_count added; heat_score reset to 0 (boost-only baseline); resolution_score DROPPED; score_history table created; snapshot trigger fixed to use composite display_score |
| 020 | recent_post_views, recent_post_reposts, recent_post_likes columns on platform_metrics (X integration) |
| 021 | is_approved on profiles; approve_beta_user() DB function; handle_new_user() updated to auto-approve waitlisted emails |
| 022 | waitlist table (email UNIQUE, anon INSERT open, no anon SELECT) |
| 023 | public_platform_connections view (safe public read, is_active=true filter) |
| 024 | Two-tier category system: category_1 → 10 primaries; subcategory column added; old flat categories retired |

### Key table notes
- `profiles`: has `is_creator` (migration 001, compute-spotlight), `is_market_maker` (migration 003, Flutter/markets), and `is_approved` (migration 021, beta gate; redirects to /pending-approval). All separate flags.
- `token_balances`: separate table (NOT a column on profiles). Holds `available_tokens` (integer).
- `platform_metrics`: has `previous_follower_count` (bigint) for 24h growth delta tracking.
- `active_boosts`: handles cooldown enforcement (no separate `power_up_cooldowns` table).
- `waitlist`: table name is `waitlist` (NOT `waitlist_emails`). Anon INSERT allowed; no anon SELECT (count shown in UI uses a hardcoded floor).
- `score_history`: time-series snapshots. Columns: user_id, composite_score (bigint), recorded_at.

### token_transactions type constraint (migration 018, final)
```
'signup_bonus', 'bet_placed', 'bet_won', 'bet_lost', 'refund',
'promoted', 'referral_bonus', 'purchase', 'purchased',
'challenge_reward', 'passive_bonus'
```

### Key RLS rules
- token_balances — service role only for writes
- token_transactions — service role only for inserts
- notifications — service role only for inserts
- markets — no client-side UPDATE; pool sizes via DB trigger only
- platform_connections — service role writes; users read own rows
- platform_metrics — service role writes; users read own + public reads is_live rows
- score_history — service role writes; public read
- waitlist — anon INSERT; no anon SELECT

### user_passive_effects view (migration 017)
`visibility_multiplier` (additive sum), `token_earn_rate` (additive sum), `promotion_discount` (max across badges), `referral_bonus` (max tier). Read-only at query time — never written back to any table.

---

## Platform Integrations

| Platform | Status | Notes |
|----------|--------|-------|
| YouTube | ✅ Live | Google verification in review — only whitelisted emails can connect until approved |
| Twitch | ✅ Live | Re-auth silently skips consent (handled by already-connected sheet) |
| X (Twitter) | ✅ Live | OAuth + metrics sync live |
| Spotify | ✅ Live | Premium Web API; saved tracks + albums as score metrics |
| TikTok | Submitted | 1–4 week review; secrets NOT yet in Supabase. Do not build until API approved. |
| Instagram | Blocked | Meta SMS verification required — retry from mobile browser |
| Kick | Deferred | No official API yet |

OAuth redirect URIs all use `noraplatforms.com/auth/callback`.

---

## Edge Functions

All deployed manually with `--no-verify-jwt`. Auth verified internally.
Supabase project uses ES256 (asymmetric) JWTs — HS256 runtime verification always fails.

| Function | Purpose |
|----------|---------|
| oauth-initiate | Generates OAuth URLs for YouTube, Twitch, X, Spotify with HMAC-signed CSRF state |
| oauth-callback | Verifies state, exchanges code for tokens, stores connection, triggers sync |
| sync-platform-metrics | Fetches live data from all 4 platforms; computes per-platform display_score (bigint additive); updates heat_score as sum of active boost deltas (baseline 0); writes score_history. MUST stay a single function — never split per platform. Handles token refresh. 4-minute cooldown per connection. |
| disconnect-platform | Revokes OAuth tokens, deletes connection (cascades to metrics) |
| resolve-markets | Resolves expired markets: sums current display_score across all platforms vs opening_resolution_score; distributes payouts (10% rake: 5% platform + 5% MM); handles voids/refunds; fires evaluate-challenges hooks; applies token_earn_rate passive bonus (passive_bonus type) |
| apply-promotion | Full promotion/power-up catalogue; enforces cooldowns via active_boosts query; stacks badge promotion_discount + MM discount multiplicatively; fires evaluate-challenges hooks; awards Power Tripped + Untouchable badges directly |
| evaluate-challenges | Full condition engine (count_threshold, snapshot, streak, composite, manual); accepts user JWT or service role; idempotent; awards tokens + badges; fires from Flutter (check_in, bet_placed) and other edge functions |
| compute-spotlight | Computes spotlight scores based on token activity (tokens_bet×1 + tokens_promoted×1.5 + unique_bettors×2 + 24h_activity×1.25); queries is_creator=true profiles; upserts spotlight_scores; calls recompute_spotlight_tiers() DB function |
| create-checkout-session | Validates auth, creates Stripe hosted checkout, inserts pending token_purchases row |
| stripe-webhook | Verifies Stripe HMAC signature, idempotency check, credits tokens via increment_token_balance RPC |

`main-character-check` — pg_cron job (migration 018); calls `evaluate_main_character_badge()` hourly; awards 150T + badge after 24h as #1 heat_score.

### Deploying edge functions
```bash
export SUPABASE_ACCESS_TOKEN=your_token
npx supabase functions deploy <function-name> --project-ref cceisywxwhgljdpisjrl --no-verify-jwt
```

IMPORTANT: Never paste SUPABASE_ACCESS_TOKEN into Claude Code. Run deploy commands in your terminal. Rotate token at supabase.com/dashboard/account/tokens.

### Edge Function Secrets (set in Supabase Dashboard → Edge Functions → Secrets)
```
YOUTUBE_CLIENT_ID / YOUTUBE_CLIENT_SECRET
TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET
X_CLIENT_ID / X_CLIENT_SECRET
SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET
APP_URL               https://noraplatforms.com
OAUTH_STATE_SECRET
STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET
SYNC_SECRET           (sync-platform-metrics alt auth)
```

---

## Deployment

Push to main triggers GitHub Actions → Flutter web build → Vercel deploy. GitHub secrets: VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID, SUPABASE_URL, SUPABASE_ANON_KEY. `vercel.json` rewrites all paths to `/index.html`; static exceptions: `/privacy`, `/terms`, `/tiktok-verification`.

---

## Opening URLs in Flutter Web

Use `openUrlInBrowser(url)` from `lib/core/utils/open_url.dart` (NOT url_launcher directly). Web impl: `window.open(url, '_blank')`. Non-web: url_launcher fallback.

---

## Theme Colors (AppTheme)

primary #6C63FF · secondary #03DAC6 · success #00C896 · danger #FF4757 ·
background #0A0A0F · surface #1A1A2E · surfaceLight #16213E · textPrimary white ·
textSecondary #8B8FA8 · cardBorder #2A2A3E

---

## Current Build Status

### Completed phases (full details in docs/ARCHIVE.md)
- **Phases 1–3.5**: Auth, token economy, home/discover/wallet/profile, markets, betting, YouTube + Twitch OAuth, pg_cron sync.
- **Phase 4 — Stripe**: Token purchase sheets, create-checkout-session + stripe-webhook, deep link handling.
- **Phase 5 — Market Resolution**: resolve-markets edge function, market detail countdown/resolving states, bet blocking.
- **Post-Phase-5 — Public Profile**: /u/:username screen, publicProfileProvider, preview + promote buttons.
- **Phase 6 — Promotions & Power-Ups**: active_boosts, apply-promotion, all promo/sabotage sheets, PromotionFlashBanner, HomeTicker.
- **Phase 7 — Challenges & Badges**: migrations 016–018, evaluate-challenges, BadgesShelf, ChallengesScreen, passive effects.
- **Phase 8 — Scoring Redesign**: display_score→bigint, resolution_score dropped, score_history, ScoreDashboard.
- **Post-Phase-7 Platform Additions**: X + Spotify OAuth, public_platform_connections view, beta approval gate.
- **Pre-Launch — Cover Screen**: LaunchScreen countdown, waitlist table (migration 022).

**OG/Early Adopter cutoffs already set in DB — DO NOT re-run.** OG = 2026-07-04T04:00:00Z, Early Adopter = 2026-08-03T04:00:00Z.

### Known Issues
- YouTube OAuth in Google Testing mode — only whitelisted emails can connect until verified.
- Profile pictures deferred — avatar from connected social account (not yet built). No manual upload.
- All edge functions deployed manually (not auto-deployed from GitHub).
- TikTok secrets NOT in Supabase — do not build until API review completes.
- Google Cloud $300 credit is time-limited — needs activation.

---

## Outstanding Items — Priority Order

### Must do before launch
1. **Get Tokens two-step flow** — news-panel only: Purchase → buy sheet; Earn → 4 options (Arena, Hot Topic, Chicken Run, Ball Bounce). Header button unaffected.
2. **Spotify OAuth end-to-end test** — confirm metrics sync writes display_score and score_history correctly.
3. **RLS policy audit** — verify individual policy rules (`pg_policies WHERE schemaname='public'`).
4. **Supabase access token rotation** — rotate at supabase.com/dashboard/account/tokens; use `! export SUPABASE_ACCESS_TOKEN=...`.

### High priority
5. **Onboarding walkthrough** — PageView, 4–5 slides, skippable, re-accessible from Settings.
6. **UI audit pass** — inconsistencies pass before onboarding is built.
7. **Profile avatars** — pull from connected platform data; display on profile + circular market cards.

### Medium priority
8. **Hot Topic content** — /hot-topic is currently a placeholder.
9. **News/activity feed** — currently static placeholders in home + /news.
10. **Weekly Spotlight wiring** → Arena Champions Round results.
11. **Plan/Roadmap content** at /plan.
12. **Google Cloud activation** — $300 credit, limited days.
13. **Cloudflare SSL** — confirm Full (strict) mode.

---

## Deferred Features — Do Not Build Until Instructed

### Arena System (Post-Launch — Major Subsystem)
Real-time competitive layer. 3 rounds, 5-minute matches, audience-driven. Uses velocity/relative movement — NOT raw display_score (prevents large creators auto-winning).

**Round structure and scheduling windows:**
- Round 1 — Discovery: 7 AM–7 PM daily. Same-category matchups. 1 pt/win.
- Round 2 — Chaos: 7 PM–7 AM daily. Cross-category matchups. 2 pts/win.
- Round 3 — Champions: Friday 7 PM → Sunday midnight. Weekly top performers only. 5 pts/win.
  Winners occupy Spotlight the following week.

**ArenaScore formula:**
`ArenaScore = BaseFlow + HeatInfluence + AbilityImpact + MomentumSpike + MomentumCarry − SuppressionEffects`

Token actions: **Back** (at-risk backing; 90% pool share on win, lost on loss) and **Trigger** (consumed power-ups/abilities; not returned). No Shift action. No third loop. See Two-Game Architecture for canonical definitions.

Existing power-ups reinterpreted (not replaced): +Popularity → HeatInfluence weight;
Universe → global flow rate; Galaxy → same-category flow rate; −Popularity → opponent efficiency;
Black Hole → cancels Universe/Galaxy + AbilityImpact suppression; SMBH → volatility spike both sides.

Stacking rule: EffectiveMultiplier = Base × (1 + log(1 + n)) — prevents exponential abuse.

**10 Archetypes** (one per primary category): 1 Passive, 2 Core (30–60s CD), 1 Signature (2–4min), 1 Ultimate (1/match). Abilities modify multipliers/windows only. Subcategories ±5–10% one stat.

**Spotlight Reset & Momentum Carry (canonical — implement in Phase A):**
`momentum_score` column on `platform_metrics`; Arena wins deposit (losses don't subtract); linear weekly decay; cap TBD in Phase A. MomentumCarry reads it at match start. Spotlight rotation: the Monday after holding a slot, reset both `heat_score` and `momentum_score` to 0 — reward is visibility + points already earned, not a compounding advantage. Non-Spotlight winners carry `momentum_score` forward.

**New tables needed:** arena_matches, arena_events, arena_state.
**Build order:** Phase A (DB + cron engine) → Phase B (Flutter UI) → Phase C (Spotlight wiring).

**Games (Separate Project)**: Ball Bounce (endless flyer), Chicken Run (multiplier risk), Dragon egg idle game. Ad token faucet (3× reward). Daily caps: 8 ads/game, 150 tokens across all games.

**Future Platform Integrations**: TikTok (API review, do not build yet), Instagram (blocked on Meta SMS verification), Kick (no API), X Spaces (if API opens).

**Marketing Campaign**: launch-day dragon/phoenix hatching animation + rocket engines on countdown page. Do not build until assets provided.

---

## Riverpod Providers (key list)

All plain — no code generation.

- `currentUserProvider` — auth state
- `userBadgesProvider(userId)` — BadgesShelf
- `challengeProgressProvider(userId)` — ChallengesScreen
- `passiveEffectsProvider(userId)` — reads user_passive_effects view
- `scoreHistoryProvider` (family by userId + period) — ScoreDashboard
- `activeBoostsProvider(userId)` — power-ups sheet cooldown state
- `promotionEligibilityProvider(userId)` — promotion discount/multiplier banners
- `spotlightCreatorsProvider` — home screen spotlight (pinned spotlight_entry first, then effective_score)
- `risingCreatorsProvider` — Rising tab, sorted by effective_score
- `liveMetricsFeedProvider` — Who's Live tab, sorted by effective_score
- `marketMakersProvider` — markets screen, filters `is_market_maker=true AND pending_opt_out=false`
- `unreadCountProvider` — notification bell
- `myBetsProvider` — My Bets screen
- `publicProfileProvider` — /u/:username (queries public_platform_connections view)

---

## Token Economy Principles (read before touching any token logic)
- Tokens are purely internal promotion fuel — no real-world cash value ever
- heat_score capped 0–100 always
- heat_score = what users see (boost-only; baseline 0)
- display_score = additive bigint raw points (never modified by promotions/power-ups)
- 10% betting rake: 5% to platform, 5% to Market Maker pool
- Integer balances only — no decimals in token_balances
- Every token movement logged immutably in token_transactions with type + reference_id
- ON CONFLICT DO NOTHING everywhere badges are inserted

---

## Test Account System

Test accounts are synthetic Market Makers (`profiles.is_test_account = true`) used to seed dev data without polluting real user queries. Filtered from all public-facing surfaces.

### Column additions (migration 025)
- `profiles.is_test_account` — boolean NOT NULL DEFAULT false. Index on (is_test_account).
  Protected by trigger: only service_role can set this to true.
- `platform_connections.is_test_account` — mirrors the flag; sync-platform-metrics skips
  any connection where this is true.

### Production filter rule
**Default: test accounts EXCLUDED from all user-facing queries.** Edge functions check `INCLUDE_TEST_ACCOUNTS === 'true'` to opt in — MUST NOT be set in production. Flutter providers always filter `is_test_account = false`.

Surfaces that filter test accounts (`.eq('is_test_account', false)`): `marketMakersProvider`, `risingCreatorsProvider`, `compute-spotlight` (profiles query); `sync-platform-metrics` (connections query); `evaluate-challenges` (early exit); `evaluate_main_character_badge()` (excludes from #1 heat scan).

Do NOT filter (by design): `/u/:username`, `resolve-markets`, `marketDetailProvider`.

### Seeded test accounts (migration 026, applied)
20 creators, 2 per primary category. UUIDs `10000000-0000-0000-0000-000000000001` through `…000020`. Username pattern: `test_<category>_<subcategory>_1` (e.g. `test_athlete_basketball_1`). All `is_market_maker=true`, `is_test_account=true`, 1000 tokens, one synthetic YouTube connection per account. Full list in migration 026.

### Teardown (migration 027, committed but NOT applied)
`027_teardown_test_accounts.sql` deletes all test account rows in FK order, wrapped in a
transaction, idempotent. Run manually as part of the pre-launch reset.

Do NOT:
- Sign in as test accounts via the UI
- Give test accounts a real Stripe customer ID
- Give test accounts real OAuth tokens
- Set `INCLUDE_TEST_ACCOUNTS=true` in production

---

## Pre-Launch Full Reset (run manually before July 4, 2026)

Run each step manually and confirm before moving to the next. Gate each one.

1. **Run `027_teardown_test_accounts.sql`** — removes all test accounts and their FK chain.
2. **Truncate Arena tables** (when they exist): `arena_matches`, `arena_events`, `arena_state`.
   Wipes all match history from beta testing.
3. **Reset real user tokens:**
   - Zero out `token_balances` (set `available_tokens = 0, lifetime_earned = 0`).
   - Truncate `token_transactions`.
   - Truncate `token_purchases`.
   - Assumption: pre-launch users are beta testers. Confirm this before running.
4. **Clear challenge and badge state:** truncate `user_badges`, `user_challenge_progress`, `user_streaks`.
   Badge and challenge progress starts fresh at launch.
5. **Clear market history:** truncate `bets`, `markets`, `score_history`.
6. **Clear promotion state:** truncate `active_boosts`, `promotion_banners`.
7. **Keep** `profiles` and `platform_connections` — real users keep their accounts and
   platform connections through launch.
8. **Keep** `waitlist` — untouched.
9. **Do NOT re-run** OG/Early Adopter badge cutoff migration — already set in DB to
   `2026-07-04T04:00:00Z`. Do not run again.
10. **Re-grant signup bonuses** after reset: run `increment_token_balance(user_id, 100)` for
    every real user so they start launch day with their 100 token welcome bonus.

---

## Hard Implementation Rules

1. Plain Riverpod only — no code generation, no @riverpod, no build_runner.
2. `sync-platform-metrics` stays a single Edge Function — never split per platform.
3. Never modify `display_score` outside `sync-platform-metrics`. Never modify `heat_score` outside `sync-platform-metrics` (which sums active_boosts). Never reference `resolution_score` — it does not exist.
4. All token awards logged in `token_transactions` with appropriate type and reference_id.
5. ON CONFLICT DO NOTHING everywhere badges are inserted (user_badges has UNIQUE(user_id, badge_id)).
6. Passive effects are read-only at query time — never written back to any table.
7. Handle API rate limits (HTTP 429) gracefully — log and skip, do not throw.
8. Never hardcode API keys — use Supabase Edge Function secrets and Vercel env vars only.
9. `noraplatforms.com` everywhere — no vercel.app references anywhere.
10. Read every file in full before modifying it.
11. `flutter analyze` must pass zero issues before every commit.
12. `accepts_new_markets` column does not exist — use `is_market_maker=true AND pending_opt_out=false`.
13. `power_up_cooldowns` table does not exist — cooldowns enforced via active_boosts queries.
14. `spotlight_pinned_until` column does not exist on platform_metrics — spotlight pinning uses active_boosts (spotlight_entry type).
15. Test accounts (`is_test_account=true`) must be filtered from all ranking/discovery queries. Flutter providers always add `.eq('is_test_account', false)`. Edge functions check `INCLUDE_TEST_ACCOUNTS` env var (default: filter ON). Never set `INCLUDE_TEST_ACCOUNTS=true` in production.
16. Arena and Markets are independent reward loops. Do not design any feature that grants Arena progress as a result of a Market outcome, or vice versa.
17. Arena does not modify `display_score`, `heat_score`, or `token_balances` outside of: (a) Back action — debits tokens at action time, credits 90% pool share at match end if winning side, lost otherwise; (b) Trigger action — debits tokens at action time, never returned; (c) Match resolution — writes `momentum_score`, writes weekly Arena points, fires evaluate-challenges.
18. ArenaScore is an in-memory match-only value. Do not persist it after match end. Only `winner_id` and final scores are recorded in `arena_matches`.
19. Spotlight has two distinct sections (Arena Champions, Top Movers). When `compute-spotlight` is updated, it must produce both rankings independently.
