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
1. `_WideSpotlightLayout` / `_NarrowSpotlightLayout` — 3-column spotlight layout from `spotlightCreatorsProvider`
   - Wide (≥900px): carousel (flex 5) | rank sidebar (flex 2) | news+tokens panel (flex 2); 12px gaps; wrapped in `ConstrainedBox(minHeight: 420)`
   - Narrow: stacked vertically; also wrapped in `ConstrainedBox(minHeight: 420)`
   - Both layouts use `creatorsAsync.valueOrNull ?? []` — loading and empty states show placeholder content immediately; layout never collapses
   - Carousel: `_SpotlightCard` (real data, height 400 wide / 300 narrow) or `_SpotlightPlaceholderCard` when empty/loading
   - Rank sidebar: always renders exactly 4 cards (2nd–5th). Real creators use `_RankCard` (white10 border, 64px, CircleAvatar). Missing slots use `_PlaceholderRankCard`
   - News panel (`_NewsPanel`) and Get Tokens button (`_GetTokensButton`) render outside the data guard — always visible regardless of creator data
   - Breaking News is static placeholder (3 hardcoded headlines). See `// TODO: wire to news API` in code.
2. `_RisingSection` — horizontal scroll of creator tiles; shows 3 `_RisingPlaceholderTile` widgets when empty
3. `_WhoIsLiveSection` — vertical list of live streams; section header always visible; "No creators are live right now" when empty
4. `_FooterLinks`

**Token purchase sheet**: `BuyTokensSheet` in `lib/features/wallet/widgets/buy_tokens_sheet.dart`.
Invoke via `showBuyTokensSheet(context)`. Used by wallet screen and home screen header.
The news-panel "Get Tokens" button currently goes directly to `showBuyTokensSheet` — a two-step
flow (Purchase vs Earn modal) is a planned but not-yet-built outstanding item.

**Feature structure:** Each feature lives in `lib/features/<name>/` with subdirectories
screens/, widgets/, providers/, and models/.

**Supabase calls:** Direct client calls inline in providers. Mutation logic uses action
classes (e.g. ProfileActions, NotificationActions). No edge functions called from providers
except OAuth initiation.

**Widgets:** Private classes (_WidgetName) defined at bottom of screen file.

**Error handling:** try/catch with if (mounted) guard + ScaffoldMessenger snackbar.

**Domains:** All profile share links and referral links use `noraplatforms.com`.
Do not use `nora-platforms.vercel.app` anywhere.

### React Home App — RETIRED

The React app (`landing/` directory) has been deleted. Flutter's `HomeScreen` is the
sole home screen. Vercel routes all paths (except `/privacy`, `/terms`,
`/tiktok-verification`) to Flutter's `index.html` via a single catch-all rewrite.

### Burger Menu (Side Drawer)

Defined in `home_screen.dart` as `_SideDrawer`. Structure:

**TOP** — User card:
- Logged in: colored-initial avatar, username, "Tap to view profile" → `/profile`
- Logged out: person icon, "Guest", "Sign in for full access" + "Sign in →" button → `/login`

**NAVIGATE** section:
| Label | Subtitle | Route | Auth required |
|-------|----------|-------|---------------|
| Dashboard | Market Maker hub | /dashboard | ✓ (MM Only badge if isMarketMaker) |
| Profile | Your public profile | /profile | ✓ |
| My Bets | Active & past bets | /markets/mybets | ✓ |
| Wallet | Tokens & transactions | /wallet | ✓ |
| Hot Topic | Trending this week | /explore | public |
| Challenges | Daily & weekly goals | /challenges | ✓ |

**SUPPORT** section: Settings (placeholder), Help (placeholder)

**Footer**: "v1.0.0 — Phase 1" left · "NORA" right (muted accent)

Unauthenticated users tapping auth-required items are redirected to `/login` with
`pendingNavigationProvider` set so they return to their destination after login.
All nav uses `context.go()` — nothing leaves the Flutter app.

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

