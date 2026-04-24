# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.
Read it fully before making any changes.

---

## Project Overview

N.O.R.A. Platforms is a Flutter web application for a prediction market platform based
on creator popularity metrics. The backend is Supabase (PostgreSQL + Auth). Deployed
to Vercel via GitHub Actions on push to main.

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

**Routing:** GoRouter (lib/core/router/app_router.dart). Unauthenticated users redirect
to /login; authenticated users land on /home. The main shell
(lib/core/shell/main_shell.dart) wraps authenticated routes with bottom nav bar.

**Feature structure:** Each feature lives in lib/features/<name>/ with subdirectories
for screens/, widgets/, providers/, and models/. Features implemented: auth, home,
profile, discover, markets, notifications, wallet (stub for Phase 4).

**Supabase calls:** Direct client calls inline in providers. Mutation logic uses action
classes (e.g. ProfileActions, NotificationActions). No edge functions called from
providers except OAuth initiation.

**Widgets:** Private classes (_WidgetName) defined at bottom of screen file.

**Error handling:** try/catch with if (mounted) guard + ScaffoldMessenger snackbar.

### React Home App (`/home`) — Phase 2 complete

A separate Vite + React app lives in the `landing/` directory (source stays in `landing/`
for historical reasons — only the served URL changed). It is the primary entry point,
replacing Flutter's `/home` screen. Vercel routes `/home` and `/home/(.*)` to
`home/index.html`; all other paths serve Flutter's `index.html`.

- Entry: `landing/src/main.jsx` → `landing/src/Landing.jsx`
- Styles: `landing/src/index.css`
- Build output: `landing/dist/` → copied to `.vercel/output/static/home/` by `deploy.yml`
- Supabase data fetched via `@supabase/supabase-js` in `landing/src/supabase.js`
- Uses React Router (react-router-dom) with `BrowserRouter`; basename comes from
  `BASE_PATH = '/home'` in `landing/src/config.js`
- Internal pages use `<Link to="...">` for client-side navigation — no full page reload:
  `/home/profile`, `/home/wallet`, `/home/mybets`, `/home/explore`, `/home/dashboard`
- Pages live in `landing/src/pages/`; shared shell in `landing/src/components/PageShell.jsx`
- External links that intentionally leave the React app (`/login`, `/signup`) stay as `<a href>`
- Flutter's GoRouter has a top-level `/home` GoRoute (in `app_router.dart`) that calls
  `web.window.location.replace('/home')` — bridges programmatic Flutter navigation to the
  React app (post-login redirect, bottom nav Home tab)
- Phase 3 (future): change `BASE_PATH` to `'/'` and update the Vercel rewrite source in
  `deploy.yml` — no other files change
- Build command: `cd landing && npm install && npm run build`

---

## Supabase Schema

All tables have RLS enabled. Migrations run in order:

| Migration | Key additions |
|-----------|--------------|
| 001 | profiles, social_connections, markets, bets, balances, transactions |
| 002 | token_balances, token_transactions, spotlight_scores, famous_creators; triggers |
| 003 | notifications; is_market_maker, referral_code, referred_by on profiles |
| 004 | bet_placed/referral_bonus constraints; triggers: pool update, token deduct, notify |
| 005 | platform_connections, platform_metrics; RLS; heat score → spotlight trigger |
| 006 | heat_score + resolution_score on platform_metrics; opening_resolution_score + opening_heat_score on markets; updated spotlight trigger |
| 007 | token_purchases table for Stripe integration |
| 008 | Bug fixes and schema corrections |
| 009 | Market resolution: resolved_at, resolution_result, resolved_outcome on markets; 'refund' added to token_transactions type; 'bet_refunded'/'market_resolved' added to notifications type |
| 010 | duration_label on markets |
| 011 | Re-applies token_transactions type constraint with 'refund' (applied directly in SQL Editor) |
| 012 | market_series, market_event, market_identifier, category_1, category_2 on markets; category_1, category_2 on profiles |
| 013 | Rename score columns: heat_score→display_score (raw composite), display_score→heat_score (UI composite), opening_display_score→opening_heat_score |
| 014 | active_boosts table for Phase 6 promotions |
| 015 | promotion_banners table (Realtime); active_boosts CHECK updated |
| 016 | badge_definitions, challenge_definitions, user_badges, user_challenge_progress, user_streaks; seed data; 'challenge_reward' token type |
| 017 | user_passive_effects view (aggregates badge passive effects per user) |
| 018 | 'passive_bonus' token type; heat_score_leader_since on platform_metrics; evaluate_main_character_badge() DB function + hourly pg_cron job |

