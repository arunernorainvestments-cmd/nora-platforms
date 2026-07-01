# NORA Platforms — CLAUDE.md
# Last updated: 2026-07-01

## Project
Flutter web prediction-market + **card-battler** platform ("Moments" — the v3 CCG pivot),
one wallet, plus two community systems (Emergency Fund, Licensing Marketplace).
Pre-launch — July 4 2026. The v3 build path lives in `NORA_PLATFORMS_BUILD_SPEC_v3.md` (canonical
spec) + `NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md` (phased tracker, P0–P7).
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
27. **Naming (v3):** "Battle Chits" the single-use **powerup** collectibles live in `battle_chit_definitions`/`user_battle_chits` and are now **legacy/dormant** under the v3 card-battler. The v3 **card asset** — the minted-moment creature/spell that IS the game — is the **"moment chit"** in `moment_chits` (see Systems + PLAN P1). Do not conflate the two tables. The legacy powerup rule still holds: arena_abilities/arena_trigger are legacy-only, do not extend; legacy chit usage is participant-only and blocked while the caller holds a stake on the linked market.
28. identity_hash partial-UNIQUE on approved KYC rows is the sybil anchor — never drop it; Stripe Identity webhook populates it in live mode
29. lkn_agreements is append-only: after INSERT only status fields change (revoked/expired/suspended/transferred). terms_snapshot is immutable — verification reads the snapshot, never the live template. Enforced by the migration 111 BEFORE UPDATE guard trigger; never weaken it.
30. lkn_license_templates contract text is produced only by lkn-generate-contract from the pre-approved clause library — never generate novel legal language from AI.
31. lkn-verify validates the API key (X-NORA-API-Key header) and enforces the daily rate limit BEFORE any license data is read. Never return license data without a valid key.
32. The signing private key lives only as the NORA_SIGNING_PRIVATE_KEY edge-function secret (PKCS8 PEM). Never log it, return it, or commit it. lkn-verify degrades to signature:null when it is absent.
33. Battle prediction markets settle in **real money (USD)**, Markets settle in **tokens** — never cross the two currencies.
34. A chit's **archetype/effect-family and damage numbers come from the authored `tier_ladder`**, never user-set. Tier is **cost-banded** (higher tier = stronger AND costlier Aura) — never strictly-better-for-cost.
35. Real-money `battle_outcome` markets exist **only for matches where both players are KYC-verified** (per decision gate G-MON). Non-KYC matches run non-monetized.
36. Tier **ascension is one-directional** (never de-rank), applies **between matches only**, and matches **snapshot chit stats at start** — mid-match ascension can never alter an active match.

## The game (v3 — "Moments" card-battler, canonical)
> **v3 supersedes the v2.x 1v1 archetype-fighter model entirely.** The build path is `NORA_PLATFORMS_BUILD_SPEC_v3.md`
> + phased tracker `NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md` (P0–P7). Backend owns ALL game logic; Arena is display-only/server-authoritative.

Each player has **Life** (default 30), builds a **lean deck** (size 20, max 2 copies/chit) of **moment chits**, and on
their turn spends **Aura** (auto-ramp +1/turn to a cap of 10, refills each turn, **no land cards**) to summon chit
**creatures** (ATK + HP only, **no AP**, field cap **3**) onto a shared-3D field or cast one-shot **spell-moments**.
Win by reducing the opponent's Life to 0. Combat is **server-authoritative** — `process_battle_turn` resolves and emits
ordered `battle_events`; the client computes nothing.

- **The asset = the moment chit** (`moment_chits`, P1). A card minted from a real **viral moment** (a user's social post,
  consent at link). Owned/collected/traded. Card art = the viral thumbnail; body = a shared 3D humanoid rig + a minted
  cel-shaded moment video composited by camera cut on summon. Two value layers: **consent-minted user moments** (free to
  mint/collect, the base) and **licensed creator/celebrity moments** (premium packs on the `lkn_*` rail).
- **Tier ladder** (`tier_ladder`, P2) is the balance core: tiers **F/E/D/C/B/A/S**, **cost-banded** (higher tier stronger
  AND costlier — Hard Rule 34). Tier is assigned from engagement at mint; a chit's cost/atk/hp/effect are **derived**,
  never user-set. Archetype **families** (athlete/musician/artist/scientist/comedian/…) are the **effect-family classifier**.
