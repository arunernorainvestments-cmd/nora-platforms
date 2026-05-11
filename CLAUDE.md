# NORA Platforms — CLAUDE.md
# Canonical reference for all Claude Code sessions
# Last updated: May 2026

## Project Overview
Flutter web prediction market and live battle platform. Two distinct games
sharing one wallet and one creator pool. Pre-launch — July 4 2026.

Repo: arunernorainvestments-cmd/nora-platforms
Supabase project ref: cceisywxwhgljdpisjrl
Live domain: noraplatforms.com (Cloudflare → Vercel → Flutter)

---

## Tech Stack
- Frontend: Flutter web, plain Riverpod only (FutureProvider.autoDispose / Provider)
  NO @riverpod, NO build_runner, NO code generation. Ever.
- Backend: Supabase (PostgreSQL + RLS + Edge Functions in Deno/TypeScript)
- Routing: GoRouter with PathUrlStrategy (clean URLs, no #)
- Hosting: Vercel (catch-all rewrite → Flutter index.html)
- Battle Character Animations: Flame engine (sprite sheets)
- Battle Effect Animations: Lottie JSON (lottie Flutter package)
- Battle UI Interactions: Flutter native

## Theme Tokens
bg #0A0A0F | surface #1A1A2E | primary #6C63FF | secondary #03DAC6
success #00C896 | danger #FF4757

---

## Hard Rules (non-negotiable)
1. Plain Riverpod only — no codegen, no @riverpod, no build_runner
2. sync-platform-metrics stays a single Edge Function — never split
3. Never modify display_score outside sync-platform-metrics
4. Never modify heat_score outside sync-platform-metrics
   (single exception: arena-monday-rollover resets Spotlight winners)
5. All token movements logged in token_transactions with type + reference_id
6. ON CONFLICT DO NOTHING wherever badges are inserted
7. Passive effects are read-only at query time
8. Handle HTTP 429 gracefully — log and skip, never throw
9. Never hardcode API keys
10. noraplatforms.com everywhere — no vercel.app references
11. Read every file in full before modifying
12. flutter analyze zero issues before every commit
13. is_market_maker = true AND pending_opt_out = false for eligibility
14. Cooldowns via active_boosts only
15. Test accounts filtered from all ranking/discovery queries
16. Arena and Markets are independent reward loops
17. Arena never modifies display_score, heat_score, or token_balances except
    via Back action, Trigger action, and match resolution
18. ArenaScore is in-memory only — never persisted post-match
19. Spotlight has two sections — compute-spotlight produces both independently
20. arena_trigger() writes effects directly to arena_state.active_effects
21. Battle and Arena are entirely separate — all Battle artifacts prefixed battle_
22. INCLUDE_TEST_ACCOUNTS filter pass (Slice 2) tracked separately

---

## Score Hierarchy
| Score | Storage | Modified By | Role |
|---|---|---|---|
| Display Score | platform_metrics.display_score | sync-platform-metrics | Markets, Top Movers |
| Heat Score | platform_metrics.heat_score (0-100) | Promotions + rollover | UI popularity |
| Momentum Score | platform_metrics.momentum_score | Match wins + decay | Arena MomentumCarry |
| ArenaScore | arena_state.score_p1/p2 | Tick loop only | Live, ephemeral |
| Weekly Arena Points | arena_weekly_points | Match wins + Monday reset | Round 3 qualification |
| Buzz Score | celeb_weekly_scores.points | hot-topic-fetch-and-score | Hot Topic leaderboard |

resolution_score does NOT exist — dropped in migration 019.

---

## Two-Game Architecture

### Game 1: Markets
Bet tokens on creator Display Score direction by market close.
Pool: 90% winners / 5% platform / 5% Market Maker.

### Game 2: Arena
5-minute live matches. ArenaScore: BaseFlow + HeatInfluence + AbilityImpact
+ MomentumSpike + MomentumCarry minus Suppression (in-memory only).
Pool: 90% backers of winner / 5% platform / 5% winning creator.
Two token actions: Back / Trigger.
Logged-in users are audience — players are creators (test creators in dev).

### Game 3: Battle (Phase A + B complete, Phase C in progress)
6-player (2 teams of 3), turn-based, Pokemon-style.
Simultaneous move submission; server resolves in speed order.
All Battle artifacts prefixed battle_. See Battle section below.

---

## Battle Mode

### Turn Flow
1. Lobby created (battle_create_lobby) — 6-char code shared out of band
2. 5 others join (battle_join_lobby) — 3 per team
3. Host starts (battle_start_match) — random map selected
4. 30s submission window — all 6 submit simultaneously
5. process_battle_turn() fires every 3s via pg_cron
6. Resolution: voluntary swaps first, then attacks in speed order
7. Status effects applied and expired each turn
8. KO triggers forced swap to next bench character
9. All fainted = match resolved, spectator bets settled
10. Forfeit available any time via battle_forfeit RPC

### Animation Architecture (Phase C)
CHARACTER ANIMATIONS — Flame engine with sprite sheets
- Pipeline: Grok Imagine (stills) → Viggle AI (video, green/black screen)
  → SpriteMaster (sprite sheet PNG + JSON) → assets/battle/sprites/
- Required states per archetype: idle, attack, defend, hit, ko, victory
- Rendered via SpriteAnimationWidget + SpriteAnimationData

ABILITY AND EFFECT ANIMATIONS — Lottie JSON
- Pipeline: Kling or Grok (MP4, green/black screen)
  → vizgpt.ai (Lottie JSON) → assets/battle/lottie/
- Rendered via lottie Flutter package, layered over sprite layer

MENU AND UI INTERACTIONS — Flutter native
- Hover/tap effects, button states, timer countdown built in Dart
- Lottie used only where specific UI flourishes require it

### Asset Naming Convention (strictly enforced)
Claude Code constructs asset paths from archetype + state + type.
Any deviation breaks loading logic. Follow exactly.

SPRITE SHEETS
assets/battle/sprites/[archetype]_[state].png
assets/battle/sprites/[archetype]_[state].json

Valid archetypes:
  athlete | musician | business | comedian | artist
  gamer | influencer | scientist | politician | actor

Valid states: idle | attack | defend | hit | ko | victory

Examples:
  assets/battle/sprites/athlete_idle.png
  assets/battle/sprites/athlete_idle.json
  assets/battle/sprites/musician_attack.png
  assets/battle/sprites/musician_attack.json

LOTTIE EFFECT FILES
assets/battle/lottie/[archetype]_ability_[slot].json
assets/battle/lottie/system_[event].json

Examples:
  assets/battle/lottie/athlete_ability_1.json
  assets/battle/lottie/musician_ultimate.json
  assets/battle/lottie/system_ko.json
  assets/battle/lottie/system_swap.json
  assets/battle/lottie/system_victory.json

SPRITE SHEET REQUIREMENTS (SpriteMaster export settings)
- Uniform grid layout — all frames identical pixel dimensions
- Export both PNG and JSON descriptor to same directory
- JSON must include: frameWidth, frameHeight, frameCount, fps
- Recommended frame size: 512x512px
- Recommended fps: 24 for idle and victory, 30 for attack, hit, and ko

### Flutter Integration Pattern

Sprite sheet loading via Flame:
  SpriteSheet.fromImageAssetKey('assets/battle/sprites/${archetype}_${state}.png')
  SpriteAnimationData.fromJson(json from assets/battle/sprites/${archetype}_${state}.json)
  spriteSheet.createAnimation(data: animData)

Lottie effect loading:
  LottieBuilder.asset('assets/battle/lottie/${archetype}_ability_${slot}.json')
  Controlled via AnimationController, triggered on battle_events stream

### Animation Key Column (DB)
battle_events.animation_key TEXT
  Asset identifier Flutter uses to trigger the correct animation.
  Format matches asset naming convention above.
  Examples: 'athlete_ability_1', 'system_ko', 'musician_ultimate'
battle_abilities.animation_key TEXT
  Maps each ability to its Lottie asset key.
battle_participant_status_effects.indicator_key TEXT
  Maps each status effect to its visual indicator asset.
battle_maps.background_key TEXT
  Maps each map to its background asset key.

### Type Chart (10 archetypes, conflict-resolved)
Stored in battle_type_chart — rebalance via SQL only, no code changes.
athlete beats: Gamer, Artist
musician beats: Athlete, Comedian, Politician
business beats: Scientist, Artist, Musician
comedian beats: Politician, Actor
artist beats: Musician, Influencer, Gamer
gamer beats: Business, Politician
influencer beats: Actor, Comedian, Athlete
scientist beats: Gamer, Artist, Musician
politician beats: Business, Influencer
actor beats: Politician, Athlete, Scientist

### Speed Stats (turn resolution order)
athlete:90 | gamer:85 | influencer:75 | actor:70 | comedian:65
musician:60 | artist:55 | scientist:50 | business:45 | politician:40

### Battle Chit (future build)
Collectible cards (Megaman NT Warrior model).
Earned via challenges, packs, gifts. battle_chits table TBD.
Menu button opens secondary panel showing owned chits.
No mechanical effect implemented yet.

### Key Tables
battle_matches | battle_participants | battle_turn_submissions
battle_events | battle_participant_status_effects
battle_spectator_bets | battle_abilities | battle_type_chart
battle_maps | battle_animation_keys | battle_match_telemetry

---

## Dual Spotlight Architecture
Home page two sections:
- Arena Champions — 5 slots, Round 3 winners, locked Monday 00:00 UTC
  Source: arena_spotlight_assignments
- Top Movers — 5 slots, largest weekly Display Score growth
  Source: score_history deltas, updated via compute-spotlight

---

## Hot Topic (/hot-topic)
Celebrity buzz leaderboard — separate from Markets, Arena, and Battle.
25 celebrities in celebs table. Scores reset to 1000 every Monday.
Scoring via Anthropic API (claude-sonnet-4-20250514) twice daily
using Currents API news data (CURRENTS_API_KEY env secret).

Two bet types:
- Simple: up/down on a celeb, resolves each scoring run (AM/PM window)
- Weekly: person_of_week/top_riser/big_boo/top_5, resolves Friday 8PM ET

/news (CelebrityHeatScreen) feeds from celeb_score_history.
Breaking News panel on /home shows top 3 most recent entries.

---

## Token Transaction Types
'signup_bonus' | 'bet_placed' | 'bet_won' | 'bet_lost' | 'refund'
'promoted' | 'referral_bonus' | 'purchase' | 'purchased'
'challenge_reward' | 'passive_bonus' | 'arena_back' | 'arena_trigger'

---

## Edge Functions (deployed, --no-verify-jwt)

### Markets and Core
oauth-initiate | oauth-callback | disconnect-platform
sync-platform-metrics (single fn, never split)
resolve-markets | apply-promotion | evaluate-challenges
compute-spotlight (returns {champions, top_movers})
create-checkout-session | stripe-webhook

### Arena
arena-matchmaker | arena-monday-rollover | arena-dev-force-match
arena-dev-simulator | arena-dev-reset (ALLOW_DEV_TOOLS=true gated)

### Hot Topic
hot-topic-fetch-and-score | hot-topic-reset-week
hot-topic-resolve-week | hot-topic-place-bet

### Battle
battle-tick-warmer
process_battle_turn() is PL/pgSQL via pg_cron — not an edge function

---

## pg_cron Jobs
main-character-check (hourly)
arena-matchmaker (5min) | process_arena_tick (3s) | arena-tick-warmer (30s)
arena-monday-rollover (Monday 00:00 UTC)
hot-topic-morning (11:00 UTC daily) | hot-topic-evening (22:00 UTC daily)
hot-topic-weekly-reset (Monday 11:00 UTC)
hot-topic-resolve (Saturday 00:00 UTC)
battle-turn-processor (3s) | battle-cleanup (10min) | battle-presence-check (60s)

---

## Routing
/ LaunchScreen (countdown + waitlist)
/w/:token LaunchScreen with referral token
/home HomeScreen (Shell)
/markets | /markets/:id Markets | MarketDetail
/mybets | /profile | /wallet | /dashboard | /challenges (auth)
/news CelebrityHeatScreen
/hot-topic HotTopicScreen
/arena ArenaLobbyScreen (auth)
/arena/:matchId ArenaMatchScreen (auth)
/battle BattleLobbyScreen (auth) — Phase C
/battle/:matchId BattleMatchScreen (auth) — Phase C
/u/:username PublicProfileScreen (public)

---

## Pre-Launch Reset Sequence (before July 4 2026)
1. Run 027_teardown_test_accounts.sql
2. Truncate Arena and Battle tables (test rows only)
3. Reset real user token_balances, truncate transactions and purchases
4. Truncate badges, challenges, streaks, bets, markets, score_history
5. Keep: profiles, platform_connections, waitlist, celebs, celeb_weekly_scores
6. Do NOT re-run OG/Early Adopter cutoff migration
7. Re-grant signup bonuses via increment_token_balance(user_id, 100)

OG cutoff: 2026-07-04T04:00:00Z
Early Adopter cutoff: 2026-08-03T04:00:00Z (already set — do not re-run)

---

## Pending Before Phase C
- Confirm SpriteMaster JSON format matches Flame SpriteAnimationData schema

## What's Still Queued
- Battle Phase C: Flutter UI + Flame/Lottie integration (assets pending)
- Battle Phase D: Map buff wiring, matchmaking queue, balance tuning
- Battle Chit collectible economy (post-launch)
- Slice 2: Comprehensive is_test_account filter sweep
- Celebrity dedicated pages with profile pictures (pre-launch)
- Onboarding walkthrough (4-5 slide PageView)
- Profile avatars from connected platform data
- Arena Visual Pass 2/3
- Marketing campaign and launch-day animation