### Key RLS rules
- token_balances — service role only for writes
- token_transactions — service role only for inserts
- notifications — service role only for inserts
- markets — no client-side UPDATE; pool sizes via DB trigger only
- platform_connections — service role writes; users read own rows
- platform_metrics — service role writes; users read own + public reads is_live rows

### Two-Score System (Phase 3.5 — critical architecture)
platform_metrics has THREE score columns:
- display_score — raw computed composite (live viewers + followers + live bonus), 0–100.
  NEVER modified by promotions, power-ups, or any user action.
- heat_score — the 0–100 composite shown in all UI and spotlight. CAN be modified by
  promotions/power-ups. This is what all UI and spotlight reads.
- resolution_score — raw follower/subscriber count from API only. NEVER modified
  by promotions, power-ups, or any user action. Used exclusively for market resolution.

markets table snapshots at open:
- opening_heat_score — heat_score at time of market creation (locked forever)
- opening_resolution_score — resolution_score at time of market creation (locked forever)

Market resolution (Phase 5) compares opening_resolution_score vs resolution_score
at close. Never uses heat_score for resolution.

---

## Edge Functions

All deployed with --no-verify-jwt. Auth verified internally via supabase.auth.getUser().
Supabase project uses ES256 (asymmetric) JWTs — HS256 runtime verification always fails.

| Function | Purpose |
|----------|---------|
| oauth-initiate | Generates YouTube/Twitch OAuth URLs with HMAC-signed CSRF state |
| oauth-callback | Verifies state, exchanges code for tokens, stores connection, triggers sync |
| sync-platform-metrics | Fetches live data, computes display_score (raw composite), populates heat_score + resolution_score |
| disconnect-platform | Revokes OAuth tokens, deletes connection (cascades to metrics) |
| resolve-markets | Resolves expired markets: compares opening_resolution_score vs current, distributes payouts (10% rake: 5% platform + 5% MM), handles voids/refunds, sends notifications; fires bet_won/bet_lost/tokens_earned events to evaluate-challenges; applies token_earn_rate passive bonus (passive_bonus token type) |
| apply-promotion | Validates and applies self-boosts and power-ups; enforces cooldowns; stacks badge promotion_discount + MM discount multiplicatively; fires promotion_used/power_up_received events; awards Power Tripped + Untouchable badges directly |
| evaluate-challenges | Full challenge condition engine (count_threshold, snapshot, streak, composite); handles referral_signup redirect to referrer; idempotent; awards tokens + badges; fires from Flutter (check_in, bet_placed) and edge functions (bet_won, bet_lost, promotion events) |
| create-checkout-session | Validates auth, creates Stripe hosted checkout, inserts pending token_purchases row |
| stripe-webhook | Verifies Stripe HMAC signature, idempotency check, credits tokens via increment_token_balance RPC |

### Deploying edge functions
Edge functions do NOT auto-deploy from GitHub. Must deploy manually:
```bash
export SUPABASE_ACCESS_TOKEN=your_token
npx supabase functions deploy <function-name> --project-ref cceisywxwhgljdpisjrl --no-verify-jwt
```

IMPORTANT: Never paste SUPABASE_ACCESS_TOKEN into Claude Code chat. Run deploy
commands directly in your terminal tab. Rotate token at
supabase.com/dashboard/account/tokens before sharing repo access.

### Edge Function Secrets (set in Supabase Dashboard → Edge Functions → Secrets)
```
YOUTUBE_CLIENT_ID
YOUTUBE_CLIENT_SECRET
TWITCH_CLIENT_ID
TWITCH_CLIENT_SECRET
APP_URL               https://nora-platforms.vercel.app
OAUTH_STATE_SECRET
```

---

## Deployment

Push to main triggers GitHub Actions (.github/workflows/deploy.yml) which builds
Flutter web and deploys to Vercel.

Required GitHub secrets: VERCEL_TOKEN, VERCEL_ORG_ID, VERCEL_PROJECT_ID,
SUPABASE_URL, SUPABASE_ANON_KEY.

vercel.json rewrites all paths to /index.html for SPA routing.

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
- Who's Live tab: shows live creators with Heat Score, viewer count, stream info
- Wallet: token balance, transaction history (Stripe UI stub ready for Phase 4)
- Profile: edit profile, Market Maker opt-in (3-step), opt-out flow
- Platform connections: YouTube + Twitch OAuth, already-connected bottom sheet
  (shows username, connected date, disconnect button), success snackbar on connect
