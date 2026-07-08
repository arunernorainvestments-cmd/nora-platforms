# NORA Platforms — HANDOFF / Catch-up
# Onboarding entry point for a new engineer/agent. Last consolidated: 2026-07-07.
#
# Read this FIRST, then CLAUDE.md (rules), then the doc referenced for whatever you're touching.
# This file orients you; it does not replace the canonical docs — it points you at them.

---

## 0. TL;DR — what this is and where it stands

**NORA Platforms** is a pre-launch (target **July 4 2026**) **Flutter-web** platform combining
prediction markets, a social **card-battler game** ("Moments"), and two community/finance systems,
all on **one wallet**, backed by **Supabase** (Postgres + RLS + Deno Edge Functions).

- **The game is the product.** As of the **v3 pivot (2026-07-01)** the center of gravity is the
  "Moments" collectible card-battler (CCG). Everything else (Markets, Hot Topic, Likeness Cards,
  Emergency Fund, Licensing) is a supporting or independent system.
- **Backend owns all game logic.** The client is display-only / server-authoritative. Combat is
  resolved server-side (`process_battle_turn`), emitting ordered `battle_events` the client renders.
- **State of build:** v3 phases **P0–P6 done + applied to prod**; the mint→card pipeline is
  **end-to-end in sim mode**; **P7 (launch hygiene) is outstanding**. DB migration ledger is at
  **152** (next = 153). `flutter analyze` and `deno check` are clean.
- **What's blocking "live":** external spend/creds (Segmind for video gen, prod social OAuth),
  a founder decision gate (**G-MON**, real-money go-live), key rotations, and the P7 reset. Details in §7.

---

## 1. The five-document contract (read the right one)

This repo is documentation-disciplined. Four canonical docs plus a set of specs. **If two docs
disagree, the priority is: CLAUDE.md > everything.**

| Doc | Role | When you read it |
|---|---|---|
| **CLAUDE.md** | Canonical **rules** + how to build safely. 39 numbered Hard Rules + governance. | Before writing any code. Non-negotiable. |
| **PLAN.md** | Where we're going — **future state**, build checklists, decision gates. | To pick up the next task. |
| **ARCHIVE.md** | Where we've been — history, **full schemas**, scoring formulas, infra, runbooks, deprecated specs. | When you need a schema, formula, or runbook. |
| **RECONCILIATION.md** | Cross-repo contract with the **nora-arena** mobile app (what it consumes + open decisions). | When touching anything mobile consumes. |
| **HANDOFF.md** (this) | Consolidated orientation + map. | First. |

**Spec docs** (the detailed *what/how* for the game):
- `NORA_PLATFORMS_BUILD_SPEC_v3.md` — canonical v3 card-battler spec (the *what*).
- `NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md` — phased tracker P0–P7 (the *how/when*), status per phase.
- `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md` — web minting, consent/moderation stack, match-cut templates, wager mode.
- `Minting_Workflow.md` — device-clip upload + trimmer, V2V middle, AGNOSTIC plates. **Wins where it conflicts** with the two specs above.
- `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md` — anchor plates + motion prompts + Seedance/Segmind generation (§4 prompt grammar + moderation still govern).
- `NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md` + `NORA_CHIT_EFFECT_LIBRARY_WAVE1.md` + `NORA_INTERACTION_LAYER_SPEC.md` — the card effect system (design principles, shipped Wave 1 library, reactive-depth roadmap).

---

## 2. The game in one screen ("Moments" CCG, v3 canonical)

A 1v1 lane-less card game. Each player has **Life** (default 30) and a **20-card lean deck**
(max 2 copies/chit) of **moment chits**.

- **Turn economy:** spend **Aura** (auto-ramps +1/turn to a cap of 10, refills each turn, **no land
  cards**) to summon **creature** chits (**ATK + HP only, no AP**, field cap **3**) or cast one-shot
  **spell-moments**. Reduce opponent Life to 0 to win.
