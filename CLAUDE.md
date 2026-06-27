# NORA Platforms — CLAUDE.md
# Last updated: 2026-06-27

## Project
Flutter web prediction market + live battle platform. Three games, one wallet,
plus two community systems (Emergency Fund, Licensing Marketplace).
Pre-launch — July 4 2026.
Repo: arunernorainvestments-cmd/nora-platforms
Supabase ref: cceisywxwhgljdpisjrl | Domain: noraplatforms.com (Cloudflare → Vercel → Flutter)

This repo keeps four docs. **CLAUDE.md** = canonical rules + how to build safely
(this file). **PLAN.md** = where we're going (future state not yet built). **ARCHIVE.md** =
where we've been (history, full schemas, scoring formulas, infra, runbooks, testing,
deprecated specs). **RECONCILIATION.md** = the cross-repo contract with the nora-arena mobile
app (what it consumes from this backend + open platform-side decisions). If CLAUDE.md and
ARCHIVE.md ever disagree, CLAUDE.md wins.

## Tech Stack
- Flutter web: plain Riverpod only (FutureProvider.autoDispose / Provider). NO @riverpod, NO build_runner, NO codegen. Ever.
- Backend: Supabase (PostgreSQL + RLS + Deno Edge Functions)
- Routing: GoRouter + PathUrlStrategy (clean URLs, no #)
- Hosting: Vercel catch-all rewrite → Flutter index.html
- Battle animations: Flame (sprites) + Lottie JSON (effects) + Flutter native (UI)
- LLM calls use claude-sonnet-4-6 (Hot Topic scoring, Emergency Fund AI). Never hardcode keys.

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
23. Emergency Fund AI evaluator facilitates only — never recommends approve/deny (Hard Rule: ubi_*)
24. ubi-documents Storage bucket has NO client-accessible signed URLs, ever — documents are AI-only
25. Individual vote values in ubi_panel_votes are forever private — no client SELECT policy, no index on vote column
26. One role per match: for a match with an open battle_outcome market, a verified human is COMBATANT (uses chits, cannot bet) or SPECTATOR (bets, cannot influence) — never both. Enforced at the DB layer across KYC-linked alts (identity_hash). Never weaken the bets/arena_events integrity triggers (migration 102)
27. Battle Chits are the canonical powerup system — arena_abilities/arena_trigger are legacy-only; do not extend them. Chit usage is participant-only and blocked while the caller holds a stake on the linked market
28. identity_hash partial-UNIQUE on approved KYC rows is the sybil anchor — never drop it; Stripe Identity webhook populates it in live mode
29. lkn_agreements is append-only: after INSERT only status fields change (revoked/expired/suspended/transferred). terms_snapshot is immutable — verification reads the snapshot, never the live template. Enforced by the migration 111 BEFORE UPDATE guard trigger; never weaken it.
30. lkn_license_templates contract text is produced only by lkn-generate-contract from the pre-approved clause library — never generate novel legal language from AI.
31. lkn-verify validates the API key (X-NORA-API-Key header) and enforces the daily rate limit BEFORE any license data is read. Never return license data without a valid key.
32. The signing private key lives only as the NORA_SIGNING_PRIVATE_KEY edge-function secret (PKCS8 PEM). Never log it, return it, or commit it. lkn-verify degrades to signature:null when it is absent.

## Systems (current, built)
- **Markets**: bet on creator Display Score direction. Pool: 90% winners / 5% platform / 5% Market Maker.
- **Arena**: now the **spectator + prediction-market surface over Battle matches** (markets with resolution_type='battle_outcome'). A legacy creator-vs-creator live 5-min 1v1 (ArenaScore in-memory, Back/Trigger) still coexists on /arena and is walled off by the integrity triggers (Hard Rules 26–28). Legacy pool: 90% backers / 5% platform / 5% winning creator.
- **Battle**: 6-player (2 teams of 3), turn-based, Pokémon-style. 1v1/2v2/3v3. Phases A+B+C done; matchmaking shipped. Phase D (map buffs, balance) queued.
- **Hot Topic**: celebrity buzz leaderboard, independent of games. 25 celebs, Claude scoring twice daily via Currents API.
- **Likeness Cards**: collectible character cards (replaced Campaigns). Owners field cards in Battle and share match rewards; original creator always eligible to battle as themselves. Stat sheets (6 stats, 300-pt budget) feed Battle/Arena. Card + Chit marketplaces, weekly polls (stat multipliers) round it out.
- **Battle Chits**: canonical single-use powerup collectibles (see Hard Rule 27 + ARCHIVE.md).
- **Emergency Fund** (`/emergency-fund`, `ubi_*`): community mutual-aid pool, sim mode. Contribute → AI privately evaluates request → random contributor panel votes → Stripe Treasury disburses. Platform holds zero funds.
- **Licensing Marketplace** (`/licenses`, `lkn_*`): Right of Publicity licensing. Buyers purchase priced tiers governed by toggle-driven templates → append-only `lkn_agreements` (Hard Rule 29). Public registry `/license/:id` (no PII). Verification REST API `GET api.noraplatforms.com/v1/verify`, X-NORA-API-Key auth, rate-limited (Hard Rule 31), ECDSA P-256 signed (Hard Rule 32). License IDs `LKN-[year]-[8 chars]`. Payments sim-mode (`LKN_PAYMENTS=sim`).
- **Campaigns**: ARCHIVED. Deprecated by migration 089, replaced by Likeness Cards. Tables renamed `campaigns_archived_*`, read-only; Flutter list screen shows a deprecation banner. Do not resurrect. Full framework + on-chain vision preserved in ARCHIVE.md.

## Building future work safely (governance)
Everything queued in PLAN.md must respect these, in addition to the Hard Rules above:
- **Migrations** apply only via the git-driven `supabase db push` flow so the
  `schema_migrations` ledger stays consistent. NEVER hand-run DDL through the Management API
  query endpoint — it applies the change without recording it and breaks the next push.
- **Likeness/card language** is collectible game assets, never financial instruments. Never use
  "investment", "return", "yield", "dividend", or "revenue share" in card-facing copy or code.
- **Append-only ledgers** — `likeness_card_transfers`, `lkn_agreements`, `campaigns_archived_ledger`
  — are INSERT-only. Never UPDATE an existing row (status-only changes on lkn_agreements per Rule 29).
- **sim vs live** is a per-feature mode flag (campaigns/cards/Emergency Fund/licensing). Build new money
  flows in sim first; KYC + payment gates flip on at live launch only. All monetary values are integer
  USD cents — no floating point anywhere in money math.
- **KYC staking gates** (`platform_integrity_settings`) default off in sim; flipping them on is the live-launch
  switch. `enforce_one_role_per_match` stays TRUE always (money-independent integrity).
- **IAP / token credit** functions must be idempotent (ON CONFLICT DO NOTHING + a receipt ledger) — web Stripe
  and mobile RevenueCat both credit the same `token_transactions`.
- **No backend in the mobile repo**: nora-arena is frontend-only. All tables, edge functions, and pg_cron
  stay in this Supabase project. Mobile reaches licensing only through `api.noraplatforms.com/v1/verify`.
- **Dev tooling** (arena bot-backer, test-match maintainer, dev_* RPCs) must be removed before launch — see the
  pre-launch reset sequence in ARCHIVE.md.

## Reference
- Where we're going, with build checklists: **PLAN.md**
- History, scoring formulas, DB schemas, infra (edge fns / pg_cron / routes), Arena testing, deploy runbooks,
  deprecated Campaigns framework, redesign migration ledger: **ARCHIVE.md**
- Arena + Battle mobile app lives in a separate repo (`arunernorainvestments-cmd/nora-arena`, its own CLAUDE.md). Shares this backend. Cross-repo contract + open decisions: **RECONCILIATION.md**.
