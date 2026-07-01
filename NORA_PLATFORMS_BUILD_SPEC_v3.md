# NORA Platforms — Build Spec **v3** (The "Moments" Card-Battler)
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md in full before touching any file.**

> ⚠️ **v3 supersedes the v2.x alignment specs and the 1v1 archetype-fighter model entirely.** The game is now a collectible card-battler built on minted "moments." Where v2.x described a duel between archetype characters with D&D stats, v3 describes a card game: collect Battle Chits, summon them onto a shared-3D field, win by reducing the opponent's Life to 0. Authority is unchanged: this repo owns ALL backend; Arena is display-only/server-authoritative.

---

## 0. How to use this document

**Before any phase:** `ls supabase/migrations/` and reconcile to ARCHIVE.md §B1 (ledger 066→115). Migrations apply **only** via `supabase db push`. `flutter analyze` zero issues before/after every phase. Money math in integer USD cents. Append-only ledgers stay INSERT-only. Idempotent credits.

**Process rules:** (1) **Verify, don't assume** — confirm every named table/column/function against the repo before changing it. (2) **Decision gates** marked 🚧 need a product answer; build the mechanism to the gate and stop. (3) Each phase has a **Deliverables** checklist and a **DO NOT** block; treat each phase as one atomic unit.

**Status tags:** [BUILT] · [REPURPOSE] · [NEW] · [CUT] (archive, don't drop) · [DORMANT].

---

## 1. The model (canonical — encode everywhere)

**The game.** Each player has **Life** (default 30). Players build a **lean deck** of **Battle Chits** and, on their turn, spend **Aura** to summon chit creatures onto a shared-3D field (Lord-of-Heroes camera) or cast one-shot spell-moments. Creatures have **ATK + HP only** (no AP). Win by reducing the opponent's Life to 0.

**The asset = the chit.** A Battle Chit is a card minted from a real **viral moment** (a user's social post). Chits are owned/collected/traded. The expressive identity of a chit is its **card art (the viral thumbnail) + a minted cel-shaded video** composited by camera cut on summon and signature abilities; the body is a **shared 3D humanoid rig** with a common clip set reused by all summons.

**Two layers of value:**
| | **Consent-minted user moments** (the base) | **Licensed creator/celebrity moments** (premium) |
|---|---|---|
| Source | a user's own social post, consent at link | a consented, licensed creator (the `lkn_*` pipeline) |
| Availability | free to mint/collect | premium card packs (fast-follow as agreements land) |
| Money | KYC at cash-out / real-money play | same |

**Locked combat constants** (all tunable in config): Life 30 · **Aura climbs +1/turn to a cap of 10**, refills each turn, **no land cards** · deck 20 · max 2 copies per chit · opening hand 3–4 · **field cap 3 creatures per player** · creatures = ATK + HP, no AP.

**Two resource gates** (independent): **Aura** ("can I afford it?", personal, auto-ramp) and **Vibe** ("is the crowd hyped?", shared, symmetric, prediction-market-driven, server-authoritative, with a passive floor). Premium "ultimate moment" chits require both.

**No class edges.** Avatars are cosmetic. "Archetype" survives only as the **effect-family classifier** of a chit (athlete = aggressive body, musician = AoE debuff, scientist = control/removal, comedian = disruption, …).

**What survives from v2.x and gets stronger:** prediction markets, the **Vibe Meter** (now also a gameplay unlock), the licensing infrastructure (now for premium packs), the **two-currency model**, and the **payout split** (the creator slice now routes to the **moment-owner** — "summon your friend, your friend earns").

**What is deprecated:** the 1v1 fighter resolver, **D&D six-stat characters**, per-archetype move-sets, license-per-character battle eligibility, and the parody-celebrity-avatar base (celebrities return as licensed premium chits).

---

## 2. Decision gates & locked decisions

| Item | Status |
|---|---|
| 🚧 **G-MON (monetization gating)** | **DEFAULT (confirm):** a real-money prediction market runs on a match **iff both players are KYC-verified**; the creator royalty flows to the **moment-owners** of chits played; licensed celebrity chits are premium content; consent at mint, KYC at cash-out. Build the gate; this is the one open product call. |
| **Fusion** | **LAUNCH / core.** Tag-based (keys on archetype family / keyword / element), not per-card recipes. See P2 (rules) + P3 (resolution). |
| **Tier ladder + ascension** | **LAUNCH / core.** F/E/D/C/B/A/S, **cost-banded**; ascension one-directional, definition-level, weekly-refreshable. See P2 (ladder) + P6 (ascension). |
| **Combat constants** | Locked per §1 (config-driven). |
| **Vibe** | Symmetric, market-driven, passive floor — survives from v2.x. |
| **Deck** | Lean at launch; deck-building later. |

---

## PHASE 0 — Canonical model + governance

**Goal:** make the four canonical docs describe the card-battler so every later phase inherits it.

**Deliverables**
- [ ] CLAUDE.md: rewrite the Systems block to §1 (chits, Aura, Vibe, tiers, fusion, minting, ascension, the consent-vs-licensed split). Mark the 1v1 fighter / D&D-stat / archetype-moveset / license-per-character-eligibility model **deprecated**.
- [ ] Hard Rules (append as 33+, never renumber): (33) "Battle prediction markets settle in real money (USD), Markets in tokens — never cross." (34) "A chit's archetype/effect-family and damage numbers come from the authored **tier ladder**, never user-set." (35) "Real-money markets exist only for matches where **both players are KYC-verified** (per G-MON)." (36) "Tier ascension is one-directional and applies between matches only; matches snapshot chit stats at start."
- [ ] PLAN.md: replace the v2.x phase plan with P0–P7 below; move the deprecated systems to a "Retired" section.
- [ ] RECONCILIATION.md: record the cross-repo contract changes (chit catalog, tier exposure, CCG event stream, market gating) as the new client contracts.
- [ ] ARCHIVE.md: dated entry noting the pivot and where the retired 1v1/stat schemas sit.

**DO NOT** delete retired tables this phase (docs only). Don't weaken the KYC / one-role-per-match integrity rules — they remain load-bearing for real-money play.

---

## PHASE 1 — Chit catalog + collection + deck + ownership/barter

**Goal:** the asset layer — chits exist, are owned/collected, deckable, and tradeable.

**What changes**
- [NEW] **`battle_chits`** catalog (the chit *definition*, keyed to a moment): `id`, `moment_id`, `character_class` (`consent_minted` | `licensed`), `chit_type` (`creature` | `spell_moment`), `archetype_family`, `tier` (F/E/D/C/B/A/S), `aura_cost`, `atk`, `hp` (creatures), `timing_type`, `keywords[]`, `effect_ref`, `vibe_gate` (nullable), `card_art_url`, `moment_video_ref`. Tier/cost/atk/hp/effect are **derived from the tier ladder** (P2), not free-set.
- [NEW] **Ownership/collection** (`chit_ownership`: user ↔ chit, quantity) — append-only acquisition ledger + a derived holdings view. A user collects chits; copies of the same chit are fungible.
- [NEW] **Lean deck rules** (`decks` / `deck_chits`): deck size 20, max 2 copies per chit, validated server-side on save and at match entry.
- [REPURPOSE] **Barter for chits** (`chit-barter` RPC): chit↔chit / chit↔token swaps need **no KYC**; any swap involving a **licensed** premium chit (licensing crossover) requires **KYC on both parties** via the verify/cancel popup. Atomic; logs a transfer event.
- [REPURPOSE] Premium **chit packs** ride the existing `lkn_*` licensing/marketplace plumbing (a licensed pack is a set of `licensed`-class chits sold for real money).
- [CUT] Retire `battle_characters` *as a 1v1 character home* and the per-archetype `battle_abilities` move-set tables (archive). License-per-character battle eligibility is removed — eligibility is now "you own chits and have a legal deck."

**Deliverables**
- [ ] `battle_chits` + `chit_ownership` (+ append-only acquisition ledger) + RLS.
- [ ] `decks`/`deck_chits` with server-side validation (size/copies).
- [ ] `chit-barter` with the KYC-on-licensed-crossover rule; non-licensed swaps ungated.
- [ ] Premium-pack flow on `lkn_*` plumbing.
- [ ] 1v1 character/moveset tables archived; license-per-character eligibility removed.

**DO NOT** allow user-set tier/cost/stats. Don't let a licensed-pack barter skip KYC. Don't drop the archived 1v1 tables.

---

## PHASE 2 — Tier ladder + chit anatomy + effects/keywords/families + fusion rules

**Goal:** the data + balance core. **This is the heart of the game — `process_battle_turn` and minting both depend on it.**

### 2.1 The tier ladder (the core balance table)
- [NEW] **`tier_ladder`** — for each tier F/E/D/C/B/A/S, the **cost-banded** stat/effect envelope: `aura_cost_range`, `atk_range`, `hp_range`, `effect_power`. **Tiers are cost-banded: a higher tier is stronger AND costs more Aura** — an S-tier is a different point on the curve, not strictly-better-for-cost. This banding is the rule that keeps virality from equalling auto-win.
- [NEW] **`engagement_tier_thresholds`** — the engagement → tier mapping (illustrative, tunable): F `<1k` · E `1k–10k` · D `10k–50k` · C `50k–250k` · B `250k–1M` · A `1M–5M` · S `>5M` (post-engagement, normalized per platform). Mint reads this (P6); ascension re-reads it (P6).

### 2.2 Chit anatomy & effect model
- [NEW] **Effect templates** (`effect_templates`): a finite, balanceable library keyed by archetype family + timing type, parameterized by tier `effect_power`. A chit references a template; its magnitude = template scaled to its tier.
- [NEW] **Timing types**: `on_summon`, `activated` (pay Aura later), `triggered` (condition — "when attacked", "start of turn", "when an ally is KO'd"), `counter` (held/reactive).
- [NEW] **Keywords**: `taunt`, `charge`, `shield`, `stealth` (persistent properties).
- [NEW] **Archetype families** = the effect-family classifier (athlete/musician/artist/scientist/comedian/influencer/politician/business/gamer/actor).

### 2.3 Fusion rules (tag-based — the system, not a recipe book)
- [NEW] **`fusion_rules`** — authored **patterns**, not per-card recipes, so they apply to any qualifying (incl. user-minted) chits. A rule matches on `{archetype_family, keyword, element/tag, count}` and maps to a **fusion effect template** at a power scaled by the components' tiers. Example pattern: "≥2 Athlete-family creatures summoned in one turn → Power-Advance combined strike." Ship a **starter set** at launch (expandable).
- Resolution lives in P3; this phase defines the rule + effect data model.

**Deliverables**
- [ ] `tier_ladder` (cost-banded) + `engagement_tier_thresholds`.
- [ ] `effect_templates` (family × timing, tier-scaled) + timing types + keywords + families enumerated.
- [ ] `fusion_rules` (tag-based patterns → fusion effect templates) with a launch starter set.
- [ ] A derivation function: given (family, timing, tier) → concrete (cost, atk, hp, effect magnitude) for `battle_chits`.

**DO NOT** author fusion as per-card recipes (won't scale to UGC). Don't break tier cost-banding (no strictly-better-for-cost high tiers). Don't let tier scale stats without scaling cost.

---

## PHASE 3 — CCG combat engine (`process_battle_turn` rebuilt)

**Goal:** the card-game resolver. **The single largest new build.** Server-authoritative; emits `battle_events` the client renders.

**What changes**
- [NEW/REBUILD] Replace the 1v1 duel resolver with a **board-state engine**: per-match state (both players' Life, Aura/max-Aura, hand, deck, field with ≤3 creatures, Vibe), and turn resolution:
  - **Start of turn:** max Aura +1 (to cap 10), refill Aura, draw 1, fire `start_of_turn` triggers, read Vibe.
  - **Main:** validate and resolve plays — summon (respect 3-cap, summoning sickness unless `charge`), cast spell-moment, pay `activated` abilities; each spends Aura; Vibe-gated chits require the current threshold.
  - **Combat:** creature attacks (face = Life damage; creature-vs-creature = mutual ATK→HP; `taunt` forces targeting; eliminate at 0 HP).
  - **End:** fire `end_of_turn` triggers; hold `counter` effects for the opponent.
- [NEW] **Fusion detection/resolution:** within a turn's "Advance window," detect when played chits match a `fusion_rule` pattern; resolve the combined fusion effect (Aura-costed by its components), and emit a fusion event (the client plays the combined cutscene).
- [NEW] **Snapshot:** at match start, snapshot each deck chit's tier/stats so mid-match ascension cannot alter an active match (Hard Rule 36).
- [NEW] **Event stream:** emit ordered `battle_events` for draws, summons (with `moment_video_ref`), attacks, effects, fusions, KOs, Life/Aura/Vibe deltas — keyed `(turn_number, sequence_in_turn)` with `*_after` reconciliation fields.

**Deliverables**
- [ ] Board-state engine + turn resolution (Aura economy, summon/3-cap/sickness, combat/targeting/taunt, timing types, keywords).
- [ ] Fusion detection + resolution against `fusion_rules`.
- [ ] Match-start stat snapshot.
- [ ] Ordered `battle_events` covering every CCG action with reconciliation fields.

**DO NOT** compute any outcome on the client. Don't let ascension affect an in-progress match. Don't exceed the field cap or skip summoning-sickness/taunt validation server-side.

---

## PHASE 4 — Vibe Meter backend

**Goal:** the per-match Vibe Meter — survives from v2.x, now also a gameplay unlock.

- [NEW] **`process_battle_vibe_tick`** (copies only the COMMIT-per-tick + Realtime-broadcast pattern from the retired arena tick; depends on **zero** legacy tables) + **`match_vibe`** state (0–100 + thresholds).
- [NEW] **Vibe = f(market activity + spectator presence + token reactions)** with a **passive floor / slow rise**, so it works in thin or non-monetized matches. Server-authoritative.
- The engine (P3) reads thresholds for Vibe-gated chits; availability applies at the **next-round boundary** after a threshold crosses.

**Deliverables:** `process_battle_vibe_tick` + `match_vibe` (no legacy dependency); multi-factor floored Vibe; broadcast over Realtime; engine consumes it.

**DO NOT** compute Vibe on the client or make it depend on a legacy table or solely on real-money bets.

---

## PHASE 5 — Real-money rail + market gating + payout

**Goal:** turn on the regulated surface; gate it correctly for the new model; route royalties to moment-owners.

**Prerequisites (hard gates before any live flip):**
- [ ] Merge `doc6-mobile-iap-confirm` (mig 115 `mobile_iap_receipts`).
- [ ] Rotate `NORA_SIGNING_PRIVATE_KEY` on a secure machine + update the public key before `LKN_PAYMENTS=live`.

**What changes**
- [NEW] **`currency`** on `markets` (`'token'|'usd'`, default token) + denormalized on `bets`; `handle_bet_pool_update` branches (token→`token_balances`; USD→`sim_usd_balances`/Stripe Treasury). Markets stays token-only; battle prediction markets settle USD.
- 🚧 **G-MON market gating:** a real-money `battle_outcome` market is created for a match **iff both players are KYC-verified** (default — confirm). Otherwise the match runs **non-monetized** (no real-money market).
- [NEW] **Payout → moment-owners.** Rewrite `match_revenue_config` to explicit keys (confirmed split): `predictors_pct 0.80`, `winner_players_pct 0.06`, `loser_players_pct 0.02`, `creator_pct 0.02`, `passive_holders_pct 0.05`, `platform_pct 0.05`. The **creator slice routes to the moment-owners of the chits actually played** in the match (the "summon your friend, your friend earns" flywheel); the passive slice to holders of those chits.
- [BUILT→WIRE] Stripe Connect (royalty payouts) + Treasury (pools + Fund) wired for live behind config; sim preserved. KYC at cash-out / real-money entry; age + jurisdiction gates; `identity_hash` populated; idempotent across Stripe + RevenueCat.

**Deliverables**
- [ ] Prereqs (mig 115 merged; key rotated).
- [ ] `currency` model + branched settlement; USD on Treasury rail.
- [ ] Market created iff both players KYC'd (G-MON); non-KYC matches non-monetized.
- [ ] Payout split with creator/passive slices routed to **moment-owners of played chits**.
- [ ] KYC/age/jurisdiction gates; integrity flipped at live; idempotent credits.

**DO NOT** settle Battle in tokens or Markets in real money. Don't create a real-money market unless both players are KYC'd. Don't flip live before the two prereqs.

---

## PHASE 6 — Minting pipeline + tier-ascension

**Goal:** the content funnel — moments become chits, and viral chits ascend.

### 6.1 Minting
- [NEW] **Social link** via existing API access (consent recorded). **Recommend the moment:** surface the user's highest-engagement post/video. **Animate:** the moment → cel-shaded anime-style clip optimized for a chit (blend via camera cuts; never rig to a skeleton). **Classify** content → archetype family. **Assign tier** from `engagement_tier_thresholds` (current engagement). **Moderate** before mint. **Mint** the `battle_chits` row with ladder-derived cost/stats/effect; card art = the viral thumbnail.
- The user picks the moment + flavor; the system assigns family/tier/cost/stats/effect. **Users never set power.**

### 6.2 Tier-ascension (the viral upgrade)
- [NEW] **Weekly refresh, user-requested, ≤ once / 7 days per user** (a per-user cooldown protects the APIs at launch). On refresh: pull the linked post's **current cumulative engagement**, recompute tier vs. `engagement_tier_thresholds`, and **ascend if a higher tier is crossed**.
- **Ascension is one-directional** (never de-rank — engagement is monotonic), **definition-level** (updates the chit's tier so **all owned copies ascend together**), and re-derives stats/cost/effect from the **cost-banded** ladder (stronger AND costlier — not free power). **Family/effect type is fixed at mint; only magnitude/tier scales.**
- **Match safety:** ascension applies **between matches only**; active matches use the start-of-match snapshot (Hard Rule 36).
- **Abuse mitigation:** engagement-authenticity heuristics + moderation on refresh; manual-review queue for large single-jump ascensions; deleted post / expired token → last-verified tier persists (no de-rank, no further ascension until re-verified).

**Deliverables**
- [ ] Minting pipeline (link → recommend → animate → classify → tier-assign → moderate → mint); users never set power.
- [ ] Ascension job (weekly, ≤1/7d/user cooldown): pull engagement → recompute tier → one-directional, definition-level ascend → re-derive from ladder.
- [ ] Match-start snapshotting honored; ascension only between matches.
- [ ] Authenticity/moderation guards + large-jump review queue.

**DO NOT** let users set their own tier/stats. Don't de-rank chits. Don't change a chit's archetype/effect type on ascension. Don't apply ascension to an in-progress match. Don't exceed the weekly per-user API refresh cap.

---

## PHASE 7 — Fusion expansion + deprecation cleanup + Fund + launch hygiene

- [NEW] **Fusion rule expansion** — author additional `fusion_rules` patterns and fusion effect templates beyond the launch starter set (content, not engine).
- [CUT/EXECUTE] Execute deprecations: archive the retired 1v1/stat/moveset tables; remove license-per-character eligibility remnants; **weekly polls + multipliers DORMANT**; retire any parody-avatar-specific scaffolding (celebrities now arrive as licensed chits).
- [BUILT→ON] **Emergency Fund (G4 default):** live wiring on the shared Treasury/KYC rail behind config; sim acceptable at launch; safe to hold to immediate post-launch if Phase 5 runs long.
- [EXECUTE] Pre-launch reset (ARCHIVE §A8) + remove dev tooling (`dev_*`); test-account sweep; seed any required imagery.

**Deliverables:** expanded fusion library; retired schemas archived; polls dormant; Fund wired behind config; dev tooling removed; reset run; `flutter analyze` clean; real-money + token smoke tests pass.

**DO NOT** drop dormant/retired schemas. Don't ship dev tooling to prod.

---

## Cross-repo contract (mirror into RECONCILIATION)

| Backend provides | Arena consumes |
|---|---|
| `battle_chits` catalog (+ `tier`, `archetype_family`, `chit_type`, cost/atk/hp, keywords, `vibe_gate`, `card_art_url`, `moment_video_ref`) | render chits as illustrated cards with tier badges; build decks (P1/P2) |
| Lean deck rules (size 20 / max 2 copies) | deck-builder validation mirror (P1) |
| CCG `battle_events` stream (draw/summon/attack/effect/**fusion**/KO, Life/Aura/Vibe `*_after`) | `PlaybackQueue` + `SubmitTurn`; HUD reconciles from server (P3) |
| Shared-3D summon contract + `moment_video_ref` | shared humanoid rig + camera-cut moment compositing (P3) |
| Server-authoritative `match_vibe` (multi-factor, floored) | render Vibe; never compute (P4) |
| Real-money market **iff both players KYC'd**; royalty to moment-owners | bet UI only on KYC'd matches; KYC/age/jurisdiction gating (P5) |
| Minting + **ascension** (weekly, definition-level, one-directional) | minting UI; tier-reveal; ascension/refresh UI + tier-up celebration (P6) |
| `fusion_rules` (tag-based) | fusion feedback + combined cutscene (P3) |

**One open product call:** 🚧 **G-MON** (real-money market gating + royalty routing). Everything else is locked or engineering.
