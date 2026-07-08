# NORA Interaction Layer — design spec (reactive play, counters, charge-up)

**Status:** DESIGN PROPOSAL — not built. Companion to `NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md`
(content) and the shipped Wave-1 library (live in the DB `effect_templates`, migs 151/152; design
record in ARCHIVE "2026-07-08" entry). This doc covers the **engine**
depth the user asked for after Wave 1: "instant deploy to block/counter," "counter/nullifying
cards," and "cards that build to stack damage on a later turn." Those are engine features, not
templates — so they live here, sequenced with the compound-effects work (Wave 2).

Everything is written to fit **this** engine (turn-based, server-authoritative, creature-centric,
single Aura curve + symmetric Vibe gate) rather than importing systems that fight it.

---

## 0. What exists today (the honest baseline)

Grounded in the live resolver (`ccg_submit_turn`, migs 128/129):

| Capability | State |
|---|---|
| `on_summon` battlecry, `activated` (pay-Aura action on your turn) | ✅ built |
| `triggered` (`start_of_turn` / `end_of_turn`) recurring effects | ✅ built |
| `counter` (`when_attacked`) — a board creature auto-reacts *before* damage (Understudy) | ✅ built |
| Single-clause effects only (`snap_effect_kind` × one target × one magnitude) | ✅ built |
| **Compound / multi-clause effects** | ❌ Wave 2 (resolver extension) |
| **Playing a card during the opponent's turn** (response window / priority) | ❌ not built |
| **Negate / counter a specific play** (counterspell) | ❌ no effect kind + needs a window |
| **Charge-up state** (store counters, release a big payoff later) | ❌ no per-card counter state |

**Design boundary (carried from the framework §0):** we do **not** import MTG's priority/response
system (both players hold priority, pass back and forth every step). It reshapes the whole turn
loop and slows a fast, mobile-first game. The turn stays: *you submit your ordered action list on
your turn; the opponent does not act during it.* The interactive "gotcha" comes from **pre-armed
reactions that auto-resolve** — the Hearthstone Secret model — which the engine already seeds with
`counter/when_attacked`.

---

## 1. Pillar A — Secrets (pre-armed reactions)  ← the core of this layer

**What it delivers:** counters, nullifies, reactive blocks, punishes — the "I saw that coming"
dynamic — with **zero** change to the turn structure.

**Model.** A Secret is a card you play on *your* turn (pay Aura) that enters a hidden **armed**
zone instead of the field. It carries a **trigger condition**; when the opponent does the matching
thing on *their* turn, the engine auto-resolves the Secret's effect *before* completing the
triggering action, then reveals + discards it. No priority pass, no opponent input required — the
server evaluates armed Secrets at each relevant step of the opponent's turn.

**This generalizes `counter/when_attacked`** from "a creature already on the board reacts to being
attacked" to "a hand-played card reacts to a chosen condition." Same evaluation seam, wider surface.

**New trigger conditions** (extend the existing `trigger_condition` enum):
`on_enemy_summon` · `on_enemy_attack` · `on_enemy_spell` (a spell-moment is cast) ·
`on_enemy_activated` (an activated ability fires) · `on_enemy_face_damage`.

**Schema.**
- New `zone` value `armed` on `ccg_match_cards` (alongside hand/field/graveyard). Armed cards are
  hidden from the opponent (RLS: the mig-147 spectator/opponent read must exclude `zone='armed'` —
  a Secret the enemy can see is worthless).
- `chit_type` gains `secret` (a third kind beside `creature`/`spell_moment`), or reuse
  `spell_moment` + a `is_secret` flag. **Recommend a distinct `secret` chit_type** — it reads
  clearly on the card face and in deck-building, and keeps targeting/resolution rules separate.
- A cap (e.g. **max 2 armed Secrets** per player) to bound evaluation + counterplay.
- `timing_type` gains `secret` (armed-until-triggered), or Secrets reuse `triggered` with the new
  conditions. **Recommend `timing_type='counter'` reused** (it already means "reacts"), plus the
  `armed` zone to distinguish hand-played Secrets from on-board `when_attacked` reactions.

**Resolver work** (`ccg_submit_turn` + a new `ccg_check_secrets(match, acting_seat, condition, ctx)`):
at each opponent action step (summon / attack / cast / activate / face-damage), call
`ccg_check_secrets` for the *defending* seat's armed cards matching the condition, resolve them in
armed order, emit `secret_reveal` + `effect` events, move them to graveyard.

**Family fit (identity matrix §1):** Secrets are a natural home for the reactive families —
**Actor** (P: shield_grant, already reactive), **Scientist** (control), **Comedian** (disruption).
Athlete/Musician/Influencer stay proactive (an intentional gap, like the anti-cycle in the framework).

---

## 2. Pillar B — the `negate` effect kind (counterspell)

**Depends on Pillar A.** Once Secrets exist, "counter/nullify a play" is just a new `effect_kind`
that a Secret resolves with: **`negate`** — cancel the triggering action and (per template) apply a
rider.

