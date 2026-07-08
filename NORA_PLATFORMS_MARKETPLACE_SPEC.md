# NORA Platforms — Chit Marketplace Build Spec (Fixed-Price, Token-First)
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md in full before touching any file.**
Compiled: 2026-07-08 · Adds the public **fixed-price marketplace** for minted moment chits (token lane live; USD lane shaped-but-stubbed behind the P5 switch).

> **Status (2026-07-08): M1 + M2 SHIPPED to prod** — migs 153–156, apply-time smokes green, Hard Rule 40
> added to CLAUDE.md, cross-repo contract mirrored into RECONCILIATION.md §8. **M3 (Flutter `/market`) is
> next** — tracked as PLAN.md Track C, alongside the §6 economy decisions (founder sign-off). M4 stays gated.

> Scope discipline: this is the **bare fixed-price mechanics** — list a card, buy a card, delist. **No** supply/demand pricing, **no** card-balancing economy, **no** value accrual. Fixed prices from a config table; the platform takes a fee on A/S sales. Everything is built token-first and USD-ready so the live flip is a config change, not a rewrite.

---

## 0. How to use this document + ground-truth reconciliation (AS BUILT, 2026-07-08)

Hard Rules in play: 27 (`moment_chits` ≠ `battle_chit_definitions`) · 29 (append-only ledgers) · 33 (currency wall, integer minor units, no floats) · 34 (stats ladder-derived) · **40** (the marketplace invariants, added with M1) · G-CARDVAL parking (fixed price only — no appreciation/investment language, ever). Migrations only via `supabase db push`.