- Public profiles: /u/username route, shareable, no login required
- Referral: /join?ref=code route, tracking, bonus tokens
- Notifications: bell icon, notification center, mark as read
- Markets: Open Markets + My Bets tabs, pool ratio bars, timeago countdowns
- Betting: 4-step bottom sheet, join or create markets
- Heat Score: live viewers + follower reach + live bonus (0–100)
- Two-score system: heat_score + display_score + resolution_score at DB level (migration 013 renamed columns)
- Market snapshots: opening_resolution_score + opening_heat_score on market create
- pg_cron: syncs platform metrics every 5 minutes

### Completed (Phase 4 — Stripe Token Purchases)
- create-checkout-session edge function: validates auth, creates Stripe hosted checkout, inserts pending token_purchases row
- stripe-webhook edge function: verifies Stripe HMAC signature, idempotency check, credits tokens via increment_token_balance RPC, logs to token_transactions
- token_purchases table (migration 007): tracks pending/completed purchases with stripe_session_id
- Wallet screen: "Get More Tokens" bottom sheet with all 4 package cards (Starter/Popular/Pro/Elite)
- Deep link handling: /wallet?purchase=success and /wallet?purchase=cancelled with snackbar feedback
- Secrets required: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET (set in Supabase Dashboard)
- Stripe webhook endpoint: https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/stripe-webhook

### Completed (Phase 5 — Market Resolution)
- resolve-markets edge function: resolves expired markets, distributes payouts, handles voids
- Resolution logic: opening_resolution_score vs current resolution_score (above/below/tie→refund)
- Void conditions: missing metrics, tied score, or no bets on the winning side → full refund
- Payout: 90% of pool to winners proportional to stake; 5% to platform, 5% to Market Maker
- token_transactions type constraint updated to include 'refund' (migration 011)
- Market detail screen: countdown timer now shows correct state per market.status:
  - open + time remaining → "Closes in HH:MM:SS"
  - open + time expired → "Resolving..." (waiting for cron)
  - resolved → "Resolved at HH:MM"
  - voided → "Market voided / Refunded"
- Bet blocking: Above/Below buttons and drawer confirm button disabled when:
  - market.status != 'open'
  - market.endAt ≤ 15 seconds away (live countdown enforced by StatefulWidget timer)
- MarketDetail model now includes resolvedAt (DateTime?) and resolutionResult (String?)

### Completed (Post Phase 5 — Public Profile & Score Rename)
- Migration 013: atomic rename of score columns (heat_score↔display_score swap +
  opening_display_score→opening_heat_score); applied via SQL Editor only
- sync-platform-metrics + resolve-markets edge functions redeployed after rename
- Public profile screen (/u/:username) fully rebuilt with 5 sections:
  - Header: avatar, username, bio, category chips, Heat Score badge
  - Action buttons: Promote (own profile) or Bet + Promote (other MM profiles)
  - Live Now: one card per live platform with viewer count
  - Platform Stats: one card per connected platform with follower count, viewer
    count (if live), Raw Score, Heat Score
  - Recent Content: placeholder
- Public profile visibility rules:
  - Heat Score shown whenever connections.isNotEmpty; displays '---' if !isMarketMaker
  - Platform Stats shown whenever connections.isNotEmpty; non-MM profiles show
    per-connection cards with '---' for all numeric values (_RedactedStatCard)
  - Action buttons (Bet/Promote) only visible when isMarketMaker && connections.isNotEmpty
- publicProfileProvider queries public_platform_connections view (not platform_connections)
  to avoid RLS block — view exposes only safe columns, filtered to is_active=true at DB level
- "Preview Profile" button added to logged-in profile screen → pushes /u/:username
- "Promote" button added below Market Maker dashboard on logged-in profile screen
  (only visible when isMarketMaker == true); now opens Promotions sheet (Phase 6)

### Completed (Phase 6 — Promotions & Power-Ups)
- Migration 014: active_boosts table — tracks all time-limited heat_score modifications and
  cosmetic effects; RLS allows activator/target to read; all writes via service role
- apply-promotion edge function: auth, validates boost type, enforces self-only constraint,
  cooldown checks (universe/galaxy), black_hole cancellation logic, discount + multiplier
  computation, token deduction via increment_token_balance RPC, active_boosts insert,
  token_transactions log, triggers immediate sync-platform-metrics for target user
- sync-platform-metrics updated: heat_score = clamp(display_score + sum(active boost deltas), 0, 100)
  — expired/cancelled boosts automatically excluded; display_score + resolution_score unchanged
- Promotions sheet (lib/features/promotions/widgets/promotions_sheet.dart):
  - Self-boost only (own profile): Quick Boost, Major Boost, Spotlight Entry
  - Shows 20% discount banner if user has an open market
  - Shows 1.5× multiplier banner if ≥200 tokens in open bets on their market
  - Strikethrough original price when discount active