**Variants (all single-clause, ride Pillar A's trigger conditions):**
- *Counter a summon* (`on_enemy_summon` → `negate`): the summoned creature is destroyed as it
  enters (goes to graveyard, on-summon never fires).
- *Counter a spell* (`on_enemy_spell` → `negate`): the spell-moment is cancelled, no effect.
- *Silence-on-arrival* (softer): let the summon resolve but strip its effect/keywords (reuses the
  existing keyword machinery, not a true negate — a good "common"-rarity version).

**Resolver work:** `negate` needs the triggering action to be *interruptible* — i.e., Secrets are
checked *before* the action commits, and a `negate` verdict aborts it. This is the one place the
turn resolver's action loop changes shape (a pre-commit hook per action), so it's the highest-risk
item here — scope it once, reuse for all negate variants.

**Balance guardrail:** `negate` is `magnitude_scales=false` (it's binary), gated to mid+ tiers via
`min_tier_band` (hard counters shouldn't be F-tier commons), and belongs to **Scientist** (Primary
already = removal/control) and maybe **Comedian** (disruption) — never the proactive families.

---

## 3. Pillar C — charge-up / counter state (build a payoff)

**What it delivers:** "stack damage for a later turn," the framework's deferred **Combo** (Gamer)
and **Encore** (Musician) signatures (§7), and slow-burn value engines.

**Model.** A per-card integer **`charges`** column on `ccg_match_cards` (snapshot state, in-match
only — never persisted post-match, mirrors ArenaScore discipline). Two template hooks:
- **Accumulate:** a `triggered`/`start_of_turn` template adds N charges each turn (or on a
  condition, e.g. Combo = +1 per same-family card played this turn).
- **Release:** an `activated` (or `on_summon`) template spends charges, magnitude scaling with the
  charge count — the payoff. E.g. *Charge Up* (build) + *Unleash* (spend all charges as damage).

**Schema:** `ccg_match_cards.charges smallint default 0`; two template columns —
`charge_gain smallint` (per trigger) and `charge_spends boolean` (release reads+zeros charges into
magnitude). Both additive, both in-match only.

**Resolver work:** modest — increment on the trigger, and in `ccg_apply_effect` let a
charge-spending effect compute `magnitude = base × charges` (or similar) then reset. No turn-loop
change (unlike Pillar B), so this can land independently.

**Why it's not a third resource (framework §0 caution):** charges are **per-card bookkeeping**, not
a shared pool you spend across cards. Aura still answers "can I afford it," Vibe "is the crowd
hyped," charges just "has this specific card been building." Keep it that way.

---

## 4. Compound effects (Wave 2 prerequisite, shared with the library)

Pillars B and the richer Secrets want **multi-clause** templates ("negate AND draw," "shield self
AND damage attacker" — the framework's *Clutch Moment*). This is the same resolver extension the
Wave 2 library needs, so build it once, first:

- `effect_template_clauses` child table (or `secondary_effect_*` columns) — ordered clauses per
  template, each `kind × target × magnitude × scales`.
- `ccg_match_cards` snapshots the clause list (JSONB) instead of the three singular `snap_effect_*`.
- `ccg_apply_card_effect` loops clauses in order.
- `compose_chit_rules` joins clauses with " AND " / line breaks (already structured to extend).

Once this lands, `complexity=2` templates (already gated by `min_tier_band` from mig 151) become
authorable, and the reactive pillars can carry riders.

---

## 5. Recommended sequencing

| Wave | Deliverable | Turn-loop change? | Risk |
|---|---|---|---|
| **2a** | Compound-clause resolver (§4) + `complexity=2` library cards | no | med |
| **2b** | Charge-up state (Pillar C) — build/release cards, Combo/Encore signatures | no | low–med |
| **3a** | Secrets (Pillar A) — `armed` zone, new triggers, `ccg_check_secrets`, RLS hide | no (pre-commit reveal only) | med |
| **3b** | `negate` (Pillar B) — pre-commit interrupt hook | **yes** (action loop) | high |

Rationale: 2a/2b are additive engine work with no turn-structure risk and immediately deepen the
game. Secrets (3a) add the reactive dynamic without a priority system. `negate` (3b) is last because
it's the only piece that alters the action loop's commit semantics — isolate it so a bug can't
destabilize the whole resolver.

Each wave keeps the invariants: server-authoritative resolution, in-match-only combat state, single
Aura + Vibe economy, and effect power derived from tier (engagement), never from card text.

---

## 6. Open questions for the user

- **Secret chit_type vs flag** — distinct `secret` kind (clearer UX, recommended) or `spell_moment`
  + `is_secret`?
- **Secret cap** — 2 armed at once? (bounds evaluation + keeps counterplay readable)
- **How hard should `negate` be** — destroy-on-counter (hard) as the ceiling, with silence-on-arrival
  (soft) as the common? Which families may hold true negate (rec: Scientist only at launch)?
- **Charge-up flavor** — per-family signature (Gamer Combo / Musician Encore) first, or a generic
  build/release pair any family can access?
- **Do Secrets settle real-money `battle_outcome` markets differently** — a hidden card resolving a
  match introduces information asymmetry; confirm it's fine for monetized (KYC) matches or gate
  Secrets to non-monetized at launch (ties to G-MON).
