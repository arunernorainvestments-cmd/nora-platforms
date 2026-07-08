# NORA Platforms — Chit Marketplace Build Spec (Fixed-Price, Token-First)
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md, HANDOFF.md in full before touching any file.**
Compiled: 2026-07-08 · Adds the public **fixed-price marketplace** for minted moment chits (token lane live; USD lane shaped-but-stubbed behind the P5 switch).

> Scope discipline: this is the **bare fixed-price mechanics** — list a card, buy a card, delist. **No** supply/demand pricing, **no** card-balancing economy, **no** value accrual. Fixed prices from a config table; the platform takes a fee on A/S sales. Everything is built token-first and USD-ready so the live flip is a config change, not a rewrite.

---

## 0. How to use this document + ground-truth reconciliation

[To be written — verify-don't-assume checklist before building; migration ledger next = **153** (`supabase db push` only); the Hard Rules in play (27 moment_chits≠battle_chit_definitions · 29 append-only ledgers · 33 currency wall / integer cents-no-floats · 34 stats ladder-derived · 30 no fabricated legal language · G-CARDVAL parking — fixed price only, no appreciation/investment language). Inspect what already exists before writing: `chit-marketplace-{buy,list}` edge fns, `chit-barter` (mig 119), `chit_packs` (mig 120), `chit_ownership` + acquisition ledger (mig 117), one-active-self-minted + swap-delete (mig 142), `battle_payments_mode()` switch (mig 132–134). Decide extend-vs-rebuild per what's found.]

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

[To be written — table of what's LOCKED (one listing/user · unique-card · pricing scale · peg · A/S fee-as-burn A10/S15 · signup grant 500🪙 · route `/market`) vs what needs live/founder sign-off (USD lane flip, buyer/seller KYC on USD, challenge-emission governance edit to CLAUDE.md).]

---

## PHASE M1 — Listing + fixed-price token sale (LIVE)
**Effort:** L · **Depends:** shipped mint pipeline + `chit_ownership` (117) + `battle_payments_mode` (132) · **Migrations:** 153–155 · **PR:** `mkt-m1-token-listings`

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
- [ ] `marketplace_tier_pricing` seeded (7 tiers, USD cents + token price + A/S fee_bps) — mig 153.
- [ ] `marketplace_listings` + `marketplace_sales` (append-only) + escrow reuse + RLS (public-read active; server-only writes) — mig 154.
- [ ] `marketplace_listing_allowance()` (default 1) gating concurrent listings — mig 154.
- [ ] `marketplace_list_chit` / `marketplace_buy_chit` / `marketplace_delist_chit` — atomic, idempotent, attribution-preserving, A/S fee **burned** — mig 155.
- [ ] `acquired_currency='token'` stamped on every bought chit (provenance seam for M2).
- [ ] USD lane RAISEs (columns present, inert); apply-time smoke green; `deno check` clean; no Dart yet → `flutter analyze` unaffected.

**DO NOT** mutate `chit_ownership` acquisition-ledger rows or `marketplace_sales` (INSERT + status-sibling only, Rule 29) · let a chit be listed while wager-staked/playable/swap-pending, or stay ascendable while escrowed · credit the A/S fee anywhere (it is a **burn**, not platform income) · use floats for price or fee (integer tokens; integer cents when USD lands — Rule 33) · strip `original_minter_handle`/`card_serial` on transfer · let a bought card eat the buyer's self-mint slot · bypass `increment_token_balance`/receipt-ledger idempotency · allow any client-side write to a marketplace table · enable the USD path in M1.

---

## PHASE M2 — USD-ready seam (BUILT LIKE-LIVE, SIM BEHIND SWITCH)

[To be written — `currency` branch on listings/sales; fee-in-**integer cents**; Stripe Connect seller payout / `sim_usd_balances` sim path behind `battle_payments_mode`; **activate the provenance lock** (token-bought → token-resale-only); KYC-on-USD-seller gate stub. Deliverables + DO NOT.]

**Deliverables**
- [ ] [placeholder]

**DO NOT** [placeholder]

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

[To be written — what nora-arena (Unity) consumes: marketplace listing read model, buy/list/delist RPC names, `acquired_currency` field, fee/burn semantics, one-listing rule. Minting/marketplace stay web-only (Companion-App model); mobile deep-links to web.]

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