**Ground-truth findings that shaped the build (recorded so M3+ doesn't re-derive them):**
- `chit-marketplace-{buy,list}` edge fns = the **legacy powerup** lane (`battle_chit_definitions` / `user_battle_chits` / `chit_marketplace_listings`) — HR27, left untouched. The moment-chit marketplace is a **fresh `marketplace_*` build, RPC-only, no edge functions**.
- Escrow reuses the **mig-142 wager pattern**: negative acquisition-ledger delta + a status row + partial-unique open index. The listing row plays the status-row role.
- `chit_ownership` is trigger-derived from the append-only `chit_acquisition_ledger` (mig 117); transfer = new ledger rows; the buy inserts directly (not via `chit_grant`) to carry the `acquired_currency` stamp.
- Token legs mirror `_barter_move_tokens` (mig 119): tx types `chit_purchase`/`chit_sale`, seller credit via `increment_token_balance`.
- Integration seams that had to be patched (all in mig 155): `self_mint_slot` counts listed chits (else listing frees the slot → double self-mint); `chit_swap_retire` blocked while listed; ascension **frozen** while escrowed (`moment_chit_rederive` guard + `chit_ascension_refresh` skip). Wager-staking a listed chit is blocked automatically (quantity=0 after escrow). Deck enforcement rides `deck_validate`'s ownership re-check at match entry (same as wager escrow — no purge on sale, matching wager-loss precedent).
- Listings require `finalized_at IS NOT NULL` — covers "pending preview / swap-pending" (migs 140/150).

---

## 1. The model (canonical)

[To be written — fixed-price; **one active listing per user**; **unique-card** listings (transfers ownership, attribution/`original_minter_handle`/`card_serial` survive, seller freed to mint again); **token lane live now / USD lane ready-not-on**; **provenance lock** (`acquired_currency`) baked in dormant; **no appreciation, ever**.]

**Pricing scale (config-driven `marketplace_tier_pricing`; token peg 100🪙 = $1, display-only, never cash-out):**

| Tier | USD (ready) | Tokens (live) | Platform fee (A/S only, **burn**) |
|---|---|---|---|
| F | $1 | 100🪙 | — |
| E | $2 | 200🪙 | — |
| D | $5 | 500🪙 | — |
| C | $10 | 1,000🪙 | — |
| B | $25 | 2,500🪙 | — |
| A | $50 | 5,000🪙 | 10% |
| S | $100 | 10,000🪙 | 15% |

---

## 2. Decision gates & locked decisions

| LOCKED (built or committed) | Needs founder sign-off (NOT built / NOT flipped) |
|---|---|
| One active listing per user (`marketplace_listing_allowance()`, default 1) | **USD lane flip** — `marketplace_usd_lane=TRUE` (mechanics shipped in M2, gate OFF) |
| Unique-card listings; attribution + `card_serial` survive transfer | Live money — `battle_payments_mode='live'` (Stripe Treasury/Connect, mig-132 stub) |
| Pricing scale §1 + peg 100🪙=$1 (display-only, never cash-out) | **Signup grant 500🪙** (currently 100) + §6 challenge-emission budget → CLAUDE.md currency-model edit |
| A/S fee-as-burn (A 10% / S 15%) | M4 battle pass / subscription (§7) |
| Provenance lock: token-bought → token-resale-only (ACTIVE since M2) | USD fee disposition at live (burn vs retain — decide at the flip) |
| KYC-on-USD both sides (enforced whenever the lane opens) | Route `/market` UX shape (M3 build) |

---

## PHASE M1 — Listing + fixed-price token sale (LIVE) — ✅ SHIPPED 2026-07-08
**Effort:** L · **Depends:** shipped mint pipeline + `chit_ownership` (117) + `battle_payments_mode` (132) · **Migrations:** 153–155 · **PR:** `mkt-m1-token-listings` (#11, merged)
**Prod smoke:** `MKT M1 smoke OK: sold S fee_burned=1500, delist returned escrow`. Note: RPCs shipped as auth wrappers over service-only `_internal(p_user, …)` fns (mig-101 pattern) so the apply-time smoke exercises real logic.

**Goal:** a user lists one owned chit at its fixed tier price, another user buys it with tokens, ownership transfers atomically with attribution intact, and the platform burns a fee on A/S sales. Token lane is **live**; the USD columns exist but are inert until M2.

### 3.1 Config: the pricing table
- [NEW] **`marketplace_tier_pricing`** — one row per tier F–S: `tier` (PK, CHECK ∈ F/E/D/C/B/A/S), `usd_cents` (int: 100/200/500/1000/2500/5000/10000), `token_price` (int: 100/200/500/1000/2500/5000/10000), `fee_bps` (int basis points: F–B = 0, A = 1000, S = 1500). Seed all 7 rows. Prices/fees are **config, not code** — tuning is an UPDATE here, never a rebuild. → **mig 153**.

### 3.2 Schema: listings over the ledger
- [NEW] **`marketplace_listings`** — the sale-offer layer over `chit_ownership` (never mutate the acquisition ledger; this is a *sibling* status table, Hard Rule 29): `id`, `chit_id` FK `moment_chits`, `seller_user_id`, `currency` (`'token'|'usd'` default `'token'`), `tier_snapshot`, `price_snapshot` (int — the frozen token price at list time), `fee_bps_snapshot`, `usd_cents_snapshot` (int, recorded but inert in M1), `status` (`'active'|'sold'|'delisted'`), `created_at`, `closed_at`. Escrow state on the chit reuses the **wager-escrow pattern (mig 142)** — a listed chit is held, not free. → **mig 154**.
- [NEW] **`marketplace_sales`** — append-only sale ledger (INSERT-only, Rule 29): `id`, `listing_id`, `chit_id`, `buyer_user_id`, `seller_user_id`, `currency`, `gross_price` (int), `fee_burned` (int), `net_to_seller` (int), `created_at`. → **mig 154**.
- [NEW] **Listing allowance helper** — `marketplace_listing_allowance(p_user)` returns the max concurrent active listings for a user, **default 1** (this *is* the "one active listing" rule). Written as a function, not a hardcoded constant, so a future subscription tier (§7) raises it via config without a schema change. The list RPC enforces `active_count < allowance`. → **mig 154**.
- RLS: public-read `status='active'` listings; a seller reads/manages only their own rows; **all writes via SECURITY DEFINER RPC only** — no client writes to any marketplace table (mirrors the `create_moment_chit` server-only-writer discipline).

### 3.3 RPCs (server-authoritative, atomic, idempotent)
- [NEW] **`marketplace_list_chit(p_chit_id)`** — verify caller owns the chit (`chit_ownership`); verify it is not already listed, not wager-staked, not pending a self-mint swap-delete; verify `active listings < marketplace_listing_allowance(caller)`; **snapshot** tier → `token_price` → `fee_bps` from `marketplace_tier_pricing`; move the chit into escrow and **freeze ascension while escrowed** (Hard Rule 36 stays satisfied — a listed card's tier/price can't shift under a live buyer); INSERT the `active` listing. → **mig 155**.
- [NEW] **`marketplace_buy_chit(p_listing_id)`** — verify listing `active`; verify `buyer ≠ seller`; verify buyer token balance ≥ `price_snapshot`. Then **in one transaction:** debit buyer `price_snapshot`; compute `fee = price_snapshot * fee_bps_snapshot / 10000` (integer floor); **burn the fee** (tokens leave supply — record `fee_burned`, credit it to no one); credit seller `price_snapshot − fee`; transfer ownership in `chit_ownership` (append a new acquisition-ledger row — **preserve `original_minter_handle` / `card_serial`**; set `acquired_currency='token'` — the provenance stamp M2 will enforce resale-currency against); release escrow to the buyer; mark listing `sold` + stamp `closed_at`; INSERT `marketplace_sales`. **Token moves go through the existing `increment_token_balance` + receipt-ledger idempotency** — a replayed buy is a no-op, never a double-spend. The bought chit does **not** consume the buyer's one-active-self-minted slot (attribution ≠ authorship; same treatment as wager-won cards, M-P4). → **mig 155**.
- [NEW] **`marketplace_delist_chit(p_listing_id)`** — seller-only; return the chit from escrow to the seller; unfreeze ascension; mark listing `delisted` + `closed_at`. → **mig 155**.
- [GUARD] **USD is inert in M1:** any RPC called with `currency='usd'` RAISEs (`'usd marketplace lane not enabled until M2'`). The column and `usd_cents_snapshot` exist only so M2 is a branch, not a migration of live data.

### 3.4 Apply-time smoke (prove the loop)
- [NEW] mig 155 seeds two dev users + one dev chit, runs list → buy → asserts (ownership moved, attribution preserved, seller credited `price − fee`, `fee_burned` correct on an S-tier, buyer slot untouched, listing `sold`), then a second list → delist → asserts (escrow returned, listing `delisted`). Synthetic rows auto-deleted; swept by the P7 reset. Log `MKT M1 smoke OK: sold S fee_burned=1500, delist returned escrow`.

**Deliverables**
- [x] `marketplace_tier_pricing` seeded (7 tiers, USD cents + token price + A/S fee_bps) — mig 153.
- [x] `marketplace_listings` + `marketplace_sales` (append-only) + escrow reuse + RLS (public-read active; server-only writes) — mig 154.
- [x] `marketplace_listing_allowance()` (default 1) gating concurrent listings — mig 154.
- [x] `marketplace_list_chit` / `marketplace_buy_chit` / `marketplace_delist_chit` — atomic, idempotent, attribution-preserving, A/S fee **burned** — mig 155.
- [x] `acquired_currency='token'` stamped on every bought chit (provenance seam for M2).
- [x] USD lane RAISEs (columns present, inert); apply-time smoke green on prod; no Dart yet → `flutter analyze` unaffected.

**DO NOT** mutate `chit_ownership` acquisition-ledger rows or `marketplace_sales` (INSERT + status-sibling only, Rule 29) · let a chit be listed while wager-staked/playable/swap-pending, or stay ascendable while escrowed · credit the A/S fee anywhere (it is a **burn**, not platform income) · use floats for price or fee (integer tokens; integer cents when USD lands — Rule 33) · strip `original_minter_handle`/`card_serial` on transfer · let a bought card eat the buyer's self-mint slot · bypass `increment_token_balance`/receipt-ledger idempotency · allow any client-side write to a marketplace table · enable the USD path in M1.

---

## PHASE M2 — USD-ready seam (BUILT LIKE-LIVE, SIM BEHIND SWITCH) — ✅ SHIPPED 2026-07-08
**Migration:** 156 · **PR:** `mkt-m2-usd-seam`
**Prod smoke:** `MKT M2 smoke OK: lane gated, KYC gated, provenance locked, sim USD sale 10000c (fee 1500c withheld), currency wall intact` (the smoke flips the lane ON inside its transaction and restores it — end state OFF).

Two independent gates, both OFF/founder-owned:
1. **`platform_integrity_settings.marketplace_usd_lane`** (NEW, default FALSE) + helper `marketplace_usd_enabled()` — whether the marketplace accepts USD at all. This is the §2 "USD lane flip".
2. **`battle_payments_mode()`** (mig 132) — sim settles against `sim_usd_balances` via `ccg_usd_debit`/`ccg_usd_credit`; `live` RAISEs until Stripe Treasury/Connect lands. The live flip is config + the mig-132 Treasury work, not a marketplace rewrite.

**Deliverables (all shipped)**
- [x] `currency` branch on list/buy: USD gross = `usd_cents_snapshot` (frozen at list), fee in **integer cents**, floor division; delist unchanged (no money moves).
- [x] **Provenance lock ACTIVE**: any token-stamped acquisition of the chit by the seller ⇒ token-resale-only. One-directional — USD-bought copies may relist for tokens (money → tokens is a sink, safe). Free emission structurally cannot reach USD.
- [x] KYC-on-USD: seller `is_eligible_for_real_money` to list, buyer to buy (KYC in sim; +18/jurisdiction activate with live mode). Token lane stays KYC-free.
- [x] **Currency wall smoke-asserted**: a USD sale writes `sim_usd_transactions` only — never `token_transactions` (HR33).
- [x] `acquired_currency='usd'` stamped on USD purchases; wrapper became `marketplace_list_chit(p_chit_id, p_currency DEFAULT 'token')` (old 1-arg dropped — no PostgREST overload ambiguity).

**DO NOT** flip `marketplace_usd_lane` without founder sign-off · flip `battle_payments_mode` to live before the Treasury/Connect branch + key rotations land · let a USD movement touch `token_transactions` (or vice versa) · weaken the provenance lock to per-copy heuristics (the (seller, chit) grain is deliberately conservative) · credit the USD fee anywhere in sim (live disposition is a founder decision at the flip).

---

## PHASE M3 — Flutter client (plain Riverpod)

[To be written — `/market` browse/list; Sell action surfaced from `/collection` + mint-success; buy/delist flows; CardFace render; plain Riverpod only (no codegen); GoRouter; theme tokens; `flutter analyze` clean. Deliverables + DO NOT.]

**Deliverables**
- [ ] [placeholder]

**DO NOT** [placeholder]

---

## 6. Token economy — sources, sinks & challenge emissions

[To be written — the closed loop. SOURCES: signup grant (500🪙) · token purchase · budgeted, tapered challenge emissions (daily-streak / one-time onboarding-funnel / burn-recycled performance ladder). SINKS: card purchases (buyer→seller) · A/S fee burn · (future mint/ascension costs). Governance note: challenges move open-faucet → budgeted+tapered (CLAUDE.md currency-model edit, referenced not owned here). Safe-by-construction: no cash-out, provenance-locked resale → free emission can't reach USD.]

---

## 7. Forward: battle pass & subscription (economy extension — analysis + future Phase M4, NOT this build)

> **Status: specced at the model level, not built.** Same treatment PLAN.md gives G-CARDVAL. M1–M3 ship without any of this. Read this before designing either feature so it lands inside the economy rather than on top of it.

### 7.1 Why it fits this platform
- **Lowest-compliance revenue on the platform.** Prediction markets and USD card sales drag KYC + age + jurisdiction + money-transmission behind them. A cosmetic-forward pass sells a digital good plus utility currency — ordinary e-commerce. Highest margin, lightest regulatory surface.
- **Monetizes the free tier.** Most users will never place a real-money bet. Whales bet; the mass market buys a season pass. It broadens the revenue base instead of deepening it on the regulated surface.
- **Gives the challenge system a destination.** Challenges currently emit tokens. A pass makes challenge completion *also* advance a seasonal track — the retention loop is far stronger than raw handouts. Challenges become the pass's XP source (§6).
- **Pass/sub token stipends are pre-paid token demand.** Real money converts to tokens up front; the A/S burn (§3) partially retires them. Healthy source/sink behavior, and provenance-lock (§4) means none of it can reach USD.

### 7.2 The safe design line (non-negotiable)
- **Rewards = cosmetics + token stipend + QoL. Never premium USD-tradeable chits.** "Pay $X → receive cards resellable for USD" is the G-CARDVAL / investment-contract landmine *plus* loot-box optics. Pass rewards stay on the cosmetic/token side of the currency wall (Hard Rule 33).
- **Deterministic tiers, never randomized drops.** A known-reward track is not a loot box; a randomized one is. Every pass tier states exactly what it grants.
- **Paid emission ≠ free emission.** Pass and subscription tokens sit in the **bought** bucket alongside direct purchases — categorically separate from the tapered signup/challenge faucet (§6). They do not draw against the free-emission budget.
- **No appreciation language, anywhere.** Fixed prices, no yield/return/revenue-share framing (CLAUDE.md governance; Hard Rule 30 for anything contractual).

### 7.3 Battle pass — shape
Seasonal (e.g. 8–10 weeks). **Free track** keeps non-payers progressing (retention subsidy); **premium track** is a one-time seasonal purchase (USD, or a token price). XP comes from the existing challenge classes (§6) — daily streak, milestones, performance — so no parallel progression system is built. Tiers grant, in rough order of value to the platform: cosmetic card frames / badges / leaderboard flair (zero marginal cost, retains well) → token stipends (pre-paid demand) → QoL unlocks. Season ends, track resets, cosmetics are permanent.

### 7.4 Subscription — shape, and two hooks worth taking
Standing membership (monthly). Two perks fall naturally out of what M1 already builds:

1. **Extra listing slots.** M1 enforces one active listing via `marketplace_listing_allowance(p_user)` — a *function*, default 1, deliberately not a hardcoded constant. A subscription tier raises that allowance by config. This is QoL, not pay-to-win: subscribers move inventory faster, they don't get stronger cards.
2. **Monthly token stipend.** Pre-paid token demand; safe by construction under provenance-lock.

**One honest tradeoff to decide, not to assume:** discounting the A/S fee for subscribers is tempting, but that fee is a **burn** — your main deflationary sink. Discounting it leaks sink pressure.
- *Option A (cleaner economy):* extra slots + stipend + cosmetics; burn stays intact.
- *Option B (richer perk):* fee discount, accepting reduced burn, offset by recurring USD subscription revenue.
Model both against the §6 emission budget before choosing. **A is the default.**

### 7.5 Sketched Phase M4 (gated — do not start without founder sign-off)
- [ ] Season + tier schema (deterministic rewards, cosmetic-first); XP sourced from existing challenge events, no parallel progression.
- [ ] Entitlement model (`pass_purchases` / `subscriptions`, append-only receipts, idempotent across Stripe **and** RevenueCat — mobile IAP rides `mobile_iap_confirm`).
- [ ] Subscription tiers drive `marketplace_listing_allowance()` + stipend grants via config.
- [ ] Cosmetic inventory (frames/badges) — **cosmetics are not chits**, never enter `moment_chits`, never listable on the marketplace.
- [ ] Emission budget re-modeled in §6 with pass/sub stipends in the *bought* bucket.

**DO NOT** grant USD-tradeable chits from a pass or subscription · randomize pass rewards · let cosmetics become marketplace-listable assets · let pass/sub stipends draw from the free-emission budget · describe any of it with investment/return/yield language · start M4 before M1–M3 ship and the emission model is re-run.

---

## Cross-repo contract (mirror into RECONCILIATION.md)

✅ Mirrored 2026-07-08 — see **RECONCILIATION.md §8** (the living copy; this spec does not duplicate it).
Summary: marketplace is **web-only** (Companion-App model, like minting); Unity consumes the public-read
listing/pricing read models and deep-links to web `/market` for any action; RPC names + `acquired_currency`
+ fee/burn + one-listing semantics documented there. Never wire IAP to marketplace purchases.

---

## Per-phase report template (use after each PR)
```
Phase Mx — <name>
- What changed: <migrations, functions, tables, docs>
- Checklist: <n/m items complete>
- flutter analyze / deno check: <clean / issues>
- Smoke test: <pass/fail + what was exercised>
- Gate hit: <none / USD live gate / founder sign-off>
- Ground-truth surprises: <spec-vs-repo mismatch>
```