**Old → new migration mapping (applied in migration 024):**
Comedian→Performer/Comedian · Doctor→Healthcare/Doctor General · Researcher→Healthcare/Researcher ·
Fitness→Influencer/Fitness · Sports→Athlete/(subcategory null, flag for reselection)

`kPrimaryCategories` and `kSubcategories` constants live in
`lib/core/constants/creator_categories.dart`. The old `kCreatorCategories` flat list is retired.

**Markets Screen** (`lib/features/markets/screens/markets_screen.dart`):
- Queries `profiles` where `is_market_maker=true AND pending_opt_out=false` via `marketMakersProvider`
- Filter tabs: Live Now | All | + 10 primary categories; counts show Market Makers per category
- Content: vertically scrolling subcategory sections, each with a horizontal scroll of circular creator cards
- Circular card: 90px CircleAvatar with username-hash color, `@username` label, subcategory label below
- Live ring: `Border.all(color: Color(0xFFFF4757), width: 3)` + LIVE badge chip
- Tapping a card navigates to `/u/:username`
- Live Now tab: single horizontal row of all live MMs, no subcategory grouping

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

### resolution_score — DROPPED (migration 019)
- This column no longer exists on `platform_metrics`. Do not reference it.
- Market resolution now uses composite `display_score` (sum across all platforms).

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
- `profiles`: has both `is_creator` (migration 001, used by compute-spotlight) and `is_market_maker` (migration 003, used by Flutter app and markets queries). These are separate flags.
- `profiles`: has `is_approved` (migration 021) for beta gate. Users redirected to /pending-approval until approved.
- `token_balances`: separate table (NOT a column on profiles). Holds `available_tokens` (integer).
- `platform_metrics`: has `previous_follower_count` (bigint) for 24h growth delta tracking.
- `active_boosts`: handles cooldown enforcement — no separate `power_up_cooldowns` table exists. Cooldowns are checked by querying active_boosts for existing non-expired entries.
- `waitlist`: table name is `waitlist` (NOT `waitlist_emails`). Anon INSERT allowed; no anon SELECT (count shown in UI uses a hardcoded floor).
- `score_history`: time-series snapshots for Robinhood-style dashboard chart. Columns: user_id, composite_score (bigint), recorded_at.

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
Aggregates per-user passive badge effects:
- `visibility_multiplier` — additive sum
- `token_earn_rate` — additive sum
- `promotion_discount` — max across badges
- `referral_bonus` — max tier across badges

Passive effects are read-only at query time — never written back to any table.

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

**`main-character-check`** is NOT an edge function. It is a `pg_cron` job (registered in migration 018)
that calls the `evaluate_main_character_badge()` DB function hourly. Awards 150T + badge after
24h consecutive #1 heat_score.

### Deploying edge functions
```bash
export SUPABASE_ACCESS_TOKEN=your_token
npx supabase functions deploy <function-name> --project-ref cceisywxwhgljdpisjrl --no-verify-jwt
```

IMPORTANT: Never paste SUPABASE_ACCESS_TOKEN into Claude Code chat. Run deploy
commands directly in your terminal tab. Rotate token at
supabase.com/dashboard/account/tokens before sharing repo access.

### Edge Function Secrets (set in Supabase Dashboard → Edge Functions → Secrets)
```
YOUTUBE_CLIENT_ID / YOUTUBE_CLIENT_SECRET
TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET
X_CLIENT_ID / X_CLIENT_SECRET
SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET
APP_URL               https://noraplatforms.com
OAUTH_STATE_SECRET
STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET
SYNC_SECRET           (for sync-platform-metrics auth header alternative)
```

---

## Deployment

Push to main triggers GitHub Actions (.github/workflows/deploy.yml) which builds
Flutter web and deploys to Vercel.

Required GitHub secrets: VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID,
SUPABASE_URL, SUPABASE_ANON_KEY.

vercel.json rewrites all paths to /index.html for SPA routing.
Static exceptions: /privacy, /terms, /tiktok-verification serve static HTML directly.

