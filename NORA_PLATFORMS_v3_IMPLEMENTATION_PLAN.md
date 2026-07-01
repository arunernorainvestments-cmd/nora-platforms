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

## PHASE 2 — Tier ladder + anatomy + effects/keywords/families + fusion DATA ⭐ CRITICAL PATH  ✅ applied to prod (mig 122–125)
**Effort:** L · **Depends:** P1 · **Migrations:** 122–125 · **PR:** `v3-p2-balance-core`

| # | Task | Done |
|---|---|---|
| 2.1 | **`tier_ladder`** — per tier F–S: `aura_cost_range, atk_range, hp_range, effect_power`. **Cost-banded** (higher tier stronger AND costlier). → **mig 122** + `assert_tier_cost_banding()` statement-trigger (encodes Hard Rule 34 — rebalancing can't break cost-banding). | ✅ |
| 2.2 | **`engagement_tier_thresholds`** — engagement→tier map (F `<1k` … S `>5M`, per-platform normalized). Read by mint + ascension (P6). → **mig 122** + `tier_for_engagement()`. | ✅ |
| 2.3 | **`effect_templates`** — finite library keyed by (archetype family × timing type), parameterized by tier `effect_power`. Chit references template; magnitude = template scaled to tier. → **mig 123** (10-template starter library, 1 signature effect/family; `is_fusion` flag + shape CHECK). | ✅ |
| 2.4 | Enumerate **timing types** (`on_summon, activated, triggered, counter`), **keywords** (`taunt, charge, shield, stealth`), **archetype families** (athlete/musician/artist/scientist/comedian/influencer/politician/business/gamer/actor). → CHECK constraints across mig 116/123/124. | ✅ |
| 2.5 | **`fusion_rules`** — tag-based **patterns** `{archetype_family, keyword, element/tag, count}` → fusion effect template scaled by component tiers. Ship a **launch starter set**. → **mig 124** (3 fusion templates + 3 starter rules: athlete-pair / charge-pair / musician-pair; `power_scaling` sum/max/avg; template-must-be-fusion guard). | ✅ |
| 2.6 | **Derivation function**: `(family, timing, tier) → concrete (cost, atk, hp, effect magnitude)`. This is what 1.1, P3, and P6 all call. → **mig 125** `derive_chit_stats()` + `create_moment_chit()` (sanctioned server-only writer) + adds `moment_chits.effect_magnitude` & the `effect_ref → effect_templates` FK. | ✅ |

**DO NOT:** author fusion as per-card recipes · break cost-banding (no strictly-better-for-cost high tiers) · scale stats without scaling cost.
**Exit:** balance data + derivation fn exist; a chit's numbers are fully ladder-derived.
**Push status:** migrations 122–125 **APPLIED to prod** 2026-07-01 via `supabase db push` (clean). Functional proof: mig 125 seeds 6 chits through `create_moment_chit`→`derive_chit_stats`→insert against the FK + all CHECKs — inserted with zero errors, validating the whole derivation chain. (6 dev-seed chits now in catalog — swept by P7 reset.) No Dart → `flutter analyze` unaffected.

---

## PHASE 3 — CCG combat engine (`process_battle_turn` rebuilt) — LARGEST BUILD
**Effort:** XL · **Depends:** P2 · **Migrations:** 126–129 · **PR:** `v3-p3-ccg-engine` · ✅ applied to prod

| # | Task | Done |
|---|---|---|
| 3.1 | **Board-state engine**: per-match state (both Life, Aura/max-Aura, hand, deck, field ≤3, Vibe). Built as **NEW `ccg_*`** (mig 126: `ccg_matches`/`ccg_match_players`/`ccg_match_cards`/`ccg_events`); legacy `battle_*` engine left intact (non-breaking, archived in P7). | ✅ |
| 3.2 | **Start of turn**: max Aura +1 (cap 10), refill, draw 1, fire `start_of_turn` triggers, read Vibe. → **mig 128** `ccg_begin_turn`. | ✅ |
| 3.3 | **Main**: validate/resolve summon (3-cap, summoning sickness unless `charge`), cast spell-moment, pay `activated`; each spends Aura; Vibe-gated require current threshold. → **mig 129** `ccg_submit_turn`. | ✅ |
| 3.4 | **Combat**: face=Life dmg; creature-vs-creature mutual ATK→HP; `taunt` forces targeting; eliminate at 0 HP. → **mig 129** (attack handler) + **128** `ccg_damage_creature`/`ccg_kill_card`. | ✅ |
| 3.5 | **End**: fire `end_of_turn` triggers; hold `counter` for opponent. → **mig 129** (end phase) + **128** `ccg_fire_timed_triggers`; `counter`/when_attacked fires in the attack handler. | ✅ |
| 3.6 | **Fusion detection/resolution**: within a turn's "Advance window," match played chits to `fusion_rule` patterns; resolve combined effect; emit fusion event. → **mig 128** `ccg_resolve_fusions` (matches this-turn summons on family/keyword; power_scaling over component tiers). | ✅ |
| 3.7 | **Match-start snapshot**: freeze each deck chit's tier/stats so mid-match ascension can't alter an active match (Hard Rule 36). → **mig 129** `ccg_instantiate_card` copies `snap_*` at match start; engine reads snapshot only. | ✅ |
| 3.8 | ordered event stream (draw/summon w/ chit ref/attack/effect/fusion/KO + Life/Aura/Vibe deltas), keyed `(turn_number, sequence_in_turn)` with `*_after` reconciliation. → **mig 126** `ccg_events` (own stream, supersedes legacy `battle_events`) + **127** `ccg_emit_event` stamps `life_p1/p2_after`, `aura_active_after`, `vibe_after`. | ✅ |

**DO NOT:** compute any outcome client-side · let ascension affect in-progress match · exceed field cap or skip sickness/taunt validation server-side.
**Exit:** full server-authoritative CCG turn resolves and emits a complete event stream.
**Push status:** migrations 126–129 **APPLIED to prod** 2026-07-01. Functional proof: mig 129's apply-time smoke plays a synthetic match (summon → on-summon effect → 2 fusions → face damage → event stream) and asserts — logged `CCG engine smoke OK: 2 summons, 2 fusion(s), seat2 life 2` (synthetic match auto-deleted). ⚠️ **Balance note:** fusion magnitude scales high (base × Σ tier effect_power ≈ 27) — tune in P7; mechanism correct. Deck-entry path (`ccg_create_match` from real 20-card decks + 2 auth users) not yet exercised end-to-end (needs the deck/matchmaking UI or a test-account pass). No Dart → `flutter analyze` unaffected.

---

## PHASE 4 — Vibe Meter backend  ✅ applied to prod (mig 130–131)
**Effort:** M · **Depends:** P2 (threshold contract) · **Migrations:** 130–131 · **PR:** `v3-p4-vibe`

| # | Task | Done |
|---|---|---|
| 4.1 | **`process_battle_vibe_tick`** — copy only the COMMIT-per-tick + Realtime-broadcast pattern from the retired arena tick; **zero legacy-table dependency**. → **mig 131** (void fn, one call = one tick; `ccg-vibe-tick` pg_cron @30s; zero legacy deps). | ✅ |
| 4.2 | **`match_vibe`** state (0–100 + thresholds). → **mig 130** (`vibe` live + `available_vibe` latched + `vibe_floor`; thresholds = chits' `vibe_gate`). | ✅ |
| 4.3 | Vibe = f(market activity + spectator presence + token reactions) with **passive floor / slow rise** (works in thin/non-monetized matches). Server-authoritative. → **mig 130** `ccg_vibe_events` (3 sources) + `ccg_record_vibe_signal()`; **mig 131** slew-toward-target (floor + activity, rise +5/decay −3 per tick). | ✅ |
| 4.4 | Engine (P3) reads thresholds for Vibe-gated chits; availability applies at **next-round boundary** after a crossing. → **mig 130** repoints `ccg_get_match_vibe()` to `available_vibe`; `ccg_matches_latch_vibe` trigger latches live→available on turn advance (no `ccg_begin_turn` change needed). | ✅ |

**DO NOT:** compute Vibe client-side · depend on a legacy table · depend solely on real-money bets.
**Exit:** floored multi-factor Vibe broadcasts over Realtime; engine consumes it.
**Push status:** migrations 130–131 **APPLIED to prod** 2026-07-01. Functional proof: mig 131 smoke — activity pulse → 3 ticks → `vibe 15` → round-boundary latch → engine reads latched value (logged `Vibe tick smoke OK: vibe 15, latched available 15`). Realtime: `match_vibe` + `ccg_events` added to `supabase_realtime` publication. `ccg_record_vibe_signal()` is the hook P5 bets/reactions will call. No Dart → `flutter analyze` unaffected.

---

## PHASE 5 — Real-money rail + market gating + payout (G-MON)  ✅ built like-live, SIM behind switch (mig 132–134)
**Effort:** L · **Depends:** P3, P6 (moment-owner routing) · **Migrations:** 132–134 · **PR:** `v3-p5-real-money`

> **The switch:** `platform_integrity_settings.battle_payments_mode` (`sim`|`live`, default **sim**). Everything is
> built as if live; in sim, USD flows against `sim_usd_balances`; flipping to `live` routes to Stripe Treasury —
> the live branch RAISEs until the two prereqs land (5.0a/5.0b). Helper: `battle_payments_mode()`.

**🚧 DECISION GATE G-MON** — confirm with product owner before live go-live:
> Real-money `battle_outcome` market created **iff both players KYC-verified** (default); royalty → moment-owners of played chits; licensed celebrity chits premium; consent at mint, KYC at cash-out. **Build the gate regardless; confirm the rule before flip.**

**Hard live-flip prereqs (independent, clear any time):**
| # | Task | Done |
|---|---|---|
| 5.0a | Merge `doc6-mobile-iap-confirm` (mig **115** `mobile_iap_receipts`) — currently committed on branch, NOT merged. | ☐ |
| 5.0b | Rotate `NORA_SIGNING_PRIVATE_KEY` on a **secure machine** + update public key before `LKN_PAYMENTS=live` (current key known-compromised, generated in Codespace). | ☐ |

| # | Task | Done |
|---|---|---|
| 5.1 | **`currency`** on `markets`/`bets` (default token) + usd pools; the 3 bet triggers branch on currency (token path byte-for-byte preserved; usd → `ccg_usd_debit`/usd pools). → **mig 132** (columns + `ccg_usd_debit`/`ccg_usd_credit` sim/live-switched) + **133** (branched `handle_bet_pool_update`/`handle_bet_token_deduction`/`handle_bet_notify_creator`). Markets stays token; battle markets USD (Hard Rule 33). | ✅ |
| 5.2 | **G-MON gating**: create real-money `battle_outcome` market **iff both players KYC'd**; else non-monetized. → **mig 133** `ccg_create_outcome_market` (returns NULL when not both KYC'd) + `ccg_place_bet`; **`enforce_ccg_bet_integrity`** BEFORE-INSERT trigger enforces one-role (combatant can't bet) + eligibility — additive, never weakens mig-102 (Hard Rule 26). | ✅ |
| 5.3 | Explicit payout keys `ccg_*` (predictors .80/winner .06/loser .02/creator .02/passive .05/platform .05; legacy keys untouched). Creator slice → **moment-owners of chits PLAYED** (`ccg_match_cards`→`moment_chits`→`moments.owner_user_id`); passive → holders of those chits pro-rata. → **mig 132** (keys) + **134** `ccg_settle_market` + finish trigger (exception-guarded). | ✅ |
| 5.4 | USD rail wired for live behind the switch (sim preserved); `is_eligible_for_real_money` (KYC always; age≥18 + jurisdiction at live); idempotent settlement (market-status guard). Full Stripe Connect/Treasury API + `identity_hash`/RevenueCat idempotency = live-branch stubs (RAISE until flip). | ◑ sim complete; live branch stubbed |

**DO NOT:** settle Battle in tokens or Markets in real money · create real-money market unless both KYC'd · flip live before 5.0a + 5.0b.
**Exit:** currency-branched settlement; gated market creation; moment-owner payout; sim intact, live behind config.
**Push status:** migrations 132–134 **APPLIED to prod** 2026-07-01. Functional proof: mig 134 smoke — `P5 smoke OK: split sums 1.0, mode sim, G-MON gated non-KYC match to non-monetized`. ⚠️ Full payout round-trip (2 KYC'd users + sim USD, moment-owner + passive-holder credits) NOT yet exercised e2e — needs a test-account pass. Live Treasury/Connect API + age/jurisdiction enforcement + IAP idempotency are stubbed behind `battle_payments_mode='live'` (RAISE until 5.0a/5.0b). No Dart → `flutter analyze` unaffected.

---

## PHASE 6 — Minting pipeline + tier-ascension  ✅ applied to prod (mig 135–136)
**Effort:** L · **Depends:** P2 · **Migrations:** 135–136 · **PR:** `v3-p6-mint-ascend`
*(DB owns orchestration; social fetch / cel-shaded animation / AI family classification are external edge steps that feed params.)*

**6.1 Minting** → **mig 135** (extends `moments` w/ pipeline state; `moment_record`/`moment_recommend`/`moment_moderate`/`moment_mint`)
| # | Task | Done |
|---|---|---|
| 6.1a | Social link via existing API access (record consent). → `moment_record` (sets `consent_granted_at`). | ✅ |
| 6.1b | **Recommend the moment** — surface user's highest-engagement post/video. → `moment_recommend` (max engagement, un-minted). | ✅ |
| 6.1c | **Animate** — moment → cel-shaded clip via camera cuts; never rig to a skeleton. → external edge; `moment_video_ref` stored at mint. | ◑ external |
| 6.1d | **Classify** content → archetype family. → external AI; family passed to `moment_mint`. | ◑ external |
| 6.1e | **Assign tier** from `engagement_tier_thresholds` (current engagement). → `moment_mint` calls `tier_for_engagement`. | ✅ |
| 6.1f | **Moderate** before mint. → `moment_moderate`; `moment_mint` requires `moderation_status='approved'`. | ✅ |
| 6.1g | **Mint** `moment_chits` via ladder-derived stats; card art = viral thumbnail; **users never set power**. → `moment_mint` → `create_moment_chit` (consent_minted, thumbnail as card art). | ✅ |

**6.2 Tier-ascension** → **mig 136** (`chit_ascension_log`, `ascension_review_queue`, `moment_chit_rederive`, `chit_ascension_refresh`)
| # | Task | Done |
|---|---|---|
| 6.2a | **Weekly refresh**, ≤1/7 days per user (cooldown). → `chit_ascension_refresh` (7-day guard via `chit_ascension_log`; recompute tier from engagement). | ✅ |
| 6.2b | **One-directional** / **definition-level** / re-derive from cost-banded ladder; family/effect fixed. → `moment_chit_rederive` (updates the catalog row = all copies; only ascends when new rank > current). | ✅ |
| 6.2c | **Match safety**: between matches only; active matches use start snapshot (Hard Rule 36). → catalog update is safe; matches read `ccg_match_cards.snap_*`. | ✅ |
| 6.2d | **Abuse mitigation**: moderation on refresh; **large-jump (≥3 tiers) → manual-review queue** (not auto-applied); deleted/expired source keeps last tier (`source_status<>'active'` skipped). | ✅ |

**Push status:** migrations 135–136 **APPLIED to prod** 2026-07-01. Smokes: `P6.1 mint OK` (engagement→tier boundaries + missing-moment guard); `P6.2 ascension OK` (Seed Sprinter C→A re-derived: cost 8, mag 12, family/effect fixed → reset C). ⚠️ Full owner-scoped mint + weekly refresh cooldown not e2e-tested (needs a real auth user + linked moment). No Dart → `flutter analyze` unaffected.

**DO NOT:** let users set tier/stats · de-rank chits · change archetype/effect type on ascension · apply ascension to in-progress match · exceed weekly per-user API cap.
**Exit:** moments → chits pipeline live; viral chits ascend safely.

---

## PHASE 7 — Fusion expansion + deprecation cleanup + Fund + launch hygiene  ◑ additive done (mig 137); destructive DEFERRED to launch prep
**Effort:** M · **Depends:** P2/P3 (fusion content), all · **PR:** `v3-p7-launch-hygiene`

| # | Task | Done |
|---|---|---|
| 7.1 | **Fusion rule expansion** — author additional `fusion_rules` + fusion effect templates beyond starter set. → **mig 137**: +3 fusion templates (control_purge/disrupt/wall) + 3 rules (scientist/comedian/shield pairs) = **6 rules total**. PLUS balance pass: gentler `effect_power` curve (F1…S4) + all fusion rules → `avg` scaling (fixed the ~27-dmg issue → Seed Sprinter magnitude now 4); seed chits re-derived. | ✅ |
| 7.2 | Execute deprecations (markers set in P1 mig 121): physically archive retired 1v1/stat/moveset tables; drop `check_battle_eligibility`/`get_eligible_characters`; polls→DORMANT; retire parody-avatar scaffolding. | ⏸ **DEFERRED to launch prep** — mobile still consumes legacy fns; gated on P3-engine cutover + the pending companion↔nora-arena pivot. Do NOT run before that. |
| 7.3 | **Emergency Fund (G4 default)** live wiring behind config; sim acceptable at launch. | ✅ already satisfied — Fund runs in sim (ubi_*), which the spec accepts at launch; flips to live on the shared Treasury/KYC rail (same `battle_payments_mode`-style switch) post-launch. No new work now. |
| 7.4 | **Pre-launch reset** (ARCHIVE §A8) + remove dev tooling (`dev_*`, `arena-dev-*`); test-account sweep; seed imagery; **remove P2/P3 dev-seed chits + `is_test` matches**. | ⏸ **DEFERRED to launch day** — destructive; must run last, after the pivot and once matches/decks are exercised. |
| 7.5 | Final `flutter analyze` clean; real-money + token smoke tests pass. | ◑ per-phase apply-time smokes green; **full flutter analyze + e2e real-money/token round-trip pending** the Flutter client work + test-account pass. |

**DO NOT:** drop dormant/retired schemas · ship dev tooling to prod.
**Exit:** expanded fusion; retired schemas archived (not dropped); Fund behind config; dev tooling gone; smoke tests green.
**Push status:** mig 137 (additive: fusion expansion + balance) **APPLIED to prod** 2026-07-01. 7.2 + 7.4 (destructive) intentionally deferred — see notes. No Dart → `flutter analyze` unaffected.

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
