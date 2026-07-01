# NORA Platforms v3 — Phased Implementation Plan
**Source specs:** `NORA_PLATFORMS_BUILD_SPEC_v3.md` (the "Moments" card-battler) + `PROMPT_nora_platforms_v3.md`
**Last updated:** 2026-07-01 · **Target launch:** July 4 2026 (Phase 5/7 may slip to immediate post-launch)

> This is the execution/tracking companion to the v3 spec. The spec is canonical for *what*; this doc is
> the *how/when/in-what-order*, grounded against the actual repo (migration ledger, existing functions/tables).
> Work P0→P7 in order. Each phase = one atomic PR carrying the spec's checklist as its description.

---

## Ground-truth reconciliation (verified against repo 2026-07-01)

Before building, note where the spec's "[NEW]" labels collide with what already exists — **verify, don't assume**:

| Spec says | Repo reality | Implication |
|---|---|---|
| `battle_chits` catalog [NEW] | `battle_chit_definitions` + `user_battle_chits` already exist (mig **086/103/106**) — rarity-based (`common…mythic`) **single-use powerups**, the legacy "Battle Chit" powerup system (Hard Rule 27). | **Naming collision — RESOLVED in P0 (2026-07-01):** the v3 catalog is named **`moment_chits`** (tiered ATK+HP card creatures, the whole asset layer); the legacy powerup tables stay `battle_chit_definitions`/`user_battle_chits` (dormant). Do **not** overload the legacy tables. Hard Rule 27 reconciled; CLAUDE.md §"The game (v3)" is canonical. |
| `battle_characters` [CUT] | No such table. 1v1 "character home" is `battle_matches` / `battle_participants`; move-sets live in **`battle_abilities`** (mig 060). | Retirement targets are `battle_abilities` (per-archetype move-sets) + the character/eligibility model — not a table literally named `battle_characters`. |
| `process_battle_turn` [REBUILD] | Exists across mig **063/067/069/091/103/106**. Current resolver = 1v1 turn-based duel. | P3 is a **rebuild in place** (new migration supersedes; keep old rows/tables archived, don't DROP). |
| `match_revenue_config` [NEW keys] | Exists (mig **088/091**), token-only. | P5 rewrites the split keys + adds `currency`. |
| `battle_events` [NEW stream] | Exists (mig 060/066/067/091/103/106). | P3 extends the event vocabulary (summon/fusion/etc.), not a greenfield table. |
| `handle_bet_pool_update` [branch] | Exists (mig 100/004). | P5 adds token-vs-USD branching. |

**Migration ledger:** currently **066→115**. Next new migration = **116**. Apply **only** via `supabase db push` (never hand-run DDL — Hard Rule / governance). `flutter analyze` = zero issues before *and* after every phase.

---

## Dependency graph (why the order is fixed)

```
P0 (docs/governance)
      │
      ▼
P1 (chit catalog + ownership + decks + barter) ──┐
      │                                           │
      ▼                                           │
P2 (tier ladder + effects + fusion DATA) ─────────┤  P2 is the balance core;
      │                                           │  P3 & P6 both read it
      ├──────────────┬──────────────┐             │
      ▼              ▼              ▼             │
P3 (CCG engine)   P4 (Vibe)     P6 (mint+ascend) ─┘
      │              │              │
      └──────┬───────┘              │
             ▼                      │
      P5 (real-money rail) ◄────────┘  (payout routes to moment-owners from P6 mint)
             │
             ▼
      P7 (fusion expansion + deprecation cleanup + Fund + launch hygiene)
```

- **P2 is the critical path** — it's "the heart of the game." `process_battle_turn` (P3) and minting/ascension (P6) both derive stats from the tier ladder. Do not start P3 until the derivation function (P2) is solid.
- **P4 (Vibe)** can proceed in parallel with P3 once P2 lands; P3 only needs the Vibe *threshold read* contract.
- **P5** depends on P6's mint (payouts route to moment-owners) and on P3 (settlement on match resolution). Its two **hard live-flip prereqs** are independent and can be cleared any time.
- **P7** is cleanup/expansion; only fusion *content* depends on P2/P3, the rest is deprecation execution.

---

## Cross-cutting guardrails (apply to every phase)

- **Tier cost-banding is the core balance rule** — higher tier = stronger **AND** costlier Aura. Never strictly-better-for-cost. This is what stops virality = auto-win.
- **Users never set tier/cost/stats** — always derived from the ladder + classification.
- **Ascension**: one-directional (never de-rank), definition-level (all copies together), ≤1/7 days per user, between-matches only (matches snapshot at start).
- **Fusion is tag-based** (family/keyword/element patterns), never per-card recipes.
- **Combat server-authoritative** — emit ordered `battle_events`; client computes nothing.
- **Money**: integer USD cents, no floats. Append-only ledgers stay INSERT-only. Idempotent credits.
- **New Hard Rules 33–36** (added P0) are load-bearing for every later phase.

---

## PHASE 0 — Canonical model + governance (docs only)
**Effort:** S · **Blocks:** everything · **PR:** `v3-p0-docs`

| # | Task | Done |
|---|---|---|
| 0.1 | CLAUDE.md: rewrite Systems block → §1 (chits, Aura, Vibe, tiers, fusion, minting, ascension, consent-vs-licensed split). Mark 1v1 fighter / D&D-stat / archetype-moveset / license-per-character eligibility **deprecated**. | ☐ |
| 0.2 | CLAUDE.md Hard Rules 33–36 (append, never renumber): 33 markets settle real-money USD, Markets in tokens, never cross · 34 archetype/damage from tier ladder, never user-set · 35 real-money markets only when both players KYC'd (G-MON) · 36 ascension one-directional, between-matches, matches snapshot at start. | ☐ |
| 0.3 | Reconcile **Hard Rule 27** language: legacy powerup "Battle Chits" (`battle_chit_definitions`) vs v3 "moment chit" asset. Pick distinct naming; note both in CLAUDE.md. | ☐ |
| 0.4 | PLAN.md: replace v2.x phase plan with P0–P7; move deprecated systems to a "Retired" section. | ☐ |
| 0.5 | RECONCILIATION.md: mirror the Cross-repo contract table (chit catalog+tier, CCG event stream, market gating, minting/ascension, fusion). Note Arena uses local Unity Editor via `unity-mcp` (no WebGL/headless CI). | ☐ |
| 0.6 | ARCHIVE.md: dated entry noting the pivot + where retired 1v1/stat schemas sit. | ☐ |

**DO NOT:** delete retired tables (docs only). Don't weaken KYC / one-role-per-match integrity.
**Exit:** four canonical docs describe the card-battler; Hard Rules 33–36 in place.

---

## PHASE 1 — Chit catalog + collection + deck + ownership/barter  ✅ built (migrations 116–121; not yet pushed)
**Effort:** L · **Depends:** P0 · **Migrations:** 116–121 · **PR:** `v3-p1-chit-asset-layer`

| # | Task | Done |
|---|---|---|
| 1.1 | **`moment_chits`** catalog (name locked P0; distinct from legacy `battle_chit_definitions`): `id, moment_id, character_class(consent_minted\|licensed), chit_type(creature\|spell_moment), archetype_family, tier(F–S), aura_cost, atk, hp, timing_type, keywords[], effect_ref, vibe_gate NULLable, card_art_url, moment_video_ref`. Tier/cost/atk/hp/effect **derived** (from P2), not free-set — enforce via constraint/trigger. → **mig 116** (+ minimal `moments` anchor; RLS public-read, no client writes; stat-shape + keyword-subset CHECKs). | ✅ |
| 1.2 | **`chit_ownership`** (user↔chit, quantity) + **append-only acquisition ledger** + derived holdings view. Copies fungible. RLS. → **mig 117** (`chit_acquisition_ledger` append-only + guard trigger; `chit_ownership` trigger-maintained holdings; `chit_grant` helper). | ✅ |
| 1.3 | **`decks`/`deck_chits`**: size 20, max 2 copies/chit; validate server-side on save **and** at match entry. → **mig 118** (`deck_validate` + `deck_set_chits`; match-entry re-check via `deck_is_legal` in mig 121). | ✅ |
| 1.4 | **`chit-barter`** RPC: chit↔chit / chit↔token = **no KYC**; any swap touching a **licensed** chit requires **KYC both parties** (verify/cancel popup). Atomic; logs transfer event. → **mig 119** (offer/accept/cancel handshake; `is_kyc_verified` gate on licensed crossover; `chit_barter_events` log). | ✅ |
| 1.5 | **Premium chit packs** on existing `lkn_*` plumbing (a licensed pack = set of `licensed`-class chits sold real-money). → **mig 120** (`chit_packs`→`lkn_listings`, licensed-only contents guard, idempotent `chit_pack_grant`; real-money purchase wiring deferred to P5). | ✅ |
| 1.6 | Archive `battle_abilities` per-archetype move-set tables + remove license-per-character eligibility (eligibility = "own chits + legal deck"). **Archive, don't DROP.** → **mig 121: deprecation MARKERS + new deck eligibility only.** ⚠️ **Physical archival (rename `battle_abilities`, drop `check_battle_eligibility`/`get_eligible_characters`) DEFERRED to P7** — the legacy `process_battle_turn` is live until P3 and nora-arena still consumes those fns (RECONCILIATION §1); removing now breaks live code. New path `deck_is_legal(deck, user)` shipped. | ◑ markers done; physical archival → P7 |

**DO NOT:** allow user-set tier/cost/stats · let licensed-pack barter skip KYC · drop archived 1v1 tables.
**Exit:** chits exist, owned, deckable, tradeable; premium packs ride licensing rail.
**Push status:** migrations 116–121 **APPLIED to prod** (`cceisywxwhgljdpisjrl`) 2026-07-01 via `supabase db push`; remote ledger `local==remote` through 121, no drift. Clean apply validates all DDL end-to-end. No Dart changed → `flutter analyze` unaffected. Functional RPC smoke test (barter/deck/pack flows) deferred until P2 seeds real chits via the derivation fn.

---

## PHASE 2 — Tier ladder + anatomy + effects/keywords/families + fusion DATA ⭐ CRITICAL PATH
**Effort:** L · **Depends:** P1 · **Migrations:** ~119–121 · **PR:** `v3-p2-balance-core`

| # | Task | Done |
|---|---|---|
| 2.1 | **`tier_ladder`** — per tier F–S: `aura_cost_range, atk_range, hp_range, effect_power`. **Cost-banded** (higher tier stronger AND costlier). | ☐ |
| 2.2 | **`engagement_tier_thresholds`** — engagement→tier map (F `<1k` … S `>5M`, per-platform normalized). Read by mint + ascension (P6). | ☐ |
| 2.3 | **`effect_templates`** — finite library keyed by (archetype family × timing type), parameterized by tier `effect_power`. Chit references template; magnitude = template scaled to tier. | ☐ |
| 2.4 | Enumerate **timing types** (`on_summon, activated, triggered, counter`), **keywords** (`taunt, charge, shield, stealth`), **archetype families** (athlete/musician/artist/scientist/comedian/influencer/politician/business/gamer/actor). | ☐ |
| 2.5 | **`fusion_rules`** — tag-based **patterns** `{archetype_family, keyword, element/tag, count}` → fusion effect template scaled by component tiers. Ship a **launch starter set**. | ☐ |
| 2.6 | **Derivation function**: `(family, timing, tier) → concrete (cost, atk, hp, effect magnitude)`. This is what 1.1, P3, and P6 all call. | ☐ |

**DO NOT:** author fusion as per-card recipes · break cost-banding (no strictly-better-for-cost high tiers) · scale stats without scaling cost.
**Exit:** balance data + derivation fn exist; a chit's numbers are fully ladder-derived.

---

## PHASE 3 — CCG combat engine (`process_battle_turn` rebuilt) — LARGEST BUILD
**Effort:** XL · **Depends:** P2 · **Migrations:** ~122–124 · **PR:** `v3-p3-ccg-engine`

| # | Task | Done |
|---|---|---|
| 3.1 | **Board-state engine**: per-match state (both Life, Aura/max-Aura, hand, deck, field ≤3, Vibe). Rebuild in place; supersede old resolver, archive old artifacts. | ☐ |
| 3.2 | **Start of turn**: max Aura +1 (cap 10), refill, draw 1, fire `start_of_turn` triggers, read Vibe. | ☐ |
| 3.3 | **Main**: validate/resolve summon (3-cap, summoning sickness unless `charge`), cast spell-moment, pay `activated`; each spends Aura; Vibe-gated require current threshold. | ☐ |
| 3.4 | **Combat**: face=Life dmg; creature-vs-creature mutual ATK→HP; `taunt` forces targeting; eliminate at 0 HP. | ☐ |
| 3.5 | **End**: fire `end_of_turn` triggers; hold `counter` for opponent. | ☐ |
| 3.6 | **Fusion detection/resolution**: within a turn's "Advance window," match played chits to `fusion_rule` patterns; resolve combined effect (Aura-costed by components); emit fusion event. | ☐ |
| 3.7 | **Match-start snapshot**: freeze each deck chit's tier/stats so mid-match ascension can't alter an active match (Hard Rule 36). | ☐ |
| 3.8 | **`battle_events` stream**: ordered events (draw/summon w/ `moment_video_ref`/attack/effect/fusion/KO + Life/Aura/Vibe deltas), keyed `(turn_number, sequence_in_turn)` with `*_after` reconciliation fields. | ☐ |

**DO NOT:** compute any outcome client-side · let ascension affect in-progress match · exceed field cap or skip sickness/taunt validation server-side.
**Exit:** full server-authoritative CCG turn resolves and emits a complete event stream.

---

## PHASE 4 — Vibe Meter backend (parallelizable with P3)
**Effort:** M · **Depends:** P2 (threshold contract) · **Migrations:** ~125 · **PR:** `v3-p4-vibe`

| # | Task | Done |
|---|---|---|
| 4.1 | **`process_battle_vibe_tick`** — copy only the COMMIT-per-tick + Realtime-broadcast pattern from the retired arena tick; **zero legacy-table dependency**. | ☐ |
| 4.2 | **`match_vibe`** state (0–100 + thresholds). | ☐ |
| 4.3 | Vibe = f(market activity + spectator presence + token reactions) with **passive floor / slow rise** (works in thin/non-monetized matches). Server-authoritative. | ☐ |
| 4.4 | Engine (P3) reads thresholds for Vibe-gated chits; availability applies at **next-round boundary** after a crossing. | ☐ |

**DO NOT:** compute Vibe client-side · depend on a legacy table · depend solely on real-money bets.
**Exit:** floored multi-factor Vibe broadcasts over Realtime; engine consumes it.

---

## PHASE 5 — Real-money rail + market gating + payout (G-MON)
**Effort:** L · **Depends:** P3, P6 (moment-owner routing) · **Migrations:** ~126–128 · **PR:** `v3-p5-real-money`

**🚧 DECISION GATE G-MON** — confirm with product owner before live go-live:
> Real-money `battle_outcome` market created **iff both players KYC-verified** (default); royalty → moment-owners of played chits; licensed celebrity chits premium; consent at mint, KYC at cash-out. **Build the gate regardless; confirm the rule before flip.**

**Hard live-flip prereqs (independent, clear any time):**
| # | Task | Done |
|---|---|---|
| 5.0a | Merge `doc6-mobile-iap-confirm` (mig **115** `mobile_iap_receipts`) — currently committed on branch, NOT merged. | ☐ |
| 5.0b | Rotate `NORA_SIGNING_PRIVATE_KEY` on a **secure machine** + update public key before `LKN_PAYMENTS=live` (current key known-compromised, generated in Codespace). | ☐ |

| # | Task | Done |
|---|---|---|
| 5.1 | **`currency`** on `markets` (`'token'\|'usd'`, default token) + denormalized on `bets`; `handle_bet_pool_update` branches (token→`token_balances`; USD→`sim_usd_balances`/Stripe Treasury). Markets stays token-only; battle markets settle USD. | ☐ |
| 5.2 | **G-MON gating**: create real-money `battle_outcome` market **iff both players KYC'd**; else run non-monetized. | ☐ |
| 5.3 | Rewrite **`match_revenue_config`** to explicit keys: `predictors 0.80, winner_players 0.06, loser_players 0.02, creator 0.02, passive_holders 0.05, platform 0.05`. Creator slice → **moment-owners of chits played**; passive slice → holders of those chits. | ☐ |
| 5.4 | Wire **Stripe Connect** (royalty payouts) + **Treasury** (pools + Fund) for live behind config; sim preserved. KYC at cash-out; age + jurisdiction gates; `identity_hash` populated; idempotent across Stripe + RevenueCat. | ☐ |

**DO NOT:** settle Battle in tokens or Markets in real money · create real-money market unless both KYC'd · flip live before 5.0a + 5.0b.
**Exit:** currency-branched settlement; gated market creation; moment-owner payout; sim intact, live behind config.

---

## PHASE 6 — Minting pipeline + tier-ascension
**Effort:** L · **Depends:** P2 · **Migrations:** ~129–130 · **PR:** `v3-p6-mint-ascend`
*(Sequence note: P6 mint must exist before P5 can route royalties to moment-owners — build P6 mint before P5.3/5.4 wiring.)*

**6.1 Minting**
| # | Task | Done |
|---|---|---|
| 6.1a | Social link via existing API access (record consent). | ☐ |
| 6.1b | **Recommend the moment** — surface user's highest-engagement post/video. | ☐ |
| 6.1c | **Animate** — moment → cel-shaded clip via camera cuts; never rig to a skeleton. | ☐ |
| 6.1d | **Classify** content → archetype family. | ☐ |
| 6.1e | **Assign tier** from `engagement_tier_thresholds` (current engagement). | ☐ |
| 6.1f | **Moderate** before mint. | ☐ |
| 6.1g | **Mint** `moment_chits` row with ladder-derived cost/stats/effect; card art = viral thumbnail. User picks moment+flavor; system sets family/tier/cost/stats/effect. **Users never set power.** | ☐ |

**6.2 Tier-ascension**
| # | Task | Done |
|---|---|---|
| 6.2a | **Weekly refresh**, user-requested, **≤1/7 days per user** (cooldown protects APIs). Pull current cumulative engagement → recompute tier → ascend if higher tier crossed. | ☐ |
| 6.2b | **One-directional** (never de-rank), **definition-level** (all owned copies ascend together), re-derive stats/cost/effect from cost-banded ladder. Family/effect type fixed at mint; only magnitude/tier scales. | ☐ |
| 6.2c | **Match safety**: ascension between matches only; active matches use start snapshot (Hard Rule 36). | ☐ |
| 6.2d | **Abuse mitigation**: authenticity heuristics + moderation on refresh; manual-review queue for large single-jump ascensions; deleted post/expired token → last-verified tier persists (no de-rank, no further ascension until re-verified). | ☐ |

**DO NOT:** let users set tier/stats · de-rank chits · change archetype/effect type on ascension · apply ascension to in-progress match · exceed weekly per-user API cap.
**Exit:** moments → chits pipeline live; viral chits ascend safely.

---

## PHASE 7 — Fusion expansion + deprecation cleanup + Fund + launch hygiene
**Effort:** M · **Depends:** P2/P3 (fusion content), all · **PR:** `v3-p7-launch-hygiene`

| # | Task | Done |
|---|---|---|
| 7.1 | **Fusion rule expansion** — author additional `fusion_rules` + fusion effect templates beyond starter set (content, not engine). | ☐ |
| 7.2 | Execute deprecations **(markers set in P1 mig 121)**: physically archive retired 1v1/stat/moveset tables (rename `battle_abilities`→*_archived); drop `check_battle_eligibility`/`get_eligible_characters` license-per-character eligibility (gated on P3 engine live + nora-arena cutover to `deck_is_legal`); **weekly polls + multipliers → DORMANT**; retire parody-avatar scaffolding (celebrities now = licensed chits). | ☐ |
| 7.3 | **Emergency Fund (G4 default)** live wiring on shared Treasury/KYC rail behind config; sim acceptable at launch; may hold to immediate post-launch if P5 runs long. | ☐ |
| 7.4 | **Pre-launch reset** (ARCHIVE §A8) + remove dev tooling (`dev_*`, `arena-dev-*` fns); test-account sweep; seed required imagery. | ☐ |
| 7.5 | Final `flutter analyze` clean; real-money + token smoke tests pass. | ☐ |

**DO NOT:** drop dormant/retired schemas · ship dev tooling to prod.
**Exit:** expanded fusion; retired schemas archived (not dropped); Fund behind config; dev tooling gone; smoke tests green.

---

## Cross-repo contract (mirror into RECONCILIATION.md — P0.5)

| Backend provides | Arena (nora-arena) consumes | Phase |
|---|---|---|
| `moment_chits` catalog (tier, family, chit_type, cost/atk/hp, keywords, vibe_gate, card_art_url, moment_video_ref) | render illustrated cards w/ tier badges; build decks | P1/P2 |
| Lean deck rules (size 20 / max 2 copies) | deck-builder validation mirror | P1 |
| CCG `battle_events` stream (draw/summon/attack/effect/fusion/KO, Life/Aura/Vibe `*_after`) | `PlaybackQueue` + `SubmitTurn`; HUD reconciles from server | P3 |
| Shared-3D summon contract + `moment_video_ref` | shared humanoid rig + camera-cut compositing | P3 |
| Server-authoritative `match_vibe` (multi-factor, floored) | render Vibe; never compute | P4 |
| Real-money market iff both KYC'd; royalty → moment-owners | bet UI only on KYC'd matches; KYC/age/jurisdiction gating | P5 |
| Minting + ascension (weekly, definition-level, one-directional) | minting UI; tier-reveal; ascension/refresh UI + tier-up celebration | P6 |
| `fusion_rules` (tag-based) | fusion feedback + combined cutscene | P3 |

**One open product call:** 🚧 **G-MON** (real-money market gating + royalty routing). Everything else locked or engineering.

---

## Per-phase report template (use after each PR)
```
Phase Px — <name>
- What changed: <migrations added, functions, tables, docs>
- Checklist: <n/m items complete>
- flutter analyze: <clean / issues>
- Smoke test: <pass/fail + what was exercised>
- Gate hit: <none / G-MON needs product confirm / prereq blocking>
- Ground-truth surprises: <any spec-vs-repo mismatch found>
```