---

## Opening URLs in Flutter Web

Do NOT use url_launcher directly for OAuth or external URLs. Use the custom utility:
- lib/core/utils/open_url.dart (conditional export)
- lib/core/utils/open_url_web.dart (uses window.open(url, '_blank'))
- lib/core/utils/open_url_stub.dart (url_launcher fallback for non-web)

Call openUrlInBrowser(url) from open_url.dart everywhere.

---

## Theme Colors (AppTheme)

primary #6C63FF · secondary #03DAC6 · success #00C896 · danger #FF4757 ·
background #0A0A0F · surface #1A1A2E · surfaceLight #16213E · textPrimary white ·
textSecondary #8B8FA8 · cardBorder #2A2A3E

---

## Current Build Status

### Completed (Phases 1–3.5)
- Auth: signup, login, forgot password, username selection
- Token economy: 100 signup bonus, referral system (+25 tokens each)
- Home screen: spotlight leaderboard, famous creators carousel, notification bell
- Discover: Famous tab + Rising tab (tier badges + Live Now pulsing badge) + Who's Live tab
- Wallet: token balance, transaction history
- Profile: edit profile, Market Maker opt-in (3-step), opt-out flow
- Platform connections: YouTube + Twitch OAuth, already-connected bottom sheet
- Public profiles: /u/username route, shareable, no login required
- Referral: /join?ref=code route, tracking, bonus tokens
- Notifications: bell icon, notification center, mark as read
- Markets: Open Markets + My Bets tabs, pool ratio bars, timeago countdowns
- Betting: 4-step bottom sheet, join or create markets
- pg_cron: syncs platform metrics every 5 minutes

### Completed (Phase 4 — Stripe Token Purchases)
- create-checkout-session + stripe-webhook edge functions
- token_purchases table (migration 007)
- Wallet screen: "Get More Tokens" bottom sheet (Starter $0.99 / Popular $4.99 / Pro $9.99 / Elite $19.99)
- Deep link handling: /wallet?purchase=success and /wallet?purchase=cancelled
- Stripe webhook endpoint: https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/stripe-webhook

### Completed (Phase 5 — Market Resolution)
- resolve-markets edge function: resolves expired markets, distributes payouts, handles voids
- Market detail screen: countdown timer, "Resolving...", resolved/voided states
- Bet blocking: buttons disabled when market.status != 'open' or endAt ≤ 15s away
- MarketDetail model: resolvedAt (DateTime?), resolutionResult (String?)

