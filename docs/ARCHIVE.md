# NORA Platforms — Design Archive

This file holds historical design decisions, superseded specs, and dropped
schema details. It is preserved for context and reference but is NOT a
canonical source. CLAUDE.md is the canonical source.

If you find a contradiction between this file and CLAUDE.md, CLAUDE.md wins.

---

## Repo Audit (April 2026)

Schema audit completed April 2026 against migrations 001–024. Key resolutions:
- Two-tier category system replaced flat 14-category list (migration 024).
- `resolution_score` dropped; composite `display_score` took over Market resolution (migration 019).
- `heat_score` baseline reset to 0; boost-only driver going forward (migration 019).

---

## Dropped Schema Elements

These fields and tables do not exist in the current schema. Do not reference them.

### resolution_score (dropped migration 019)

`platform_metrics.resolution_score` was a normalized 0–100 resolution metric used in early
market design. It was dropped when `display_score` was promoted to bigint additive and became
the sole resolution metric. The column no longer exists on `platform_metrics`.

Market resolution now: `resolve-markets` sums all `platform_metrics.display_score` rows for the
creator and compares against `opening_resolution_score` on the `markets` table. Despite the name,
`opening_resolution_score` stores the composite bigint `display_score` snapshot taken at market open
(not the old normalized resolution_score).

### power_up_cooldowns table (never built)

`power_up_cooldowns` was an early design idea for a separate cooldown tracking table.
It was never created. Cooldowns are enforced via `active_boosts` — if an unexpired entry
exists for the same user + promotion type, the cooldown is active.

### platform_metrics.spotlight_pinned_until (never built)

`spotlight_pinned_until` was a proposed column for time-based Spotlight pinning. It was never
added. Spotlight pinning uses `active_boosts` with type `spotlight_entry`.

### profiles.accepts_new_markets (never built)

`accepts_new_markets` was an early proposed column to gate whether a Market Maker was open to
new markets. It was never added. Eligibility check is `is_market_maker = true AND pending_opt_out = false`.

### profiles.token_balance (never built)

Token balances live in the separate `token_balances` table, NOT as a column on `profiles`.

---

## Arena Design History

### Superseded match durations

Early Arena specs used 1-hour Round 1 matches and 30-minute Round 2 matches. These were
rejected in favor of uniform 5-minute matches across all rounds. Rationale: shorter matches →
more matchups per week → users can participate during a work break or downtime.

### Superseded Shift action

Early specs included a third token action called **Shift** — moving tokens mid-match with a
penalty. This was removed. The canonical two token actions are Back and Trigger. Do not
reintroduce Shift.

### Superseded Spotlight reset design (pre-April 2026)

An earlier spec described the Spotlight reset as resetting only `heat_score` to 0. The canonical
rule (locked April 2026): the Monday after a creator holds a Spotlight slot, both `heat_score`
AND `momentum_score` reset to 0.

### Superseded single Spotlight design

The original home page had one Spotlight strip. The current canonical design has two: Arena
Champions (5 slots, from Round 3 results) and Top Movers (5 slots, from display_score growth).
The layout split ships with Phase A Arena UI.

### Open design questions resolved (April 2026)

| Question | Resolution |
|----------|------------|
| Carry mechanism | `momentum_score` column on `platform_metrics` |
| Decay curve | Linear over 1 week |
| Cap | TBD in Phase A spec |
| Spotlight reset scope | Resets both `heat_score` AND `momentum_score` to 0 |
| Token action count | Two (Back, Trigger). No Shift. |

---

## Category Migration Mapping (migration 024)

The flat 14-category list was retired and mapped to the two-tier system as follows:

Comedian → Performer/Comedian · Doctor → Healthcare/Doctor General ·
Researcher → Healthcare/Researcher · Fitness → Influencer/Fitness ·
Sports → Athlete/(subcategory null, flagged for reselection)

---

## React Home App Retirement

The `landing/` React app was deleted. Flutter's `HomeScreen` became the sole home page.
Vercel now routes all paths (except `/privacy`, `/terms`, `/tiktok-verification`) to
Flutter's `index.html` via a single catch-all rewrite in `vercel.json`.

---

## Completed Phase Details

Full bullet-point details for each completed phase.

### Phases 1–3.5
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

### Phase 4 — Stripe Token Purchases
- create-checkout-session + stripe-webhook edge functions
- token_purchases table (migration 007)
- Wallet screen: "Get More Tokens" bottom sheet (Starter $0.99 / Popular $4.99 / Pro $9.99 / Elite $19.99)
- Deep link handling: /wallet?purchase=success and /wallet?purchase=cancelled
- Stripe webhook endpoint: https://cceisywxwhgljdpisjrl.supabase.co/functions/v1/stripe-webhook

### Phase 5 — Market Resolution
- resolve-markets edge function: resolves expired markets, distributes payouts, handles voids
- Market detail screen: countdown timer, "Resolving...", resolved/voided states
- Bet blocking: buttons disabled when market.status != 'open' or endAt ≤ 15s away
- MarketDetail model: resolvedAt (DateTime?), resolutionResult (String?)

### Post-Phase-5 — Public Profile
- Public profile screen (/u/:username): avatar, username, bio, category chips, Heat Score badge,
  Display Score, per-platform stats (Spotify in #1DB954), badges shelf, Promote / Power-Up buttons
- publicProfileProvider queries public_platform_connections view (migration 023) to avoid RLS block
- "Preview Profile" and "Promote" buttons on own profile screen

### Phase 6 — Promotions & Power-Ups
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

### Phase 7 — Challenges & Badges
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

### Phase 8 — New Scoring System (migration 019)
- display_score changed from numeric(5,2) → bigint (additive raw points per platform)
- resolution_score DROPPED — composite display_score is now the resolution metric
- heat_score baseline reset to 0 (boost-only; active boost deltas are the only driver)
- previous_follower_count added to platform_metrics for 24h growth delta
- score_history table created (Robinhood-style dashboard chart)
- Snapshot trigger fixed: opening_resolution_score now stores composite bigint display_score
- ScoreDashboard: Robinhood-style line chart with 1D/1W/1M/3M/YTD periods

### Post-Phase-7 Platform Additions
- X (Twitter) OAuth + metrics sync (migration 020; recent_post_views/reposts/likes columns)
- Spotify OAuth + metrics sync (saved tracks/albums via column reuse of recent_post_views/reposts)
- public_platform_connections view (migration 023)
- Beta approval gate (migration 021): is_approved on profiles; approve_beta_user() DB function;
  /pending-approval route; auto-approve flow for pre-approved waitlist emails

### Pre-Launch — Cover Screen
- Launch screen: full-page countdown to July 4, 2026 00:00:00 UTC, waitlist email signup,
  consent checkbox, legal footer links
- waitlist table (migration 022): email UNIQUE, anon INSERT open, no anon SELECT
- `/` route shows LaunchScreen when app is in pre-launch mode
