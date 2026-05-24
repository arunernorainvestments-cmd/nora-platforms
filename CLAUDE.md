# NORA Platforms — CLAUDE.md
# Last updated: May 2026

## Project
Flutter web prediction market + live battle platform. Three games, one wallet.
Pre-launch — July 4 2026.
Repo: arunernorainvestments-cmd/nora-platforms
Supabase ref: cceisywxwhgljdpisjrl | Domain: noraplatforms.com (Cloudflare → Vercel → Flutter)

## Tech Stack
- Flutter web: plain Riverpod only (FutureProvider.autoDispose / Provider). NO @riverpod, NO build_runner, NO codegen. Ever.
- Backend: Supabase (PostgreSQL + RLS + Deno Edge Functions)
- Routing: GoRouter + PathUrlStrategy (clean URLs, no #)
- Hosting: Vercel catch-all rewrite → Flutter index.html
- Battle animations: Flame (sprites) + Lottie JSON (effects) + Flutter native (UI)

## Theme
bg #0A0A0F | surface #1A1A2E | primary #6C63FF | secondary #03DAC6 | success #00C896 | danger #FF4757

## Hard Rules
1. Plain Riverpod only — no codegen, no @riverpod, no build_runner
2. sync-platform-metrics stays a single Edge Function — never split
3. Never modify display_score outside sync-platform-metrics
4. Never modify heat_score outside sync-platform-metrics (exception: arena-monday-rollover resets Spotlight winners)
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
17. Arena never modifies display_score, heat_score, or token_balances except via Back action, Trigger action, and match resolution
18. ArenaScore is in-memory only — never persisted post-match
19. Spotlight has two sections — compute-spotlight produces both independently
20. arena_trigger() writes effects directly to arena_state.active_effects
21. Battle and Arena are entirely separate — all Battle artifacts prefixed battle_
22. INCLUDE_TEST_ACCOUNTS filter pass (Slice 2) tracked separately

## Games
- **Markets**: bet on creator Display Score direction. Pool: 90% winners / 5% platform / 5% Market Maker.
- **Arena**: 5-min live 1v1. ArenaScore in-memory (BaseFlow + HeatInfluence + AbilityImpact − Suppression). Pool: 90% backers / 5% platform / 5% winning creator.
- **Battle**: 6-player (2 teams of 3), turn-based, Pokémon-style. Phases A+B done, Phase C in progress. See docs/battle-spec.md.
- **Hot Topic**: celebrity buzz leaderboard, independent of games. 25 celebs, Claude scoring twice daily via Currents API.

## Reference Docs
- Scoring formulas, DB tables, data flows: docs/scoring-and-db-spec.md
- Battle animation, asset naming, type chart, speed stats: docs/battle-spec.md
- Edge functions, pg_cron jobs, routing: docs/infra.md
- Pre-launch reset sequence: docs/pre-launch.md

## Queued
- Battle Phase C: Flutter UI + Flame/Lottie integration (assets pending)
- Battle Phase D: map buff wiring, matchmaking queue, balance tuning
- Battle Chit collectible economy (post-launch)
- Slice 2: comprehensive is_test_account filter sweep
- Celebrity profile pictures (pre-launch)
- Onboarding walkthrough (4-5 slide PageView)
- Profile avatars from connected platform data
- Arena Visual Pass 2/3
- Know Your Customer (KYC) verification — required before any real-money or regulated features go live
- Marketing campaign and launch-day animation
