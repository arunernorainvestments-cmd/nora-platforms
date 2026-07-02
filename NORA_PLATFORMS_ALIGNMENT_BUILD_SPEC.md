# NORA Platforms — Alignment Build Spec (Workflow-Doc Realignment)
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md in full before touching any file.**
Compiled: June 2026 · Aligns the backend to the **Workflow Notes** (the product source of truth) + the locked architecture decisions below.

---

## 0. How to use this document

This spec realigns the **already-built** redesign to a refined product model. It is mostly **consolidation and repurposing, not greenfield** — most primitives exist; the work is to make the *license* the spine, turn the **real-money rail** on, and retire what the model dropped.

**Before any phase:**
1. `ls supabase/migrations/` and reconcile to ARCHIVE.md §B1 — confirm what is actually applied. Remote DB is at **115** per PLAN.md.
2. Migrations apply **only** via `supabase db push` (Hard Rule: never hand-run DDL through the Management API — it skips `schema_migrations`).
3. `flutter analyze` zero issues before and after every phase.
4. All money math in **integer USD cents**. Append-only ledgers stay INSERT-only. Idempotent credits (`ON CONFLICT DO NOTHING` + receipt ledger).
5. Each phase below has a **Deliverables checklist** and a **DO NOT** block. Treat each phase as one atomic unit of work; do not start the next until its checklist is green.