- Power-Ups sheet (lib/features/promotions/widgets/power_ups_sheet.dart):
  - Used on any other Market Maker's public profile
  - Universe (800T, 4h), Galaxy (300T, 4h), +Popularity (400T), -Popularity (350T),
    Black Hole (250T — cancels ALL universe+galaxy on target),
    Super Massive Black Hole (800T — cancels every active Galaxy in a chosen category)
  - Black Hole disabled if target has no active Universe or Galaxy
  - SMBH opens category picker dialog (all 14 categories)
  - Cooldown shown when Universe/Galaxy already active on target by current user
- Promote button on public profile (own) → Promotions sheet (self-boosts)
- Other MM public profile → Bet (full width) + Boost / Sabotage row:
  - Boost sheet: Universe, Galaxy, +Popularity
  - Sabotage sheet: -Popularity, Black Hole, Super Massive Black Hole
  - PowerUpMode enum drives which cards are shown
- Promote button on logged-in profile screen → Promotions sheet
- Open Markets tab filters end_at > now() so expired-but-unresolved markets
  are hidden while waiting for the resolve-markets cron to process them
- Migration 015: promotion_banners table (Realtime-enabled); active_boosts CHECK
  updated to include super_massive_black_hole
- promotion_banners: source of truth for banners; INSERT triggers Realtime events
- PromotionFlashBanner overlay in MainShell: slides in 4s flash on all screens;
  Universe = all users; Galaxy = only users with open bets in matching category_1
- HomeTicker: persistent scrolling strip at top of home screen; combines active
  Universe/Galaxy banners + Heat Score leaders; live via Realtime subscription
- kCreatorCategories shared constant (lib/core/constants/creator_categories.dart)
- Realtime on promotion_banners verified working via SQL Editor test insert

### Completed (Phase 7 — Challenges & Badges)
- Migration 016: badge_definitions, challenge_definitions, user_badges, user_challenge_progress,
  user_streaks tables; RLS; indexes; 'challenge_reward' added to token_transactions type constraint;
  full seed of 21 badge definitions + 19 challenge definitions (daily/weekly/monthly/once)
- Migration 017: user_passive_effects view — aggregates visibility_multiplier (additive),
  token_earn_rate (additive), promotion_discount (max), referral_bonus (max tier) per user
- evaluate-challenges edge function: full condition engine (count_threshold, snapshot, streak,
  composite types); accepts both user JWT and service role key for caller auth; idempotent via
  completed_at IS NULL + UNIQUE(user_id, badge_id); awards tokens (challenge_reward type) +
  badges; handles streak bidirectional reset (bet_won ↔ bet_lost)
- resolve-markets hooked: fires bet_won/bet_lost per position holder, bet_won_minority for
  minority-pool winners (<30% of total pool), market_resolution_top_stake for single largest
  staker, tokens_earned for each payout
- apply-promotion hooked: fires promotion_used for activator, power_up_received for target;
  awards Power Tripped badge directly when any power-up is used on another user;
  awards Untouchable badge when black_hole target has active spotlight_entry boost
- ChallengeActions class: fireCheckIn(), fireBetPlaced(creatorId), fireReferralSignup()
  using Supabase functions.invoke() with user JWT
- Home screen fires daily check-in via _checkInProvider (autoDispose FutureProvider)
- Bet bottom sheet fires bet_placed + bet_placed_unique_mm on successful bet insert
- BadgesShelf widget: horizontal scroll of tier-colored badge chips, tap → detail sheet
  with name, description, passive effect explanation; shown on own profile + public profiles
- ChallengesScreen: Daily/Weekly/Monthly TabBar; challenge cards with progress bars,
  token reward, badge reward indicator; MM-only challenges hidden from regular users;
  reset timer in each tab header
- /challenges route added to router (no bottom nav)
- Challenges button added to own profile screen (teal, next to Preview Profile)
- passiveEffectsProvider(userId): reads user_passive_effects view for UI/downstream use

- Migration 018: 'passive_bonus' token type added to token_transactions constraint;
  heat_score_leader_since column on platform_metrics; evaluate_main_character_badge()
  DB function awards 150T + badge after 24h consecutive #1 Heat Score; hourly pg_cron
  job 'main-character-check' registered