### Completed (Post Phase 5 — Public Profile)
- Public profile screen (/u/:username): avatar, username, bio, category chips, Heat Score badge,
  Display Score, per-platform stats (Spotify in #1DB954), badges shelf, Promote / Power-Up buttons
- publicProfileProvider queries public_platform_connections view (migration 023) to avoid RLS block
- "Preview Profile" and "Promote" buttons on own profile screen

### Completed (Phase 6 — Promotions & Power-Ups)
- Migration 014: active_boosts table
- apply-promotion edge function: full catalogue, cooldown checks (via active_boosts query),
  discount/multiplier computation, promotion_banners for universe/galaxy
- sync-platform-metrics updated: heat_score = clamp(sum of active boost deltas, 0, 100)
- Self-boost promotions sheet (Quick Boost 80T/+8/1h, Major Boost 250T/+20/1h, Spotlight Entry 500T/4h)
- Power-ups sheet: Universe 800T/4h, Galaxy 300T/4h, +Popularity 400T/+12/1h
- Sabotage sheet: -Popularity 350T/-12/1h, Black Hole 250T, Super Massive Black Hole 800T
- MM discount (20% off self-boosts when open market exists); 1.5× delta if ≥200T in open bets
- PromotionFlashBanner overlay (MainShell); HomeTicker with Realtime subscription
- Realtime on promotion_banners verified working

### Completed (Phase 7 — Challenges & Badges)
- Migrations 016–018: 21 badges, 19 challenges, user_badges, user_challenge_progress, user_streaks,
  user_passive_effects view, evaluate_main_character_badge() DB function
- evaluate-challenges edge function: full condition engine; idempotent
- BadgesShelf widget (own profile + public profiles)
- ChallengesScreen: Daily/Weekly/Monthly tabs; challenge cards with progress bars
- /challenges route added to router
- Home screen fires daily check-in via _checkInProvider
- Bet bottom sheet fires bet_placed + bet_placed_unique_mm on successful bet
- passiveEffectsProvider(userId): reads user_passive_effects view
- Passive effects applied to feed ranking: Rising, Who's Live, Spotlight

### Completed (Phase 8 — New Scoring System, migration 019)
- display_score changed from numeric(5,2) → bigint (additive raw points per platform)
- resolution_score DROPPED — composite display_score is now the resolution metric
- heat_score baseline reset to 0 (boost-only; active boost deltas are the only driver)
- previous_follower_count added to platform_metrics for 24h growth delta
- score_history table created (Robinhood-style dashboard chart)
- Snapshot trigger fixed: opening_resolution_score now stores composite bigint display_score
- ScoreDashboard: Robinhood-style line chart with 1D/1W/1M/3M/YTD periods

### Completed (Post-Phase-7 Platform Additions)
- X (Twitter) OAuth + metrics sync (migration 020; recent_post_views/reposts/likes columns)
- Spotify OAuth + metrics sync (saved tracks/albums via column reuse of recent_post_views/reposts)
- public_platform_connections view (migration 023)
- Beta approval gate (migration 021): is_approved on profiles; approve_beta_user() DB function;
  /pending-approval route; auto-approve flow for pre-approved waitlist emails

### Completed (Pre-Launch — Cover Screen)
- Launch screen: full-page countdown to July 4, 2026 00:00:00 UTC, waitlist email signup,
  consent checkbox, legal footer links
- waitlist table (migration 022): email UNIQUE, anon INSERT open, no anon SELECT
- `/` route shows LaunchScreen when app is in pre-launch mode

### OG / Early Adopter Badge Cutoffs — ALREADY SET IN DB
```sql
-- Already applied — DO NOT re-run
UPDATE challenge_definitions
SET condition = jsonb_set(condition, '{before}', '"2026-07-04T04:00:00Z"')
WHERE slug IN ('earn_og', 'earn_early_adopter');
```
OG cutoff = midnight ET July 4, 2026. Early Adopter = '2026-08-03T04:00:00Z'.

### Known Issues / Notes
- YouTube OAuth in Google Testing mode — only whitelisted emails can connect until verified.
- Google consent screen shows supabase.co domain — expected until custom domain added.
- Profile pictures deferred: avatar comes from connected social account (not yet built).
  Currently shows first letter of username. Do not add manual upload.
- All edge functions must be deployed manually (not auto-deployed from GitHub).
- TikTok secrets NOT yet in Supabase — do not build until API review completes.
- Google Cloud $300 credit is time-limited — needs activation.

---

## Outstanding Items — Priority Order

### Must do before launch
1. **Get Tokens two-step flow** — news-panel "Get Tokens" button needs a first modal:
   Purchase → existing buy sheet; Earn → 4 options (Arena, Hot Topic, Chicken Run, Ball Bounce — no links yet).
   Note: affects only the news-panel button, NOT the header "Get Tokens" button.
2. **Spotify OAuth end-to-end test** — connect from /profile, confirm metrics sync writes display_score and score_history correctly.
3. **RLS policy audit** — RLS confirmed enabled on all tables; individual policy rules need verification:
   ```sql
   SELECT tablename, policyname, cmd, roles, qual, with_check
   FROM pg_policies WHERE schemaname = 'public' ORDER BY tablename;
   ```
4. **Supabase access token rotation** — rotate at supabase.com/dashboard/account/tokens.
   Always use `! export SUPABASE_ACCESS_TOKEN=...` in Claude Code sessions.

### High priority
5. **Onboarding walkthrough** — PageView, 4–5 slides, skippable, re-accessible from Settings. Deferred until UI is stable.
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
A real-time, audience-driven competitive layer. Market Makers compete in scheduled automated
matches across 3 rounds. Outcomes determined by token flow, Heat Score influence, timed
power-up interactions, and archetype modifiers. Uses velocity / relative movement — NOT raw
display_score (prevents large creators auto-winning).

**Match length: 5 minutes, uniform across all rounds.**
Rationale: shorter matches → more matchups per week → users can participate during a work
break or downtime. This is a deliberate design choice for participation density.

**Round structure and scheduling windows:**
Each window contains many more matches now that match duration is 5 minutes (not 1h or 30min).

- Round 1 — Discovery: 7 AM–7 PM daily. Same-category matchups. 1 pt/win.
- Round 2 — Chaos: 7 PM–7 AM daily. Cross-category matchups. 2 pts/win.
- Round 3 — Champions: Friday 7 PM → Sunday midnight. Weekly top performers only. 5 pts/win.
  Winners occupy Spotlight the following week.

**ArenaScore formula:**
`ArenaScore = BaseFlow + HeatInfluence + AbilityImpact + MomentumSpike + MomentumCarry − SuppressionEffects`

Two token actions (see Two-Game Architecture section for authoritative definitions):
- **Back** — allocate tokens to a side; at-risk; resolves 90% pool share on win or lost on loss.
- **Trigger** — spend tokens on power-ups or archetype abilities; consumed, never returned.

There is no "Shift" action and no separate bet-on-outcome mechanic. Do not add a third loop.

Existing power-ups reinterpreted (not replaced): +Popularity → HeatInfluence weight;
Universe → global flow rate; Galaxy → same-category flow rate; −Popularity → opponent efficiency;
Black Hole → cancels Universe/Galaxy + AbilityImpact suppression; SMBH → volatility spike both sides.

Stacking rule: EffectiveMultiplier = Base × (1 + log(1 + n)) — prevents exponential abuse.

**10 Archetypes** (one per primary category): each has 1 Passive, 2 Core abilities (30–60s cooldown),
1 Signature (2–4min), 1 Ultimate (1/match). Abilities modify only multipliers/windows, never raw scores.
Subcategories add light ±5–10% modifiers to one stat.

**Spotlight Reset & Momentum Carry (canonical — implement in Phase A):**

Carry mechanism: `momentum_score` column on `platform_metrics`. Decays linearly over 1 week.
Arena match wins deposit momentum points; losses do not subtract. Cap to be finalized in Phase A spec.
The MomentumCarry term in ArenaScore reads this column at match start.

Spotlight rotation rule: the Monday after a creator holds a Spotlight slot (Arena Champions),
their `heat_score` resets to 0 AND their `momentum_score` resets to 0. The Spotlight reward is
public visibility plus the weekly Arena points already earned — not a compounding advantage.
This preserves rotation. Non-Spotlight match winners carry their momentum_score into the next week.

**New tables needed:** arena_matches, arena_events, arena_state.
**Build order:** Phase A (DB + cron engine) → Phase B (Flutter UI) → Phase C (Spotlight wiring).

### Games (Separate Project)
- Flappy Bird–style endless flyer (Ball Bounce)
- Chicken/Crash–style multiplier risk game (Chicken Run)
- Dragon/Dinosaur egg hatching idle game
- Ad-supported token faucet (rewarded ads = 3× base reward)
- Daily caps: 8 rewarded ads/game, 150 free base tokens across all games

### Future Platform Integrations
- TikTok — submitted for review; do not build until API approved
- Instagram — blocked on Meta SMS verification
- Kick — no official API yet
- X Spaces metrics (if API opens up)

### Marketing Campaign
- Dinosaur egg → dragon/phoenix hatching animation on launch day
- Creature lights rocket engines on countdown page
- Do not stub or build until assets are provided

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
- resolution_score column no longer exists — composite display_score handles resolution
- 10% betting rake: 5% to platform, 5% to Market Maker pool
- Integer balances only — no decimals in token_balances
- Every token movement logged immutably in token_transactions with type + reference_id
- ON CONFLICT DO NOTHING everywhere badges are inserted

---

## Test Account System

Test accounts are synthetic Market Makers used to seed dev data and validate Arena, markets,
and other features without polluting real user queries. They are identified by
`profiles.is_test_account = true` and filtered from all public-facing surfaces.

### Column additions (migration 025)
- `profiles.is_test_account` — boolean NOT NULL DEFAULT false. Index on (is_test_account).
  Protected by trigger: only service_role can set this to true.
- `platform_connections.is_test_account` — mirrors the flag; sync-platform-metrics skips
  any connection where this is true.

### Production filter rule
**Default: test accounts are EXCLUDED from all user-facing queries.**
Edge functions check `Deno.env.get('INCLUDE_TEST_ACCOUNTS') === 'true'` to opt in.
This env var MUST NOT be set in production Supabase secrets. Flutter providers always filter
`is_test_account = false` unconditionally.

Surfaces that filter test accounts:
- `marketMakersProvider` (Flutter) — `.eq('is_test_account', false)` on profiles query
- `risingCreatorsProvider` (Flutter) — `.eq('is_test_account', false)` on profiles query
- `compute-spotlight` edge function — `.eq('is_test_account', false)` on profiles query
- `sync-platform-metrics` edge function — `.eq('is_test_account', false)` on connections query
- `evaluate-challenges` edge function — early exit if user is a test account
- `evaluate_main_character_badge()` DB function — excludes test accounts from #1 heat scan

Surfaces that do NOT filter (by design):
- `/u/:username` public profile — renders normally so we can QA the page
- `resolve-markets` — test markets resolve normally; transactions are wiped in teardown
- `marketDetailProvider` — individual market detail is fine to show

### Seeded test accounts (migration 026, applied)
20 creators, 2 per primary category, UUIDs `10000000-0000-0000-0000-000000000001` through `…000020`.
All have `is_market_maker=true`, `pending_opt_out=false`, `is_approved=true`, `is_test_account=true`.
Emails: `test+<username>@noraplatforms.com`. Token balance: 1000 tokens each.
Platform connections: one synthetic 'youtube' connection per account, marked `is_test_account=true`,
never synced. Platform metrics: seeded manually with varied heat_score (5–95) and display_score.

| UUID suffix | Username | Category | Subcategory |
|---|---|---|---|
| 001 | test_athlete_basketball_1 | Athlete | Basketball |
| 002 | test_athlete_football_1 | Athlete | Football |
| 003 | test_musician_dj_1 | Musician | DJ |
| 004 | test_musician_singer_1 | Musician | Singer |
| 005 | test_healthcare_doctor_1 | Healthcare | Doctor General |
| 006 | test_healthcare_nurse_1 | Healthcare | Nurse |
| 007 | test_performer_comedian_1 | Performer | Comedian |
| 008 | test_performer_dancer_1 | Performer | Dancer |
| 009 | test_gamer_streamer_1 | Gamer | Streamer |
| 010 | test_gamer_competitive_1 | Gamer | Competitive |
| 011 | test_influencer_fitness_1 | Influencer | Fitness |
| 012 | test_influencer_travel_1 | Influencer | Travel |
| 013 | test_educator_teacher_1 | Educator | Teacher |
| 014 | test_educator_author_1 | Educator | Author |
| 015 | test_politician_congress_1 | Politician | Congress |
| 016 | test_politician_governor_1 | Politician | Governor |
| 017 | test_religion_pastor_1 | Religion | Pastor |
| 018 | test_religion_rabbi_1 | Religion | Rabbi |
| 019 | test_business_startup_1 | Business | Startup |
| 020 | test_business_nonprofit_1 | Business | Non Profit |

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