- **Server-authoritative combat:** `process_battle_turn` resolves and emits ordered `battle_events`;
  **the client computes nothing**.
- **The asset = the moment chit** (`moment_chits` table). A card minted from a real **viral moment**
  (a user's owned social post; consent at link). Card art = the viral thumbnail; the body composites
  a minted cel-shaded moment video onto a shared 3D humanoid rig via a camera cut on summon.
  - Two value layers: **consent-minted user moments** (free, the base) and **licensed
    creator/celebrity moments** (premium packs on the `lkn_*` licensing rail).
- **Tier ladder** (`tier_ladder`) is the balance core: tiers **F/E/D/C/B/A/S**, **cost-banded**
  (higher tier = stronger AND costlier Aura — never strictly-better-for-cost, Hard Rule 34). A chit's
  cost/atk/hp/effect are **derived from engagement at mint, never user-set**.
- **Archetype families** (athlete/musician/artist/scientist/comedian/…) are the **effect-family
  classifier**. **Fusion** (`fusion_rules`) is **tag-based** (patterns on `{family, keyword, element,
  count}`), so it works for any user-minted chit — not per-card recipes.
- **Two resource gates:** **Aura** (personal — "can I afford it?") and **Vibe** (`match_vibe` —
  shared, symmetric, market-driven, server-authoritative — "is the crowd hyped?"). Premium ultimate
  chits need both.
- **Ascension** (tier up) is **one-directional** (never de-rank), **definition-level** (all copies
  together), **≤1/7 days per user**, **between matches only**; matches **snapshot chit stats at start**
  (Hard Rule 36).

**Naming trap (Hard Rule 27):** the legacy single-use powerup "**Battle Chits**"
(`battle_chit_definitions`) is **dormant/legacy** — do NOT extend it. The v3 game asset is the
**"moment chit"** in `moment_chits`. Different tables; never conflate. (The minting/cinematic specs
say "battlechit"/`battle_chits` — in this repo that means `moment_chits`.)

---

## 3. Systems map (what exists, what each is for)

### Game & game-adjacent (v3)
- **Moments card-battler** — the game (§2). CCG engine, tier ladder, effects, fusion, Vibe. Screens:
  `/collection`, `/mint`, `/battle*`. Backend migs 116–152.
- **Battle prediction markets** — `battle_outcome` markets over CCG matches, settled in **real money
  (USD)**. Created **only when both players are KYC-verified** (decision gate **G-MON**, Hard Rule 35);
  non-KYC matches run non-monetized. Payout routes creator/passive slices to the **moment-owners of
  the chits actually played** ("summon your friend, your friend earns" — PLAN P5).
- **Minting + Cinematic engine** — web-side pipeline that turns an owned social post into a chit:
  OAuth-owned post → pre-gen moderation → classify/tier → effect selection → stylized illustration →
  device-clip trim → cutscene MP4 (bracketed by two **house-owned AGNOSTIC anchor plates**, Seedance
  2.0 via Segmind) → post-gen moderation → practice-battle preview → store in **`battle-media`** bucket.
  See §5 for pipeline detail.

### Independent / supporting systems (v2.x base, reused by v3)
- **Markets** — bet on creator **Display Score** direction, settled in **tokens** (Hard Rule 33).
  Pool: 90% winners / 5% platform / 5% Market Maker. `/markets`.
- **Hot Topic** — celebrity buzz leaderboard (25 celebs), Claude scoring twice daily via Currents API.
  Independent of games. `/hot-topic`.
- **Likeness Cards** — collectible character cards + 6-stat sheets + marketplaces + weekly polls.
  Weekly polls/stat-multipliers go **DORMANT under v3** (P7); stat sheets are cosmetic-only in the
  battler. `/marketplace`.
- **Emergency Fund** (`ubi_*`, `/emergency-fund`) — community mutual-aid pool, **sim mode**.
  Contribute → **AI privately evaluates** → random contributor panel votes → Stripe Treasury
  disburses. Platform holds zero funds. Four hard privacy rules (23–25) — AI never recommends
  approve/deny; documents & individual votes are **private forever**.
- **Licensing Marketplace** (`lkn_*`, `/licenses`) — Right-of-Publicity licensing; also the rail for
  **premium chit packs**. Append-only `lkn_agreements` (Hard Rule 29). Public registry `/license/:id`
  (no PII). Verification REST API `GET api.noraplatforms.com/v1/verify` — X-NORA-API-Key auth,
  rate-limited (HR31), ECDSA P-256 signed (HR32). Payments sim-mode.

### Currency separation (critical)
**Two economies never cross (Hard Rule 33):** Markets settle in **tokens**; battle-outcome markets
settle in **real money USD**. All money math is **integer USD cents — no floats anywhere**.

### Deprecated / retired by v3 (archived-not-dropped; do not resume)
- The v2.x **1v1 archetype-fighter** model (6-player sprite Battle, D&D six-stat characters,
  per-archetype `battle_abilities` move-sets, license-per-character eligibility).
- **Legacy Arena** creator-vs-creator live 5-min 1v1 (ArenaScore in-memory, Back/Trigger) + legacy
  spectator-bet path — walled off by integrity triggers, retained until mobile cutover (RECONCILIATION R3).
- **Legacy powerup "Battle Chits"** (`battle_chit_definitions`) — dormant (§2 naming trap).
- **Campaigns** — ARCHIVED (mig 089), read-only, do not resurrect.

---

## 4. Codebase structure

```
nora-platforms/
├── CLAUDE.md, PLAN.md, ARCHIVE.md, RECONCILIATION.md, HANDOFF.md   # the doc contract
├── NORA_*.md, Minting_Workflow.md                                  # specs (see §1)
├── flutter_app/            # the Flutter web client
│   └── lib/
│       ├── main.dart
│       ├── core/           # config, constants, providers, router, shell, theme, utils, widgets
│       │                   #   core/widgets/card_face.dart = CardFace chip-frame widget
│       │                   #   core/config/supabase_config.dart
│       └── features/       # one dir per surface (see route table below)
│           ├── arena/ battle/ collection/ mint/          # game
│           ├── markets/ hot_topic/ marketplace/ polls/   # markets & cards
│           ├── emergency_fund/ licensing/ kyc/           # finance/legal
│           ├── auth/ onboarding/ home/ profile/ wallet/  # shell/account
│           ├── discover/ explore/ search/ challenges/    # discovery
│           └── campaigns/ launch/ notifications/ settings/ waitlist/ promotions/
├── supabase/
│   ├── migrations/         # 151 files, ledger at 152. Apply ONLY via `supabase db push`.
│   └── functions/          # 59 Deno edge functions (see groups below)
├── workers/stitch/         # Cloud Run "nora-stitch" worker (MP4 concat for §4 cinematic stitch)
├── tools/                  # cinematic/ + minting/ — paid micro-trial + authoring scripts (Deno/TS)
├── scripts/                # lkn-signing-key-setup.sh
└── assets/                 # plates (agnostic_*_plate_v1_16x9.png), etc.
```

**Tech-stack rules that bite (from CLAUDE.md Tech Stack + Hard Rules):**
- **Flutter web: plain Riverpod ONLY** — `FutureProvider.autoDispose` / `Provider`. **NO `@riverpod`,
  NO build_runner, NO codegen. Ever.**
- Routing: **GoRouter + PathUrlStrategy** (clean URLs, no `#`). Hosting: Vercel catch-all → Flutter.
- Backend: Supabase Postgres + RLS + Deno Edge Functions. Battle animations: Flame + Lottie + native.
- LLM calls use **`claude-sonnet-4-6`** (Hot Topic scoring, Emergency Fund AI, moderation). Never hardcode keys.
- Theme: bg `#0A0A0F` · surface `#1A1A2E` · primary `#6C63FF` · secondary `#03DAC6` · success `#00C896` · danger `#FF4757`.

**Edge function groups** (`supabase/functions/`, 59 total):
- **Game/mint:** `cinematic-mint`, `moment-ingest`, `moment-classify`, `moment-clip-attach`,
  `mint-cancel`, `chit-marketplace-{buy,list}`.
- **Markets/metrics:** `sync-platform-metrics` (**single function — never split, HR2**), `resolve-markets`,
  `compute-spotlight`, `create-checkout-session`, `stripe-webhook`, `apply-promotion`.
- **Hot Topic:** `hot-topic-{fetch-and-score,place-bet,reset-week,resolve-week}`.
- **Emergency Fund:** `ubi-{contribute,submit-request,upload-document,ai-evaluate,assemble-voting-panel,disburse}`.
- **Licensing:** `lkn-{create-listing,purchase-license,register-*,submit-template,revoke-license,verify,partner-apply}`.
- **Likeness/polls:** `likeness-*`, `poll-vote`.
- **OAuth/KYC/auth:** `oauth-{initiate,callback}`, `disconnect-platform`, `kyc-create-session`.
- **Mobile bridge:** `nora-arena-api-{market,profile,spotlight,token-balance}`, `mobile_iap_confirm`.
- **Arena (legacy/dev):** `arena-*`, `battle-tick-warmer` — **dev tooling must be removed pre-launch (P7)**.
- **Waitlist/misc:** `waitlist-*`, `record-invite-send`, `evaluate-challenges`, `celebrity-integration-seed`.

**Route surface** (GoRouter, `lib/core/router/`): `/` `/home` `/dashboard` · `/markets` `/markets/:id`
`/mybets` · `/hot-topic` · `/collection` `/mint` `/battle` `/battle/:matchId` `/battle/matchmaking`
`/battle/spectate/:matchId` `/battle/legacy` · `/arena` `/arena/:matchId` · `/marketplace` · `/polls`
`/poll/:pollId` · `/emergency-fund` (+`/contribute` `/request` `/my-requests` `/vote/:assignmentId`) ·
`/licenses` `/licenses/:listingId` `/license/:licenseId` `/my-licenses` `/partners` · `/wallet`
`/profile` `/u/:username` · `/kyc` `/verify-identity` · `/waitlist` `/join` `/w/:token` · auth
(`/login` `/signup` `/forgot-password`) · `/plan` `/faq` `/support` `/news` · legacy `/campaigns`.

---

## 5. The mint pipeline (highest-activity area — understand it before touching)

Turns an **owned** social post into a playable, printable chit. Governed by `Minting_Workflow.md`
(device-clip pivot, wins on conflict) + the two mint/cinematic specs. Consent & safety are absolute
(Hard Rules 37–39).

Flow (`/mint` wizard ↔ edge functions ↔ migs 135–152):
1. **Ingest** (`moment-ingest`) — user links an **OAuth-owned** post; source allowlist
   **TikTok/Instagram/YouTube only, no arbitrary-URL minting**. Pre-gen moderation (minor-safety/CSAM
   screen is **absolute, cannot be bypassed**).
2. **Classify + tier** (`moment-classify`) — engagement → tier (F–S) + family; effect/atk/hp/cost
   **derived, never user-set**.
3. **Effect selection** — server picks a real, balanced, printable effect from the **authored Wave-1
   library** (migs 151/152: 10 families × 3 templates), gated by `min_tier_band`.
4. **Clip** — because platform APIs never hand out the video file, the clip is **uploaded from the
   user's device**, but **only tethered to the already-approved owned moment** (`moment-clip-attach`):
   trimmed in-browser to 1–15s into the private **`mint-staging`** bucket → re-moderates sampled frames
   + runs thumbnail-vs-frame similarity (mismatch → human review, never silent mint).
5. **Generate cutscene** (`cinematic-mint`) — §2 V2V stylization (Core clip) → §3 Intro/Outro bridges
   (conditioned on the two **house-owned AGNOSTIC anchor plates** — `match_cut_anchor_plates`, HR39) →
   §4 stitch via Cloud Run **`nora-stitch`** worker + audio dub. Seeds/versions persisted per stage on
   `cinematic_generations`. **The style-lock + constraints prompt blocks are never user-influenced.**
6. **Post-gen moderation** on the finished MP4 (**mandatory — clean bookends never vouch for the
   middle, HR39**) → store in **`battle-media`** bucket (never a hotlinked provider URL, HR38).
7. **Preview** — user must preview the card in a **practice battle** before the chit finalizes.
8. **Finalize** — `cinematic_complete_mint`; chit carries `match_cut_template_id`, `anchor_plate_version`,
   `prompt_template_version`, `generation_seed`, plus display fields `rules_text`/`flavor_text`/`card_serial`
   (mig 148) rendered by the Flutter **CardFace** widget.

**Current status:** end-to-end works in **sim mode**; the generation back-half (§2–§4 real renders) is
**Track A**, blocked on `CINEMATIC_MODE=live` + Segmind spend. Config flags: `MINT_INGEST_MODE=live`,
`MOMENT_CLASSIFY_MODE=sim`, `CINEMATIC_MODE=sim`, `MODERATION_MODE=sim`, `MINT_CLIP_MODE=sim`.
Rules: **one active self-minted chit per user** (swap = warn → delete old only AFTER new mint confirms).

---

## 6. Where the build is (phase-by-phase)

**v3 phases** (detail in `NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md`):

| Phase | What | Status |
|---|---|---|
| P0 | Canonical model + governance (docs) | ✅ done |
| P1 | Chit catalog + collection + deck + ownership/barter | ✅ built (migs 116–121) |
| P2 | Tier ladder + anatomy + effects/keywords/families + fusion data ⭐ critical path | ✅ prod (122–125) |
| P3 | CCG combat engine (`process_battle_turn`) — largest build | ✅ prod (126–129) |
| P4 | Vibe meter backend | ✅ prod (130–131) |
| P5 | Real-money rail + market gating + payout (G-MON) | ✅ built like-live, **SIM behind switch** (132–134) |
| P6 | Minting pipeline + tier-ascension | ✅ prod (135–136) |
| **P7** | **Fusion expansion + deprecation cleanup + Fund + launch hygiene** | **◑ additive done (137); destructive/reset DEFERRED to launch prep** |

On top of P0–P6: cinematic engine + minting v2 (**migs 138–152**), Wave-1 effect library (151/152).
Migration ledger in sync at **152**; next = **153**.

---

## 7. What "launch" is still waiting on (the open list)

Two active build tracks (PLAN.md "Where we're going next"):
- **Track A — Minting §2–§4 generation back-half.** Buildable sim-first; needs `CINEMATIC_MODE=live`
  + Segmind spend to do real renders. Nodes: V2V stylization → Intro/Outro bridges → stitch+dub →
  finalize/post-gen moderation. Paid micro-trials per node (`tools/cinematic/trial_*.ts`) before wiring.
- **Track B — Effect system depth (Wave 2→3).** Compound-clause resolver (shared prereq) → charge-up
  state → Secrets → `negate` counterspell (the only piece that touches the turn loop; build last).
  Open design questions for the user in `NORA_INTERACTION_LAYER_SPEC.md` §6.

**External unblocks the user owns (gate go-live):**
- `CINEMATIC_MODE=live` + Segmind spend · `MODERATION_MODE=live` decision · production **TikTok** key
  (swap sandbox→prod at app approval) + **Instagram** `INSTAGRAM_CLIENT_ID/SECRET`.
- **G-MON confirmation** before any real-money go-live (gate is built; rule needs founder sign-off).
- **Key rotations (post-launch, pre-live):** `service_role` + `SUPABASE_ACCESS_TOKEN` (both appeared
  in session transcripts) and `NORA_SIGNING_PRIVATE_KEY` (known-compromised — generated in a Codespace;
  regenerate on a secure local machine, update secret + `.well-known/nora-public-key.pem`).
- **P7 pre-launch reset (ARCHIVE §A8):** archive (never DROP) retired schemas, DORMANT weekly
  polls/multipliers, remove ALL dev tooling (arena bot-backer, test-match maintainer, `dev_*` RPCs,
  cinematic/mint smoke users), final smoke tests.

**Cross-cutting remainders:**
- **Licensing:** gateway routing for `api.noraplatforms.com/v1/verify` → `lkn-verify` (unblocks mobile
  License Sync); `lkn-generate-contract` deferred until attorney-seeded `lkn_contract_clauses` exists
  (never fabricate legal language, HR30).
- **Mobile (nora-arena, separate repo — pivoted Flutter+Flame → Unity/C# + Meshy 3D):** merge
  `doc6-mobile-iap-confirm` (ee5a782); mirror new `moment_chits` display fields into RECONCILIATION so
  Unity prints identical card text; FCM push; RevenueCat IAP config. **No backend in the mobile repo** —
  it reaches licensing only through the verify API.
- **Pre-launch polish:** celebrity profile pictures (`celebs.image_url` NULL for all 25); the launch
  rocket MP4 the user owes.

**PARKED behind counsel — G-CARDVAL:** a founder idea for a card-value-accrual economy (finite-supply
cards appreciating from platform rake). **Do not build or describe on any user-facing surface until
legal clears it** — walks into Howey/investment-contract territory and crosses the token/USD economies.
The safe adjacent path (recurring creator earnings via P5 payout routing, no appreciation promise) is
already spec'd/partly built. Full analysis in PLAN.md.

---

## 8. Non-negotiables before you touch anything (condensed from CLAUDE.md)

Read **all 39 Hard Rules in CLAUDE.md** — these are the ones most likely to trip a new agent:

1. **Plain Riverpod only** — no codegen/@riverpod/build_runner, ever.
2. **`sync-platform-metrics` stays one function** (HR2); only it writes `display_score`/`heat_score` (HR3/4).
3. **Migrations apply ONLY via `supabase db push`** — never hand-run DDL through the Management API
   query endpoint (breaks the `schema_migrations` ledger).
4. **Read every file in full before modifying** (HR11). **`flutter analyze` zero issues before every
   commit** (HR12).
5. **Currency wall:** battle markets = USD, Markets = tokens, never cross (HR33). **Integer cents, no floats.**
6. **`moment_chits` ≠ `battle_chit_definitions`** — never conflate (HR27).
7. **Effect/tier/damage come from the authored `tier_ladder`, never user-set; cost-banded** (HR34).
8. **Chits mint only from an OAuth-owned post**, allowlisted sources, tethered device-clip, absolute
   minor-safety screen on source AND clip; **post-gen moderation on the finished MP4 is mandatory** (HR37–39).
9. **Append-only ledgers** (`lkn_agreements`, `likeness_card_transfers`, `chit_ownership`, archived
   ledgers) — INSERT-only; status-only changes where allowed.
10. **Emergency Fund privacy:** AI never recommends approve/deny; documents & individual votes private
    forever (HR23–25). **Licensing:** never generate novel legal language from AI (HR30).
11. **sim vs live is a per-feature flag**; build money flows sim-first. `enforce_one_role_per_match`
    stays TRUE always. **Never hardcode API keys** (HR9). **`noraplatforms.com` everywhere** — no vercel.app.
12. **Commit/push only when the user asks**; branch first if on `main`.

---

## 9. First moves for a new agent

1. Read **CLAUDE.md** top to bottom (rules + the game section + governance).
2. Skim **PLAN.md** "Status snapshot" + "Where we're going next" to see the two live tracks.
3. For a game/mint task: read the relevant spec (§1 table) + this §5. For a systems task: find the
   system in §3 and its edge functions in §4.
4. Before coding: confirm which **config flag / sim-vs-live** state your change assumes, and which
   **Hard Rules** apply. Migrations → `supabase db push` only, next number **153**.
5. Verify with `flutter analyze` (client) / `deno check` (functions) before proposing a commit; don't
   commit or push unless asked.
```