- **Fusion** (`fusion_rules`, P2/P3) is **tag-based** — authored patterns on `{family, keyword, element, count}`, not
  per-card recipes — so it works for any user-minted chit.
- **Two resource gates:** **Aura** (personal, "can I afford it?", auto-ramp) and **Vibe** (`match_vibe`, P4 — shared,
  symmetric, market-driven, server-authoritative, passive floor; "is the crowd hyped?"). Premium ultimate chits need both.
- **Minting + ascension** (P6): moments → chits (link → recommend → animate → classify → tier-assign → moderate → mint).
  **Ascension** is one-directional, definition-level (all copies together), ≤1/7 days per user, between-matches only (Hard Rule 36).

## Systems (current, built)
- **Markets**: bet on creator Display Score direction, settled in **tokens** (Hard Rule 33). Pool: 90% winners / 5% platform / 5% Market Maker.
- **Battle prediction markets** (v3): `battle_outcome` markets over card-battler matches, settled in **real money (USD)**.
  Created **only when both players are KYC-verified** (decision gate **G-MON**, Hard Rule 35); non-KYC matches run
  non-monetized. Payout split routes the creator/passive slices to the **moment-owners of the chits actually played**
  ("summon your friend, your friend earns") — see PLAN P5.
- **Hot Topic**: celebrity buzz leaderboard, independent of games. 25 celebs, Claude scoring twice daily via Currents API.
- **Likeness Cards**: collectible character cards + stat sheets (6 stats). Marketplaces + weekly polls persist; **weekly
  polls/stat-multipliers go DORMANT under v3** (P7). Stat sheets are cosmetic-only in the card-battler.
- **Emergency Fund** (`/emergency-fund`, `ubi_*`): community mutual-aid pool, sim mode. Contribute → AI privately evaluates request → random contributor panel votes → Stripe Treasury disburses. Platform holds zero funds.
- **Licensing Marketplace** (`/licenses`, `lkn_*`): Right of Publicity licensing; now also the rail for **premium chit packs**. Buyers purchase priced tiers governed by toggle-driven templates → append-only `lkn_agreements` (Hard Rule 29). Public registry `/license/:id` (no PII). Verification REST API `GET api.noraplatforms.com/v1/verify`, X-NORA-API-Key auth, rate-limited (Hard Rule 31), ECDSA P-256 signed (Hard Rule 32). License IDs `LKN-[year]-[8 chars]`. Payments sim-mode (`LKN_PAYMENTS=sim`).

## Deprecated / retired by v3 (archive, don't drop)
- **The 1v1 archetype-fighter model**: the 6-player turn-based Battle resolver, **D&D six-stat characters**, per-archetype
  **move-sets** (`battle_abilities`), and **license-per-character battle eligibility** (`check_battle_eligibility` gating).
  Eligibility under v3 is "you own moment chits and have a legal deck." Retired schemas stay in place (P7 archives, never DROPs).
- **Legacy Arena** creator-vs-creator live 5-min 1v1 (ArenaScore in-memory, Back/Trigger) + legacy `battle_spectator_bets`
  path — walled off by integrity triggers (Hard Rules 26–28), retained until mobile bet path is settled (RECONCILIATION R3).
- **Legacy powerup "Battle Chits"** (`battle_chit_definitions`) — dormant; superseded by the moment-chit asset (Hard Rule 27).
- **Campaigns**: ARCHIVED (migration 089, replaced by Likeness Cards). Tables `campaigns_archived_*`, read-only. Do not resurrect.

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
- v3 card-battler spec (canonical *what*): **NORA_PLATFORMS_BUILD_SPEC_v3.md**
- v3 phased implementation tracker (the *how/when*, P0–P7, with repo-grounded reconciliation): **NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md**
- Where we're going, with build checklists: **PLAN.md**
- History, scoring formulas, DB schemas, infra (edge fns / pg_cron / routes), Arena testing, deploy runbooks,
  deprecated Campaigns framework, redesign migration ledger: **ARCHIVE.md**
- Arena + Battle mobile app lives in a separate repo (`arunernorainvestments-cmd/nora-arena`, its own CLAUDE.md). Shares this backend. Cross-repo contract + open decisions: **RECONCILIATION.md**.
