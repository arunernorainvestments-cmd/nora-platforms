# NORA Platforms — Collections, Mystery Box, Clip Campaigns & Market Re-theme Build Spec
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md, HANDOFF.md, and `NORA_PLATFORMS_MARKETPLACE_SPEC.md` in full before touching any file.**
Compiled: 2026-07-23 · The "double down on collectible cards" pivot: Collections (multi-copy series minting), the Mystery Box reward pool, Clip Campaigns (bounty clips → mints), card-centric prediction markets, and home-menu routing.

> **How ambiguity is handled in this doc:** wherever the correct answer depends on repo state this spec cannot see, the section carries a **❓ REPO-CHECK** block. Claude Code MUST resolve each REPO-CHECK against the actual codebase (read the named files/migrations in full — Hard Rule 11) and record the resolution in the phase's PR description before building that item. Where a REPO-CHECK offers a default, prefer the default unless the repo contradicts it. Questions marked **[FOUNDER]** are product calls — surface them and stop; do not guess.

---

## 0. How to use this document + ground-truth reconciliation

**Before any phase:**
1. `ls supabase/migrations/` and reconcile the ledger. HANDOFF says next = **153**; `NORA_PLATFORMS_MARKETPLACE_SPEC.md` (the fixed-price marketplace doc) may have consumed 153–155.
   **❓ REPO-CHECK 0.1:** Were marketplace migs 153–155 (`marketplace_tier_pricing`, `marketplace_listings`/`marketplace_sales`, list/buy/delist RPCs) applied? If YES → this spec **extends** them (numbering continues after them) and Phase N3 modifies rather than creates. If NO → fold the marketplace M1 core into Phase N3 of this spec and this spec owns the numbering. Also check whether the pre-existing `chit-marketplace-{buy,list}` edge functions contain logic to reuse or are stubs to supersede.
2. Migrations apply **only** via `supabase db push`. `flutter analyze` zero issues before/after every phase; `deno check` clean.
3. All money math in **integer USD cents; no floats anywhere** (Hard Rule 33 discipline). Append-only ledgers stay INSERT-only (Rule 29). Idempotent credits (receipt ledger + `ON CONFLICT DO NOTHING`).
4. **Hard Rules most in play:** 27 (`moment_chits` ≠ `battle_chit_definitions` — never conflate), 29 (append-only), 30 (never fabricate legal language), 33 (currency wall), 34 (stats always ladder-derived, never user-set — **price is not a stat**; minters may set prices, never power), 36 (ascension between matches only; snapshot at start), 37–39 (mint consent/moderation stack — the Clip Campaign pipeline inherits ALL of it).
5. **The archived Campaigns system (mig 089) stays archived.** The new system in Phase N7 is a different product (clip bounties) and takes a **new schema namespace (`clip_campaigns_*`)**. Do not resurrect, extend, or rename the archived `campaigns` tables (PLAN.md: "do not resume").