- Passive effects applied to feed ranking (post Phase 7):
  - Rising tab (risingCreatorsProvider): adds platform_metrics(heat_score) to select,
    fetches user_passive_effects, sorts by effective_score = heat_score * (1 + visibility_multiplier)
  - Who's Live tab (liveMetricsFeedProvider): sorts by heat_score (was display_score),
    then re-sorts in Dart by effective_score using user_passive_effects
  - Spotlight (spotlightCreatorsProvider): fetches 15, re-sorts with pinned entries
    (active spotlight_entry boost) first, then by effective_score; returns top 3
  - apply-promotion: promotion_discount from user_passive_effects stacked multiplicatively
    with MM discount before final cost
  - resolve-markets: token_earn_rate bonus minted as separate passive_bonus token_transactions row
- Referral signup hook wired: signup_screen.dart calls fireReferralSignup() after
  successful signup when a referral code was present (fire-and-forget; evaluate-challenges
  edge function redirects evaluation to the referrer via their referred_by field)

#### Phase 7 — Remaining Deferred
- tokens_spent event: currently only fires if explicitly called — not wired to promotion
  spending in apply-promotion (bet_placed is wired; tokens_spent requires explicit call)
- LAUNCH_DATE_PLACEHOLDER in migration 016 set to '2026-06-01' (OG badge cutoff) and
  '2026-07-01' (Early Adopter +30 days) — must update before public launch to align with
  July 4th 2026 launch date (OG cutoff = '2026-07-04', Early Adopter = '2026-08-03')

### Completed (Pre-Launch — Marketing & Cover Screen)
- Launch screen (`lib/features/launch/screens/launch_screen.dart`): full-page countdown
  with waitlist email signup, consent checkbox, live waitlist count, legal footer links
- Background: `flutter_app/assets/images/launch_bg.png` — NORA rocket launchpad art
  with dark gradient overlay for text legibility; registered in pubspec.yaml
- Countdown target: **July 4th, 2026 at 00:00:00 UTC** (`DateTime.utc(2026, 7, 4)`)
  — timer hits zero at the exact second July 3rd transitions to July 4th
- Marketing campaign (in progress): dinosaur egg that hatches into a dragon or phoenix
  on launch day; creature lights the rocket engines on the countdown page. This is a
  separate animation/asset build — do not stub or build until assets are provided.
- waitlist_emails table in Supabase stores signups; unique constraint on email
  (duplicate insert treated as success, not error)
- `/` route shows LaunchScreen when app is in pre-launch mode

### Known Issues / Notes
- YouTube OAuth is in Google Testing mode — only whitelisted emails can connect.
  Must submit for Google verification before public launch.
- Twitch re-auth silently skips consent page (handled by already-connected sheet).
- Google consent screen shows supabase.co domain — expected until custom domain added.
- Profile pictures deferred: avatar comes from connected social account (not yet built).
  Currently shows first letter of username. Do not add manual upload — avatar must
  always come from connected platform.
- resolve-markets edge function must be deployed manually (not auto-deployed from GitHub).
- evaluate-challenges edge function must be deployed manually after this phase.
- Migration 016 badge cutoff dates need updating to match July 4th launch:
  OG badge cutoff should be '2026-07-04', Early Adopter cutoff '2026-08-03'.

---

## Deferred Features — Do Not Build Until Instructed

### Phase 4 — Stripe Token Purchases ✓ COMPLETE (see Completed section above)

### Phase 5 — Market Resolution ✓ COMPLETE (see above)

### Post Phase 5 — Promotions & Power-Ups ✓ COMPLETE (Phase 6)

### Post Phase 5 — Challenges & Badges ✓ COMPLETE (Phase 7)

### Post Phase 5 — Games (separate project)
- Flappy Bird–style endless flyer
- Chicken/Crash–style multiplier risk game
- Dragon/Dinosaur egg hatching idle game
- Ad-supported token faucet (rewarded ads = 3× base reward)
- Daily caps: 8 rewarded ads/game, 150 free base tokens across all games
- Feeds tokens into main economy — designed to integrate with challenge/badge system

### Future Platform Integrations (Phase 3+)
TikTok, Instagram, X, Facebook — all currently stubbed with snackbar.
Require app review submissions. Do not build until instructed.
Kick — no public API yet. Requires scraping solution or third-party provider.

---

## Token Economy Principles (read before touching any token logic)
- Tokens are purely internal promotion fuel — no real-world cash value ever
- Popularity score capped 0–100 always
- heat_score = what users see (can be modified by promotions/power-ups)
- display_score = raw computed composite (never modified by promotions/power-ups)
- resolution_score = objective truth (raw API data only, never modified)
- 10% betting rake: 5% to platform, 5% to Market Maker pool
- Integer balances only — no decimals in token_balances
- Every token movement logged immutably in token_transactions
- Free sources are generous but daily-capped so purchases feel powerful
