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
| 006 | display_score + resolution_score on platform_metrics; opening_resolution_score + opening_display_score on markets; updated spotlight trigger |

### Key RLS rules
- token_balances — service role only for writes
- token_transactions — service role only for inserts
- notifications — service role only for inserts
- markets — no client-side UPDATE; pool sizes via DB trigger only
- platform_connections — service role writes; users read own rows
- platform_metrics — service role writes; users read own + public reads is_live rows

### Two-Score System (Phase 3.5 — critical architecture)
platform_metrics has THREE score columns:
- heat_score — computed composite (live viewers + followers + live bonus), 0–100
- display_score — currently mirrors heat_score; WILL receive promotion/power-up
  modifiers in future phases. This is what all UI and spotlight reads.
- resolution_score — raw follower/subscriber count from API only. NEVER modified
  by promotions, power-ups, or any user action. Used exclusively for market resolution.

markets table snapshots at open:
- opening_resolution_score — resolution_score at time of market creation (locked forever)
- opening_display_score — display_score at time of market creation (reference only)

Market resolution (Phase 5) compares opening_resolution_score vs resolution_score
at close. Never uses display_score for resolution.

---

## Edge Functions

All deployed with --no-verify-jwt. Auth verified internally via supabase.auth.getUser().
Supabase project uses ES256 (asymmetric) JWTs — HS256 runtime verification always fails.

| Function | Purpose |
|----------|---------|
| oauth-initiate | Generates YouTube/Twitch OAuth URLs with HMAC-signed CSRF state |
| oauth-callback | Verifies state, exchanges code for tokens, stores connection, triggers sync |
| sync-platform-metrics | Fetches live data, computes heat_score, populates display_score + resolution_score |
| disconnect-platform | Revokes OAuth tokens, deletes connection (cascades to metrics) |

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
- Two-score system: display_score + resolution_score separated at DB level
- Market snapshots: opening_resolution_score + opening_display_score on market create
- pg_cron: syncs platform metrics every 5 minutes

### Known Issues / Notes
- YouTube OAuth is in Google Testing mode — only whitelisted emails can connect.
  Must submit for Google verification before public launch.
- Twitch re-auth silently skips consent page (handled by already-connected sheet).
- Google consent screen shows supabase.co domain — expected until custom domain added.
- Profile pictures deferred: avatar comes from connected social account (not yet built).
  Currently shows first letter of username. Do not add manual upload — avatar must
  always come from connected platform.

---

## Deferred Features — Do Not Build Until Instructed

### Phase 4 — Stripe Token Purchases
Token packages (exact values — do not change):
- Starter: 120 tokens – $0.99
- Popular: 650 tokens – $4.99
- Pro: 1,650 tokens – $9.99
- Elite: 3,500 tokens – $19.99

Architecture:
- Edge function: create-checkout-session (creates Stripe hosted checkout, returns URL)
- Edge function: stripe-webhook (verifies signature, credits tokens, records transaction)
- New table: token_purchases (migration 007)
- Flutter: Buy Tokens UI in Wallet screen, deep link /wallet?purchase=success
- New secrets needed: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
- Stripe webhook endpoint: https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/stripe-webhook
- Test with Stripe test card: 4242 4242 4242 4242

### Phase 5 — Market Resolution
- Scheduled job to detect expired markets
- Compare opening_resolution_score vs current resolution_score
- Determine winner, distribute pool minus platform fee (10% rake)
- 5% to platform, 5% to Market Maker pool
- Notify all participants
- Key decisions needed before building: what metric determines winner,
  what happens if creator disconnects platform before market closes,
  what happens if no bets on one side

### Post Phase 5 — Promotions & Power-Ups
These modify display_score ONLY — never resolution_score:

Promotions:
- Quick Boost: 80 tokens → +8 display_score for 1 hour
- Major Boost: 250 tokens → +20 display_score for 1 hour
- Spotlight Entry: 500 tokens → guaranteed Spotlight slot for 4 hours
- Active market bonus: 1.5× multiplier on boosts if ≥200 tokens in open bets
- Market Maker discount: 20% off promotions while market is open

Power-Ups (used on any Market Maker):
- Universe: 800 tokens — global animation with name visible to everyone (24h cooldown)
- Galaxy: 300 tokens — name highlight for all followers (24h cooldown)
- Instant +Popularity: 400 tokens — +12 display_score for 1 hour
- Instant -Popularity: 350 tokens — -12 display_score for 1 hour (rival sabotage)
- Black Hole: 250 tokens — cancels any active Universe on target

### Post Phase 5 — Challenges & Badges
- Daily/weekly/monthly challenge tracks
- Separate pools for users vs Market Makers
- Each completed challenge = 50–150 tokens + cosmetic badge
- Badges give +2% visibility multiplier in feeds while equipped
- Examples: hot streak wins, early adopter, big spender, Spotlight entry, etc.

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
- display_score = what users see (can be modified by promotions/power-ups)
- resolution_score = objective truth (raw API data only, never modified)
- 10% betting rake: 5% to platform, 5% to Market Maker pool
- Integer balances only — no decimals in token_balances
- Every token movement logged immutably in token_transactions
- Free sources are generous but daily-capped so purchases feel powerful