**Relationship to `NORA_PLATFORMS_MARKETPLACE_SPEC.md`:** that doc built the single-card fixed-price marketplace token-first. This spec **supersedes its currency posture** (see §1.4 — marketplace participation is now KYC'd and USD-oriented) and **supersedes its one-listing/one-card scope** for Market Makers. Its mechanics (escrow-on-list, price snapshot, attribution preservation, fee handling, idempotency, allowance function) are inherited wholesale — do not rebuild what it built; extend it.

---

## 1. The model (canonical — encode everywhere)

### 1.1 Revenue model (the platform is free)
The app is **free to use**. Platform revenue comes from exactly two places:
1. **A percentage fee on card sales** in the marketplace (collection primary sales + all resales).
2. **Collection mint fees** — a Market Maker pays to mint a Collection for sale.

Minting your **own single card for yourself is free** (unchanged). No paywalls on gameplay, browsing, or single self-minting.

**❓ REPO-CHECK 1.1 [FOUNDER]:** exact fee percentage on sales and the collection-mint fee schedule (flat vs per-card-count vs per-supply). Build both as config rows (`platform_fee_config`), seed placeholder values (suggested defaults: 10% sale fee; collection mint fee = $5 base + $0.50 × total copies authorized), and surface for founder sign-off before live.

### 1.2 Collections (the core new asset structure)
A **Collection** is a Market Maker minting **multiple owned posts as a themed series** (e.g. an athlete's 5-post World Cup highlight series; Togi's 5 most memorable YouTube moments). Properties:

- **Composed of 1–N distinct cards** (distinct source posts), each individually run through the FULL existing mint pipeline (OAuth-owned post, allowlist, pre/post-gen moderation, ladder-derived stats — every Hard Rule 37–39 gate, per card, no exceptions).
- **Per-card supply set by the minter: 1–1000 copies.** The minter chooses exclusivity. Supply is **fixed at mint — it can never be increased** (finiteness is the product promise; see G-COLL §2).
- **Serialized copies:** every copy is a unique instance displaying **"# of N"** + the **original minter's social handle + source platform** (YouTube/TikTok/etc.). Attribution is permanent and survives every transfer (extends the existing `original_minter_handle` rule).
- **Sold as a unit at a fixed, minter-set price**: a buyer purchases the whole collection and receives one copy of each card, usable in Arena. (Minter-set *price* is permitted; minter-set *power* is not — Rule 34 untouched: tier/stats stay engagement- and ladder-derived per card.)
- **Resale:** copy owners may relist individual copies on the open marketplace at any time. **The original minter has no ongoing stake in resales** — no royalty, no cut (this deliberately diverges from the P5 played-in-match royalty, which is a separate, match-revenue mechanism and is unaffected).
- Collections are **Market Maker–only** (KYC'd + linked social profiles). Ordinary users keep the existing one-active-self-minted rule; **Market Maker collection minting supersedes that rule for collection cards only** (their personal single self-mint slot is unchanged and separate).

### 1.3 KYC matrix (who must verify, and when)
| Action | KYC required? |
|---|---|
| Mint your own single card (keep it, play it) | **No** |
| Mint a Collection for sale (become a Market Maker) | **Yes** (+ linked social profiles) |
| Buy or resell on the marketplace | **Yes** |
| Pull a card from a Mystery Box (gameplay reward) | No |
| **Sell** a pulled card / hold a dollar balance | **Yes** (KYC at marketplace entry) |
| **Withdraw** dollar balance | **Yes** (already KYC'd; withdrawal is the hard money gate) |

**❓ REPO-CHECK 1.3:** the existing KYC flow (`kyc-create-session`, `is_kyc_verified`, `identity_hash`) — confirm it supports a "verified but not payout-onboarded" intermediate state, or whether marketplace-entry KYC and Stripe-Connect payout onboarding must be modeled as two distinct flags. Default: two flags (`kyc_verified`, `payout_onboarded`).

### 1.4 Currency posture (supersedes the marketplace spec's token-first stance)
Because marketplace participation is now KYC-gated and balances are **"real dollar balances,"** the marketplace is **USD-first**: prices in integer cents, settlement on the existing sim/live-switched USD rail (`battle_payments_mode`, `sim_usd_balances` → Stripe Treasury), platform fee taken in cents. Beta runs the whole economy in **sim mode** — build like-live, flip later (the established P5 pattern).

**❓ REPO-CHECK 1.4 [FOUNDER]:** the fate of the token lane the marketplace spec shipped/specced. Options: (a) retire tokens from the marketplace entirely (tokens stay for Markets bets + challenges only — cleanest currency wall); (b) keep a token lane for F–B tiers as the no-cash on-ramp. Default: **(a)** — flag for founder confirmation. Either way, tokens NEVER convert to USD (the wall stands).

### 1.5 Mystery Box (reward pool — beta: visible but disabled)
- Market Makers may **submit a portion of their collection's copies to the platform Mystery Pool** and are **paid a fixed amount by the platform immediately** on acceptance (platform buys the copy at a config price).
- The pool holds copies from many creators plus **generic cards** (platform-authored, in-game-use only, never marketplace-listable).
- Boxes are **awarded through gameplay only** — tournament wins, Champion Spotlight battles, events, challenges, random drops. **Mystery Boxes are NEVER sold for money or tokens** (this is the line between a gameplay reward and a loot box; it is load-bearing for §2 G-COLL and non-negotiable).
- A pulled creator card is a real serialized copy: usable in Arena immediately; sellable on the marketplace once the holder passes KYC; proceeds land in their dollar balance; withdrawal per §1.3.
- **Beta state:** the "Submit to Mystery Box Pool" button is **displayed with a brief explainer but not functional** ("Coming after Beta — the platform will purchase submitted cards at a fixed rate for the community reward pool"). The full backend ships behind a config flag `MYSTERY_POOL_MODE=disabled|sim|live`, default `disabled`.

### 1.6 Clip Campaigns (the new "Campaigns")
A **bounty marketplace for raw clips**: Market Makers post what clips they want + what they'll pay; clippers submit; **every submission passes platform moderation BEFORE the Market Maker ever sees it**; the Market Maker picks winners; payment settles in-app; the winning clip may feed a mint and be displayed on the Market Maker's public profile next to the resulting card.

- Uses a **new schema namespace** (`clip_campaigns_*`). The archived mig-089 `campaigns` tables are untouched (§0.5).
- Payment: Market Maker sets a budget, **escrowed at campaign creation** on the USD rail (sim in beta); winner payout is atomic + idempotent; platform fee per §1.1 config.
- Moderation: the submission pipeline inherits the mint moderation stack **verbatim** — minor-safety/CSAM screen absolute and first, nsfw/violence/hate blocks, escalation queue, human review path (Hard Rules 37–39 apply to campaign clips exactly as to mint clips). A clip rejected by moderation is never visible to the Market Maker.
- Ownership/consent: a submitted clip must be the **clipper's own upload of content they have rights to submit**, and the eventual MINT still runs through the Market Maker's own OAuth-owned-post pipeline. **❓ REPO-CHECK 1.6:** reconcile this consent chain — the mint consent model (HR37) requires the *minter* to own the source post. Determine and document (in CLAUDE.md, this phase) how a campaign-sourced clip legally feeds a mint: default model = the clip is the *device-clip* leg (`moment-clip-attach` path) tethered to a post the Market Maker already owns (e.g. the clipper cut a highlight FROM the Market Maker's own content). If the repo's consent model cannot support any clipper-sourced path, ship campaigns as clip-licensing only (payment + profile display) and gate the mint-feed behind founder+counsel review. Do NOT weaken HR37 to make this fit.

### 1.7 Prediction markets — card-centric re-theme
Markets pivot from creator Display Score to **card/collection events**, all resolvable from platform-internal data (cleaner oracles than social metrics):
- *"How long until card X ascends to tier Y?"* (resolves from `chit_ascension_log`)
- *"Who will be Champion Spotlight this week?"* (resolves from the spotlight computation)
- *"What date will collection Z sell out?"* (resolves from collection supply hitting zero)

Token-settled, on the existing Markets rail (Hard Rule 33: Markets = tokens — unchanged). These are **new `resolution_type` values + resolver functions**, not a new market system.

### 1.8 Home menu (the small, immediate fix)
The top-of-home category buttons (Trending, Athletes, Influencers, Artists, …) currently animate but don't route. They will route to the marketplace **filtered by archetype family / trending**, alongside "Explore All" → the full market view. Categories map to the canonical 10 archetype families.

---

## 2. Decision gates & locked decisions

| Item | Status |
|---|---|
| 🚧 **G-COLL (supersedes/unparks G-CARDVAL scope)** | **FOUNDER-DIRECTED, COUNSEL-GATED.** Finite multi-copy supply + open resale is the parked G-CARDVAL model (PLAN.md flagged Howey/investment-contract exposure). The founder has directed the build; therefore: **build all mechanics now (sim), but (a) the language ban is ABSOLUTE** — no user-facing surface may use appreciation/investment/return/yield/"becomes more valuable"/scarcity-as-value framing; collections are marketed as collectible game assets, period; **(b) no live real-money flip until counsel signs off** (same gate class as G-MON); **(c) Mystery Boxes are never sold** (earned only — the paid-randomized combination is the brightest legal line in this doc). Mirror this gate into PLAN.md and CLAUDE.md governance. |
| 🚧 **G-MYSTERY** | Mystery Pool submission + platform fixed-payment: **disabled in beta** (button visible + explainer, non-functional). Backend built behind `MYSTERY_POOL_MODE`. Platform payment rates = config, founder-set. |
| **Free app / two revenue streams** | LOCKED (§1.1). Fee numbers = REPO-CHECK 1.1 [FOUNDER]. |
| **Supply fixed at mint, 1–1000, never increasable** | LOCKED. |
| **No minter royalty on resale** | LOCKED (P5 match-royalty unaffected and separate). |
| **KYC matrix** | LOCKED (§1.3). |
| **Serialized copies ("# of N" + handle + platform)** | LOCKED. |
| **Campaigns = new namespace, archive untouched** | LOCKED. |
| **Markets re-theme = token-settled, new resolution types** | LOCKED. |
| Token lane fate | ❓ REPO-CHECK 1.4 [FOUNDER]. |

---

## PHASE N1 — Home menu routing + market category filters
**Effort:** S · **Depends:** nothing · **PR:** `coll-n1-home-routing` · *Ship first — it's user-visible and independent.*

- [FIX] Wire each category button to route (GoRouter) to the market surface with a filter param: `/markets?family=athlete`, `?family=influencer`, etc.; "Trending" → `/markets?sort=trending`. "Explore All" keeps its current route.
- [NEW] The destination market view accepts + renders these filters against collection/card listings (full listing UI matures in N3; N1 may land with the filter plumbing reading whatever listing data exists).
- **❓ REPO-CHECK N1.1:** read the home screen widget + `lib/core/router/` in full. Confirm (a) the exact button list vs the canonical 10 families and how non-family buttons (e.g. "Trending") are modeled; (b) whether `/markets` (prediction markets) or `/marketplace` (likeness cards) is the right host route for card-collection browsing, or whether a new `/market` route (per the marketplace spec) exists/should exist. Default: a dedicated card-market route; category buttons point there; do NOT overload the likeness-card `/marketplace`.

**Deliverables:** every category button routes; filters functional; `flutter analyze` clean.
**DO NOT** leave any animated-but-dead button · route categories to prediction markets (they filter the CARD market).

---

## PHASE N2 — Serialized copies + Collections (the foundation)
**Effort:** XL · **Depends:** mint pipeline (shipped) · **PR:** `coll-n2-collections`

### N2.1 Per-copy identity (the biggest schema change in this spec)
Mig 117 made copies **fungible** (`chit_ownership` quantity). "# of N" serialization requires **unique copy instances**.
- [NEW] **`chit_copies`** — one row per physical copy: `id`, `chit_id` FK `moment_chits`, `serial_number` (int, 1..N), `total_supply` (int, denormalized for display), `owner_user_id`, `state` (`owned|listed_escrow|wager_escrow|mystery_pool`), timestamps. UNIQUE `(chit_id, serial_number)`. Ownership transfers = append-only copy-transfer ledger (Rule 29 pattern) + current-owner update on the copy row.
- [NEW] `moment_chits.total_supply` (1–1000, CHECK; **immutable after mint** — enforce with a trigger). Existing single self-minted chits backfill as `total_supply=1`, serial 1.
- **❓ REPO-CHECK N2.1:** read migs 117 + 148 in full. (a) Does `card_serial` (mig 148) already carry per-copy or per-definition semantics? Reconcile — the display field and `chit_copies.serial_number` must not tell two stories; migrate/rename as needed. (b) Determine the migration path for existing `chit_ownership` quantities → `chit_copies` rows, and whether `chit_ownership` remains as a derived holdings view or is superseded. Default: keep `chit_ownership` as a derived view over `chit_copies` so existing consumers (deck validation, barter, P5 passive-holder routing) keep working; update those consumers only where copy-level identity matters.
- **❓ REPO-CHECK N2.2:** trace every consumer of `chit_ownership` (deck entry, `chit-barter`, wager escrow mig 142, P5 `ccg_settle_market` passive slice) and confirm each still resolves correctly over copies. Wager escrow now stakes a *specific copy*.

### N2.2 Collections
- [NEW] **`collections`** — `id`, `market_maker_user_id` (KYC-gated), `title`, `description`, `cover_art_url`, `status` (`draft|minting|listed|sold_out|closed`), `price_cents` (minter-set, integer), `mint_fee_paid_cents`, timestamps. **`collection_chits`** — collection ↔ `moment_chits` members with display order.
- [NEW] **Collection mint flow:** Market Maker (KYC + linked socials verified) assembles 1–N of their own posts → each runs the FULL existing mint pipeline per card (no shortcuts; HR37–39 per card) → sets per-card `total_supply` (1–1000) and the collection `price_cents` → **pays the collection mint fee** (config per REPO-CHECK 1.1; charged on the USD rail, sim in beta; idempotent receipt) → `chit_copies` rows generated (all owned by the minter until sold) → collection `listed`.
- [NEW] Market Maker flag/role: `profiles.is_market_maker` semantics extended (or a new flag) = KYC'd + ≥1 linked social. **❓ REPO-CHECK N2.3:** `is_market_maker` already exists and is used by test-account filters (Hard Rule 15 sweep). Read its current semantics; if overloading it would pollute the ranking-filter logic, add a distinct `is_collection_minter` flag instead. Default: distinct flag.
- One-active-self-minted (mig 142) is **scoped**: applies to the personal free self-mint slot; collection cards are exempt (they live under the collection + mint fee). Enforce so the swap-delete flow never touches collection cards.

**Deliverables:** `chit_copies` + serialization live, existing data migrated, all consumers green; collections mintable end-to-end in sim (fee charged, copies generated, "# of N" + handle + platform render on CardFace); supply immutability enforced; `flutter analyze`/`deno check` clean.
**DO NOT** allow supply increase after mint · let collection minting bypass ANY per-card moderation/consent gate · let minters set stats/tier (price only) · break existing single-mint users' data · touch the archived mig-089 campaigns tables.

---

## PHASE N3 — Marketplace integration (collections + copy resale, USD-first)
**Effort:** L · **Depends:** N2 (+ marketplace spec M1 per REPO-CHECK 0.1) · **PR:** `coll-n3-market`

- [EXTEND] **Collection primary sale:** buy-collection RPC — buyer (KYC'd) pays `price_cents`; receives **one copy of each member card** (lowest available serials); platform fee (config) deducted; minter credited net; all atomic + idempotent; when the last full set is no longer available, collection → `sold_out` (feeds the N5 sellout market + the pool-value story that must never be marketed as such).
- [EXTEND] **Individual copy resale:** the marketplace spec's list/buy/delist mechanics now operate on **`chit_copies`** (a listing = a specific serial). Inherit: escrow-on-list, snapshot pricing, attribution preservation, allowance function, idempotency. Re-point currency per §1.4 (USD cents, sim rail; platform fee replaces/joins the A/S burn per REPO-CHECK 1.4 resolution).
- [EXTEND] Seller payouts accrue to the dollar balance (`sim_usd_balances` in beta); **withdrawal RPC stubbed behind the live flip** (RAISE until Stripe Connect onboarding lands — the P5 pattern).
- **❓ REPO-CHECK N3.1:** resale pricing — the marketplace spec fixed prices by tier; collections introduce minter-set collection prices. For **copy resales**, confirm whether resale prices stay tier-fixed (simplest, no price discovery) or become seller-set. Default: **seller-set within config min/max bands per tier** (the founder's "worth something on the marketplace" implies price freedom; bands keep it sane). [FOUNDER] confirm.

**Deliverables:** collection buy + copy resale live in sim; fees to platform; balances accrue; sellout state transitions; KYC enforced at every marketplace entry point.
**DO NOT** let any marketplace write skip KYC · mix tokens and USD in one settlement path (Rule 33) · pay any resale royalty to the original minter · use floats.

---

## PHASE N4 — Profile & collection surfaces
**Effort:** M · **Depends:** N2 · **PR:** `coll-n4-profiles`

- [NEW] **Market Maker profile section** (public `/u/:username` + private `/profile`): "Collections" — cards created, supply/sold counts (counts are fine; no value/appreciation figures — G-COLL language ban), links to market listings. Campaign-won clips + their associated mints display here too (hook built now, populated by N7).
- [NEW] **Collection view in `/collection`:** users can group/filter their owned copies by collection (plus the existing flat view). Serial + "# of N" + minter handle + source platform visible on every copy.
- **❓ REPO-CHECK N4.1:** read `features/profile/` + `features/collection/` providers; confirm plain-Riverpod provider shape and whether profile pages already have a sectioned layout to extend vs a rebuild.

**Deliverables:** both profile surfaces + collection grouping shipped; `flutter analyze` clean.
**DO NOT** display value-tracking/appreciation stats on any surface (G-COLL) · leak private holdings on public profiles beyond what the owner opts to show (**❓ REPO-CHECK N4.2:** default = public profile shows collections *created*; holdings *owned* are private-page only unless an existing public-collection precedent exists in the repo).

---

## PHASE N5 — Prediction market re-theme (card-centric markets)
**Effort:** M · **Depends:** N2 (ascension/sellout data), existing Markets rail · **PR:** `coll-n5-markets`

- [NEW] `resolution_type` values + resolver fns, all token-settled on the existing Markets rail:
  - `card_ascension_time` — "Will card X reach tier Y by date D?" Resolves from `chit_ascension_log`. (Author as binary/date-bucket markets — the existing pool model is binary/categorical; avoid continuous-time payout structures.)
  - `spotlight_champion` — "Who will be Champion Spotlight this week?" Categorical over candidates; resolves from the spotlight computation. **❓ REPO-CHECK N5.1:** read `compute-spotlight` — confirm what it computes, cadence, and whether "Champion Spotlight" (a battle event per §1.5) exists or needs defining; if it's a new event type, spec it minimally (weekly featured match/winner) and [FOUNDER]-flag the format.
  - `collection_sellout_date` — "Will collection Z sell out by date D?" Resolves from N3's sold-out transition.
- [EXTEND] Market creation/resolution wiring for the new types in `resolve-markets`; oracle = internal tables (no social-API dependency).
- **❓ REPO-CHECK N5.2 [FOUNDER]:** fate of existing Display-Score markets — retire, or run alongside? Default: run alongside during beta; retire = product call.
- Integrity: ascension markets create a manipulation seam (a minter can influence their own card's engagement/ascension). Extend the one-role integrity pattern (Rule 26 class): **the card's minter/owner cannot bet on that card's ascension market.**

**Deliverables:** three new market types create/resolve end-to-end in tokens; minter-self-bet blocked; existing Markets untouched otherwise.
**DO NOT** settle these in USD (Markets = tokens, Rule 33) · resolve from social APIs when an internal table is the oracle · let a minter bet their own card's market.

---

## PHASE N6 — Mystery Box (built behind flag; beta-disabled)
**Effort:** L · **Depends:** N2, N3 · **PR:** `coll-n6-mystery`

- [NEW] **`mystery_pool`** — copies held by the platform: creator copies (state `mystery_pool`, acquired via submission) + **generic cards** (platform-authored `moment_chits` with `is_generic=TRUE`: in-game use only, `chit_copies` for them are **never marketplace-listable** — enforce in the listing RPC).
- [NEW] **Submission flow** (behind `MYSTERY_POOL_MODE`): Market Maker submits ≤ config-% of a collection's copies → platform pays the fixed config rate (per-tier table, [FOUNDER]-set; USD rail, sim first) → copy transfers to platform, state `mystery_pool`, attribution intact.
- [NEW] **Award engine:** `mystery_box_grant(p_user, p_context)` — server-only RPC invoked by gameplay hooks (tournament win, Champion Spotlight, events, challenges, random drop). Weighted draw across tiers (config weights, generic-heavy); pulled copy transfers to the user; append-only grant ledger; idempotent per context-key so one win = one box.
- [NEW] **Beta UI:** the submit button renders with the explainer copy and a disabled state; opening a box (when awards begin) has a reveal flow.
- **Never sellable:** no purchase path for boxes exists in any mode — grants come only from gameplay context keys. This is structural, not config.
- **❓ REPO-CHECK N6.1:** identify the real gameplay hooks to wire (`evaluate-challenges`, tournament/match-finish triggers, spotlight per N5.1) and whether an events framework exists or grants ship with challenges+spotlight only at first.

**Deliverables:** pool + submission + award engine behind flag; generic cards non-listable; beta shows disabled submit + explainer; grant ledger append-only.
**DO NOT** create any paid path to a box (structural ban) · let generic cards reach the marketplace · enable `MYSTERY_POOL_MODE` past `disabled` in beta · strip attribution on pool transfers.

---

## PHASE N7 — Clip Campaigns (new namespace; moderation-first)
**Effort:** XL · **Depends:** N2 (Market Maker role), USD rail · **PR:** `coll-n7-clip-campaigns`

- [NEW] **`clip_campaigns`** — `id`, `market_maker_user_id`, `title`, `brief` (what clips are wanted), `budget_cents` (escrowed at creation), `payout_per_clip_cents` (or winner-takes-budget — **❓ REPO-CHECK N7.1 [FOUNDER]:** payout structure: per-accepted-clip rate vs contest/winner model vs both. Default: per-accepted-clip rate with a max-accepted count so budget math is closed-form), `status` (`open|reviewing|closed|cancelled`), deadline.
- [NEW] **`clip_campaign_submissions`** — clipper uploads via the existing device-clip path (trimmer → private staging bucket; reuse the `mint-staging` pattern, separate prefix/bucket) → **moderation pipeline runs FIRST** (minor-safety absolute, nsfw/violence/hate, escalation queue — the mint stack verbatim) → only `approved` submissions become visible to the Market Maker. States: `submitted|in_moderation|rejected|approved|accepted|paid`.
- [NEW] **Acceptance + payment:** Market Maker accepts → payout from escrow to the clipper (KYC'd per §1.3, since they're receiving money) → platform fee per config → atomic, idempotent, append-only payment ledger. Cancelled/expired campaigns refund remaining escrow.
- [NEW] **Profile display + mint feed:** accepted clips displayable on the Market Maker's public profile (N4 hook) alongside the associated mint if/when one is made. The mint itself follows the REPO-CHECK 1.6 resolution — the campaign system hands the clip to the existing mint pipeline; it never mints directly.
- **❓ REPO-CHECK N7.2:** clipper eligibility — must clippers pass KYC to *submit*, or only to be *paid*? Default: submit freely, KYC required at first acceptance/payment (maximizes funnel, keeps the money gate).

**Deliverables:** campaign create (escrowed) → submit → moderate → review → accept → pay, end-to-end in sim; refund path; profile display; archived campaigns untouched.
**DO NOT** show ANY un-moderated clip to a Market Maker · touch mig-089 tables · release escrow outside accept/refund paths · let the campaign system mint directly (it feeds the pipeline, which owns consent) · weaken HR37–39 for campaign clips.

---

## Phase order & why
**N1** (independent, visible) → **N2** (foundation: everything else reads copies/collections) → **N3** (revenue) → **N4** (surfaces) → **N5** (markets; needs N2/N3 oracles) → **N6** (needs pool inventory from N2/N3) → **N7** (largest independent system; last). N4/N5 may run parallel after N3.

---

## Cross-repo contract (mirror into RECONCILIATION.md)

| Platforms provides | Arena (nora-arena / Unity) consumes |
|---|---|
| `chit_copies` (serial, total_supply, owner, state) | card display shows "# of N" + minter handle + source platform |
| `collections` + membership | collection-grouped collection view; collection badges |
| Copy-level wager escrow | wager mode stakes a specific serial |
| `mystery_box_grant` results + reveal events | box-opening reveal UI; granted copy lands in collection |
| Generic cards (`is_generic`, never listable) | in-game rendering only; no sell affordance |
| New market types (ascension/spotlight/sellout) | bet UI on token Markets rail (unchanged mechanics) |
| Champion Spotlight event (per N5.1 definition) | spotlight battle surface |

Minting + collections + campaigns remain **web-only** (Companion-App model); mobile deep-links to web.

---

## Per-phase report template
```
Phase Nx — <name>
- REPO-CHECKs resolved: <each ❓ id → what the repo showed → decision taken>
- [FOUNDER] items surfaced: <list — do not self-answer>
- What changed: <migrations, functions, tables, docs>
- flutter analyze / deno check: <clean / issues>
- Smoke test: <what was exercised>
- Gate status: <G-COLL language-ban audit done? G-MYSTERY still disabled?>
```