**Status tags:** [BUILT] exists · [REPURPOSE] adapt existing plumbing · [NEW] build · [CUT] deprecate (archive, don't drop) · [DORMANT] keep schema, disable for launch.

---

## 1. The locked model (canonical — encode this everywhere)

**Two currencies, one compliance line.** This separation is the whole point — it keeps the unregulated and regulated surfaces cleanly apart.

| | **Tokens** (virtual, no cash-out) | **Real money** (USD via Stripe) |
|---|---|---|
| Earned/bought | challenges + token purchase | n/a |
| Spent on | **Markets bets (token-only)**, **buying/trading Battle Chits** | **license purchase/resale**, **Battle prediction-market bets**, **Emergency Fund** |
| Gating | none | **KYC + age + jurisdiction** |
| Settlement | `token_balances` / `token_transactions` | Stripe Connect/Treasury (live) · `sim_usd_balances` (sim) |

**Ownership = the license.** Likeness **cards are retired**; the license (`lkn_agreements`) is the single ownership + battle-eligibility + tradeable asset. The append-only ledger + marketplace plumbing built for cards is **repurposed** to serve licenses.

**Characters carry authored D&D stats**, attached to the **character** (fixed regardless of who holds the license), decoupled from social metrics for MVP. **Archetype = mechanical baseline; `character_id` = override layer.**

**Compliance is "build/refine," not "design."** Legal review is considered complete; the scaffolding you already shipped — `identity_hash` sybil anchor, one-role-per-match integrity (Hard Rules 26–28), the KYC flow, age/jurisdiction columns, integer-cents math, idempotent credits — gets **switched on and wired to real Stripe**. That wiring is most of what "going live" is here.

**Keep / Cut / Dormant for launch:**
- **KEEP:** Markets (now **token-only**, no real-money component), Hot Topic, Emergency Fund (rides the real-money rail; cleanest fast-follow candidate if timeline bites, but baseline = launch).
- **CUT (archive, don't drop):** likeness cards, legacy Arena 1v1 (`arena_back`/`arena_trigger`/`arena_abilities`) — but **salvage the arena tick/Realtime engine for the Vibe Meter** (Phase 4).
- **DORMANT:** weekly polls + stat multipliers (keep schema, disable for launch), social-derived `creator_stat_sheets` in battle (keep table, remove from damage path).

---

## PHASE 0 — Canonical model + governance alignment

**Goal:** make the four canonical docs tell this one story so every later prompt inherits it.

**Deliverables**
- [ ] CLAUDE.md: rewrite the **Systems** block to the model in §1 (two currencies; license-as-asset; cards CUT; Markets token-only; polls/legacy-Arena/social-stats status). Add the **two-currency compliance line** as a first-class rule.
- [ ] CLAUDE.md Hard Rules: add **"Battle prediction markets settle in real money (USD), never tokens; Markets settle in tokens, never real money."** Keep Rules 26–32; do not renumber existing rules without recovering the full current list first.
- [ ] CLAUDE.md: add **"Battle archetype is an explicit authored property, never inferred from `category_1` or `listing_category`."**
- [ ] PLAN.md: move the now-decided items (R1/R2/R3, real-money settlement, license-as-asset) from "future" into the phased plan below; move cards/polls/legacy-Arena into a "Deprecated for launch" section.
- [ ] RECONCILIATION.md: mark R1/R2/R3/R4 **decided** (don't delete — strike with the resolution date) per the resolutions in this spec; update the consumed-contract table for the license-eligibility and real-money-settlement changes.
- [ ] ARCHIVE.md: add a dated entry noting cards/legacy-Arena/polls are deprecated and where their schemas now sit.

**DO NOT**
- Do not delete any deprecated table or migration in this phase — Phase 0 is documentation alignment only.
- Do not weaken Hard Rules 26–28 (one-role-per-match / `identity_hash`) — they become **load-bearing** at live launch.

---

## PHASE 1 — License as the single asset (retire cards, build the license market)

**Goal:** consolidate ownership onto the license; build the secondary license market + license↔chit barter; retire the parallel card system.

**Repurpose, don't rebuild:** `lkn_agreements` (the license) [BUILT], `lkn-purchase-license` (primary sale) [BUILT], the append-only transfer/marketplace pattern from `card_marketplace_*` / `likeness_card_transfers` [REPURPOSE]. License *contracts/templates/registry* are built (mig 108–113).

**What changes**
- [NEW] **One-license-per-person constraint:** a buyer may hold **one active license per character (listing)**. Enforce at primary mint (`lkn-purchase-license`) and on secondary purchase. A buyer may hold licenses for many different characters — just not two of the same.
- [NEW] **Secondary license marketplace (real money):** `lkn_agreements` is append-only (Hard Rule 29), so add a **listing/sale layer** (`lkn_license_listings` + `lkn_license_sales`, mirroring the card marketplace pattern) that transfers a license between users for USD, writes a transfer event to the append-only agreement-events log, charges the secondary-sale fee, and pays the seller via Stripe. Status-only changes on `lkn_agreements` per Rule 29; never mutate `terms_snapshot`.
- [NEW] **License↔Chit barter:** a swap path (`lkn-barter-license`) that trades a license for Battle Chits (or chit-for-license) with no money leg — license transfer event + chit inventory move in one atomic RPC. (Document 5: "trade of licenses between users **or for Battle Chits**.")
- [REPURPOSE] **Passive-holder match rewards on licenses:** the match-reward "passive owners" slice (Phase 3) now keys to **license holders** of the characters in a match, not card holders. Preserve the fractional-share idea: each holder's share derives from the license offering's `total_pct_offered ÷ supply`.
- [CUT] **Likeness cards:** archive `likeness_offerings`, `likeness_cards`, `likeness_card_transfers`, `card_marketplace_listings`, `card_marketplace_sales` (rename `*_archived`, set inactive; do **not** drop — they hold the pattern and any dev data). Remove their routes/screens or replace with a redirect. Remove `match_passive_reward` keyed to cards (re-add keyed to licenses in Phase 3).

**Deliverables**
- [ ] One-active-license-per-character enforced at primary + secondary, with a clear client error.
- [ ] `lkn_license_listings` + `lkn_license_sales` (+ RLS: public read active listings, seller cancels own, writes via SECURITY DEFINER RPC only).
- [ ] `lkn-list-license` / `lkn-buy-listed-license` edge fns (real money; Stripe in live, `sim_usd_balances` in sim); secondary-sale fee applied; seller paid.
- [ ] `lkn-barter-license` RPC (license↔chit, atomic, no money leg).
- [ ] Card tables archived; card routes/screens removed or redirected; `flutter analyze` clean.
- [ ] RECONCILIATION updated: ownership is licenses; cards retired.

**DO NOT**
- Do not UPDATE `lkn_agreements` rows except status fields (Rule 29). Resale/barter = new transfer + status change, never a row mutation.
- Do not use "card" in any user-facing copy or new code. Do not use "investment/return/yield/dividend/revenue share" anywhere license-facing (collectible-game-asset framing only).
- Do not drop the card tables — archive only.

---

## PHASE 2 — Character & stat model (archetype baseline + character override)

**Goal:** make `battle_archetype` an explicit authored property; attach authored D&D stats and per-character move-sets; seed the 10 launch characters; make a **license** (not a card) the battle-eligibility key.

**This phase closes RECONCILIATION R1, R2, R4.**

**The governing principle**
> **Archetype = mechanical baseline. `character_id` = override layer.** At launch the override carries **presentation** (move name, VFX accent — color/particle, battle-media clip, animation). Mechanical effects (HP/AP) stay equal to the archetype kit. **Per-character mechanical deltas (stats, effect tweaks) are reserved for the future** — the schema must support them now even though launch authors them directly. Effective value = archetype baseline overlaid with any character override.

**Battle archetype (sever from `category_1`)**
- [NEW] Add an explicit `battle_archetype` (CHECK = the canonical 10) to the character/license record. Battle reads **only** this. `profiles.category_1` and `lkn_listings.category` stay as **discovery/marketplace flavor**, fully severed from battle.
- [NEW] **Expose `battle_archetype` in `lkn_public_registry`** so the Arena client reads a real column instead of inferring from `listing_category` (R4).
- [BUILT→FIX] Fix `get_eligible_characters` self-branch to emit the authored `battle_archetype`, not `LOWER(category_1)` (R1). The `likeness_offerings.archetype` CHECK instinct was right — relocate that constraint onto the license/character record.

**Stats (authored, character-attached, D&D)**
- [NEW] **Six combat stats: STR, DEX, CON, INT, WIS, CHA**, stored as an **archetype baseline block + optional per-character override/delta** (so a future Olivia is `musician baseline + delta`). At launch the 10 characters are authored directly.
  - STR → physical (HP) damage · DEX → defense/AC + initiative + dodge + accuracy · CON → max HP · INT → max AP · WIS → defense vs psychic abilities · CHA → AP cost (higher = cheaper) + effectiveness of own psychic abilities.
  - Physical attacks deal **HP** damage; psychic attacks deal **AP** damage. Healing restores HP; encouragement restores AP.
- [DORMANT] Remove social-derived `creator_stat_sheets` from the battle damage path. Keep the table + `calculate_stat_sheets()` dormant (future week-to-week rebalancing only). The Doc-2 `power_mod/wit_mod/resilience_reduction` damage mods are **removed** for MVP.

**Move-sets (archetype kit + character override)**
- [BUILT→EXTEND] `battle_abilities` gains optional `character_id`. **Effective moveset = bespoke character moves if present, else the archetype default kit.** Override fields carried per character: `display_name`, `vfx_style` (color/particle), `animation_key`, and a link target for `battle-media` (Phase 5). Mechanical fields (HP/AP effect, category, AP cost, Vibe/threshold gating) come from the **archetype baseline** at launch.
- Type chart stays **keyed by archetype** (`battle_type_chart`) — unchanged. Initiative unchanged (now driven by DEX, see Arena spec).

**Seed the 10 launch characters (celebrity-integration pattern)**
- [REPURPOSE] Use the `celebrity-integration-seed` pattern (platform-managed `profiles`, no login, `managed_by_platform=TRUE`, managed wallet) to seed 10 characters, each with: assigned `battle_archetype`, authored D&D stat block, and a bespoke move-set (names/VFX/animation overrides over the archetype kit). One per archetype, so the type chart has a live representative for every matchup:

| Character (platform-managed seed) | `battle_archetype` |
|---|---|
| Trump | politician |
| Sabrina Carpenter | musician |
| Ronaldo | athlete |
| Kanye | artist |
| Palmer Luckey / Anduril | business |
| Ninja | gamer |
| Alix Earle | influencer |
| Neil deGrasse Tyson | scientist |
| Arnold Schwarzenegger | actor |
| Theo Von | comedian |

Move-set names per character come from the Workflow Notes (e.g., Trump "You're Fired," Sabrina "Juno," Arnold "I'll Be Back"). Author them as character overrides over each archetype's default kit.

**License → battle eligibility (R2)**
- [BUILT→CHANGE] `check_battle_eligibility` and `battle_enqueue`/matchmaking now gate on an **active `entertainment_game` license** (`lkn_agreements`), not a card. A user fields a character iff they hold an active game-use license for it (or are the platform-managed seed itself for dev). Re-verify at battle entry (the client also re-verifies via `lkn-verify` + signature — keep that contract stable).

**Deliverables**
- [ ] `battle_archetype` authored column + CHECK; battle reads only it; `category_1`/`listing_category` severed from battle.
- [ ] `battle_archetype` exposed in `lkn_public_registry`; `get_eligible_characters` self-branch fixed; Arena client alias map can be deleted (notify via RECONCILIATION).
- [ ] D&D stat storage (archetype baseline + per-character override); 10 characters' stats authored; social-stat damage mods removed from `process_battle_turn`.
- [ ] `battle_abilities.character_id` + override fields; effective-moveset resolution (bespoke-else-default).
- [ ] 10 platform-managed launch characters seeded with archetype + stats + move-sets.
- [ ] `check_battle_eligibility` / `battle_enqueue` gate on active license; battle-entry re-verify intact.

**DO NOT**
- Do not infer `battle_archetype` from `category_1`/`listing_category` anywhere.
- Do not put social-derived stats back into the damage formula for MVP.
- Do not bake character mechanical deltas at launch — launch overrides are presentation-only; keep the delta capability in schema for later.

---

## PHASE 3 — Real-money rail + match economy

**Goal:** turn on the regulated surface and move Battle settlement to real money; keep Markets token-only.

**Real-money rail (flip the compliance switches)**
- [BUILT→WIRE] Stripe Connect (instant licensor payout on license sale) + Stripe Treasury (Fund) wired for **live**; `LKN_PAYMENTS` and the Fund mode flip from `sim` to `live` behind config. Keep sim path working for dev.
- [BUILT→ON] Flip `platform_integrity_settings`: `require_kyc_for_staking=TRUE`, `require_kyc_for_combatant=TRUE` at live; `enforce_one_role_per_match` stays TRUE always. `identity_hash` populated by the Stripe Identity webhook (live). Wire `date_of_birth` → 18+/21+ gate and `verified_address_country` → jurisdiction geo-restriction at the betting + licensing entry points.
- Idempotent credits across web Stripe **and** mobile RevenueCat into the same ledgers (receipt ledger + `ON CONFLICT DO NOTHING`).

**Battle settlement → REAL MONEY (the biggest plumbing change)**
- [BUILT→CHANGE] `distribute_match_revenue()` credits **USD** (Stripe payout / `sim_usd_balances`), **not** `token_balances`. Bets on `battle_outcome` markets are placed in **real money**; the pool settles in real money.
- [NEW] **Winner > loser player split, both paid:** the player slice splits across winning **and** losing fielders, winner-weighted. Default config (tunable in `match_revenue_config` — **flagged for product to set exact numbers**):
  - **80%** correct predictors (proportional) · **8%** players (winner-weighted, e.g. 6% winner / 2% loser) · **2%** original creator(s) of characters in match · **5%** passive **license** holders (proportional to license `pct`) · **5%** platform.
- [REPURPOSE] Passive slice keys to **license** holders (Phase 1), not cards.

**Canonical spectator-bet path (resolve R3 — forced by the real-money decision)**
- The real-money pool settles through `distribute_match_revenue` on **`markets` + `bets` with `resolution_type='battle_outcome'`** (mig 100). **That path is canonical.** The legacy `battle_place_spectator_bet` → `battle_spectator_bets`/`spectator_pool` (mig 062) path is **deprecated for both clients.**
- [NEW] Mobile must migrate to the canonical `bets`/`battle_outcome` path. **Do not delete** the legacy 062 table/RPC until the Arena client has migrated (mobile currently depends on it). Track the deletion as a post-migration cleanup.

**Markets stays token-only**
- [BUILT] Markets bets/pools remain in **tokens** (`token_balances`), no real-money component. Do not route Markets through the USD rail.

**Deliverables**
- [ ] `distribute_match_revenue` credits USD; battle bets are real-money; config-driven winner>loser split; passive slice = license holders.
- [ ] Stripe Connect payout on license sale (live) + sim fallback; idempotent across Stripe + RevenueCat.
- [ ] KYC/age/jurisdiction gates enforced at betting + licensing entry; integrity settings flipped for live; `identity_hash` populated in live.
- [ ] Canonical bet path = `bets`/`battle_outcome`; mobile migration tracked; legacy 062 path marked deprecated but NOT dropped.
- [ ] Markets confirmed still token-only.

**DO NOT**
- Do not settle Battle markets in tokens or Markets in real money — the two-currency line is the compliance boundary.
- Do not drop the legacy `battle_spectator_bets`/`battle_place_spectator_bet` until mobile is off it.
- Do not bypass `increment_token_balance` for token writes or the receipt-ledger for credits (idempotency).

---

## PHASE 4 — Vibe Meter backend + Battle integration (salvage the legacy Arena engine)

**Goal:** make a per-match **Vibe Meter** that rises with **real prediction-market activity**, broadcast live; retire the legacy Arena influence actions.

**Salvage (the one genuinely reusable piece of legacy Arena)**
- [REPURPOSE] Keep the legacy **tick-aggregation + Realtime-broadcast engine** (`process_arena_tick` reading pooled activity and pushing live updates). Repurpose it to compute a per-match `vibe` value from spectator betting volume/velocity on the linked `battle_outcome` market and broadcast it over Realtime.
- [CUT] Remove `arena_back` / `arena_trigger` token actions and the `arena_abilities` catalog entirely (archive). Influence-on-the-match now comes from Battle Chits (players) and the Vibe Meter (crowd) — not the legacy Back/Trigger loop.

**What changes**
- [NEW] `vibe` state on the match (per-match meter 0–100 with thresholds). Server-authoritative: the tick engine updates it from real bet activity; the client renders it.
- [NEW] Move-gating in `process_battle_turn`: moves flagged Vibe-gated (and/or AP+Vibe-threshold) become available **at the start of the next round** after the threshold is crossed (not mid-round) — enforce server-side.

**Deliverables**
- [ ] `vibe` per-match state + thresholds; tick engine computes it from real `battle_outcome` bet activity; broadcast over Realtime.
- [ ] Vibe-gated / AP+Vibe move availability enforced server-side, applied at next-round boundary.
- [ ] Legacy `arena_back`/`arena_trigger`/`arena_abilities` archived; routes/screens removed; `flutter analyze` clean.

**DO NOT**
- Do not compute Vibe on the client — it's server-authoritative (clients render it). The client never decides move availability.
- Do not retain the legacy Back/Trigger token-influence loop; the only salvage is the tick/Realtime mechanism.

---

## PHASE 5 — Move-media backend (clip pipeline infrastructure)

**Goal:** build the infrastructure so move-intro clips (e.g., Arnold "You're Fired") can be uploaded and tied to moves; populate later.

- [NEW] Private Supabase Storage bucket **`battle-media`** (no public client policies; CDN-fronted for delivery).
- [NEW] Metadata table keying **(ability/move row) → asset path** (so a clip attaches to a specific move on a specific character; generic archetype moves need none). Include codec/size/duration fields for the mobile budget.
- [NEW] Admin upload path (service-role edge fn) to register a clip against a move and store it. Delivery is Addressables/CDN-friendly (the Arena client preloads at match-load — see the Arena spec).

**Deliverables**
- [ ] `battle-media` private bucket created.
- [ ] move→asset metadata table (+ RLS: read of asset *paths* gated; no public signed URLs leaked — mirror the `ubi-documents` discipline).
- [ ] Admin clip-upload edge fn; clips resolvable by the Arena client via Addressables/CDN.
- [ ] Pipeline verified with one test clip end-to-end; bulk population deferred.

**DO NOT**
- Do not embed clips in any app build or block battle on clip availability — clips are optional per-move enhancements.
- Do not expose raw storage paths/signed URLs to clients beyond what the Addressables delivery path requires.

---

## PHASE 6 — Chit combination + deprecation cleanup + launch hygiene

**Goal:** the fast-follow chit-combination mechanic, execute deprecations, and run pre-launch hygiene.

- [NEW] **Chit combination** (fast-follow, not launch-blocking): extend the chit framework so two chits combine for a unique effect/animation. Launch ships **single-use** chits (built); combination is specced here and gated so it can land just after launch. Respect the integrity invariant (combatants use chits, can't bet).
- [CUT/EXECUTE] Finalize deprecations from Phases 1/4: cards archived, legacy Arena removed, **weekly polls + stat multipliers set DORMANT** (schema kept, cron `create-weekly-poll`/`close-weekly-poll` unscheduled, `process_poll_results` disabled, multipliers forced to 1.000), social-stat damage path removed.
- [BUILT→ON] Emergency Fund live-mode wiring (same KYC/Treasury rail); keep sim for dev. (If timeline bites, this is the cleanest item to hold at sim/post-launch — flag, don't assume.)
- [EXECUTE] Pre-launch reset sequence (ARCHIVE §A8) + remove all dev tooling (`dev-bot-backer`, `dev-test-match-maintainer`, `dev_*` RPCs). Slice 2 test-account filter sweep (Hard Rule 15/22). Seed `celebs.image_url` (currently NULL).

**Deliverables**
- [ ] Chit-combination mechanic specced + gated for fast-follow; single-use confirmed for launch.
- [ ] Polls dormant (cron unscheduled, multipliers neutralized); legacy Arena + cards archived; social-stat path removed.
- [ ] Emergency Fund live wiring (or explicit sim/post-launch decision recorded).
- [ ] Dev tooling removed; reset sequence run; test-account sweep done; celeb images seeded.
- [ ] `flutter analyze` clean; real-money + token smoke tests pass.

**DO NOT**
- Do not drop dormant schemas (polls, social stats, cards) — they're future capability.
- Do not ship dev tooling or `ALLOW_DEV_TOOLS` paths to production.

---

## Cross-repo contract (what Phases here hand to nora-arena — mirror into RECONCILIATION)

| Change | Arena must adopt |
|---|---|
| `battle_archetype` exposed on `lkn_public_registry` | read the real column; **delete the client-side archetype alias map** |
| Eligibility gates on **license**, not card | character-select unlocks from active `entertainment_game` license |
| Battle bets settle in **real money** via `bets`/`battle_outcome` | migrate off legacy `battle_place_spectator_bet`; bet UI hits the canonical real-money path |
| **Vibe Meter** is server-authoritative (`vibe` state over Realtime) | render it; never compute it; move availability comes from the server |
| **D&D stats** (archetype baseline + character override) | wire STR/DEX/CON/INT/WIS/CHA → HP/AP/damage/dodge/initiative/AP-cost |
| 10-state animation contract (`animation_key`) | expand from 6 to 10 states |
| `battle-media` move→clip metadata | Addressables preload at match-load |

**Open numbers flagged for product:** the `match_revenue_config` split (default 80/8/2/5/5, winner-weighted 6/2 within the player slice) — confirm exact percentages before live.
