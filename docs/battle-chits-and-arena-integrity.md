# Battle Chits & Arena Integrity — Spec
# Last updated: 2026-06-08
# Status: framework migrations 102–103 applied; combat hooks for `counter`/`type_override` deferred (see §6)

This spec captures the continuity decisions made when Arena was repurposed from a
standalone live game into the **spectator + prediction-market surface over Battle
matches**, and defines the Battle Chit framework that supersedes the legacy Arena
powerup catalog. It is the authoritative design reference for the chit economy and
for the market-integrity rules. Animation production (Antigravity / nano-banana) keys
off the `animation_key` values defined here.

---

## 1. Continuity: the two "Arenas"

The word **Arena** has pointed at two architecturally distinct systems:

**Legacy Arena** (migrations 029–056, `arena_match_screen.dart`)
- Creator-vs-creator live 5-min 1v1. `ArenaScore` in-memory per tick (Hard Rule 18).
- Audience does two things on a live match:
  - `arena_back` → stake tokens on a creator, paid `arena_win`. **A wager.**
  - `arena_trigger` → spend tokens to fire an archetype ability that writes to
    `arena_state.active_effects` and changes the live score. **An influence powerup.**
- The powerups that still live here: the whole `arena_abilities` catalog
  (per-archetype `passive/core/signature/ultimate`) + the special-action mechanics
  in `arena_trigger` v3 (Debate lockout, replay_value, reset_baseline, convert_flow,
  miracle, monopoly_ceiling, revival).

**Redesigned Arena** (migrations 091/100/101, `arena_screen.dart` `_LiveBattlesSection`)
- Arena is the **spectator + prediction-market surface over Battle matches**.
  Spectators *Watch* and *Back a team* via `battle_bet_sheet` → a `bets` row →
  `markets` with `resolution_type='battle_outcome'`.
- The combatants are the 6 Battle players fielding likeness cards. They influence the
  match with **Battle Chits** (`battle_use_chit` → `battle_participant_status_effects`).

Both coexist on `/arena` today. The redesign is the forward path; legacy Arena's
audience-influence model is incompatible with a prediction market and is being walled
off (§3).

---

## 2. The core invariant — one role per match

> Buying powerful chits must not let a spectator who has a market stake swing the
> match they bet on. Players (combatants) use chits; spectators only wager.

For any match with an open `battle_outcome` market, a verified human is exactly one of:

| Role | May use chits? | May bet on this match? |
|------|----------------|------------------------|
| **Combatant** (fields a character) | ✅ yes | ❌ no |
| **Spectator** | ❌ no | ✅ yes (Back a team) |

This is symmetric and enforced at the **database layer**, not the UI:

1. **Bet path** (`bets` BEFORE INSERT, migration 102): rejects a bet on a
   `battle_outcome` market if the bettor — *or any KYC-linked alt* — is a combatant
   in the linked match.
2. **Chit path** (`battle_use_chit`, migration 103): already participant-gated
   (`auth.uid()` must own the participant); additionally rejects use if the caller —
   or a KYC-linked alt — holds an active bet on the linked market (defense in depth).
3. **Legacy Arena** (`arena_events` BEFORE INSERT, migration 102): a user who has a
   `back` event on a match cannot insert a `trigger` event on it, and vice versa.
   This retires the legacy audience-influence-while-staked dynamic without rewriting
   the large `arena_trigger`/`arena_back` functions.

---

## 3. Bridging the catalogs

`battle_chit_definitions` (086) is the **successor** to `arena_abilities`. Most arena
ability concepts already have a chit equivalent, so the bridge is consolidation +
deprecation, not a rebuild.

| Arena ability concept | Battle Chit equivalent |
|-----------------------|------------------------|
| Defense (−opponent efficiency) | `damage_shield` (Bronze/Silver Shield) |
| Sprint / Clutch (flow surge) | `momentum_surge` (Momentum Crystal) |
| stat ramp | `stat_boost` (Power Surge), `aura` (NORA Aura, Charisma Aura) |
| Counter Stance | `counter` (Counter Stance) |
| Type Breaker | `type_override` (Type Breaker) |
| Disruptor | `disruption` (Disruptor) |
| Game Winner (once-per-match ultimate) | `legendary`/`mythic` chits, `per_match_use_limit = 1` |

Delivery model differs and is intentional:

| | `arena_abilities` (legacy) | Battle Chits (canonical) |
|---|---|---|
| Acquired | bought with tokens *at point of use*, repeatable | owned collectible, consumed from inventory |
| Used by | audience + creators | **players only** |
| Duration | seconds (real-time tick) | **turns** (turn-based) |
| Influence + wager | same hands (the problem) | separated by §2 |

`arena_abilities` / `arena_trigger` are **legacy-only**. New powerup design happens in
`battle_chit_definitions`. Do not extend the arena ability catalog.

---

## 4. KYC backstop

The §2 invariant is only as strong as account uniqueness — free alts defeat it. KYC
(`kyc_verifications`, Stripe Identity in live mode, `kyc_simulate_approve` in sim)
provides the identity anchor.

- **`identity_hash`** (migration 102): a one-way SHA-256 of the verified, normalized
  `first_name|last_name|dob` (Stripe Identity does not expose raw document numbers),
  stored on the KYC row with a **partial UNIQUE index** over approved rows → one
  verified human → one staking identity. Populated by `stripe-webhook` on the
  `identity.verification_session.verified` event; a second account verifying the same
  identity hits the unique index and is marked `rejected`. Sim mode leaves it NULL.
- **`identity_linked_users(uuid)`**: returns every account sharing an approved
  `identity_hash` with a user (plus self); the §2 guards call it.
- **How alt-resistance actually holds (important nuance):** because the unique index
  permits only ONE *approved* account per `identity_hash`, a human cannot have two
  stakeable accounts. In live mode both *betting* and *being a combatant* require
  approved KYC (`require_kyc_for_staking` + `require_kyc_for_combatant`), so the same
  human's single approved account is either combatant or bettor — the second account
  can't get approved (unique violation) and an unapproved account can't stake. The real
  protection is therefore **unique index + dual KYC gates**; `identity_linked_users`
  resolves to a single account under uniqueness and is belt-and-suspenders, not the
  primary mechanism. In sim mode (gates off) alts are not blocked — acceptable because
  no real money is at stake.
- **Gating flags** (`platform_integrity_settings`, singleton):
  - `enforce_one_role_per_match` — default **TRUE** (integrity rule, money-independent).
  - `require_kyc_for_staking` — default **FALSE**; flip TRUE at live launch to require
    approved KYC before any bet.
  - `require_kyc_for_combatant` — default **FALSE**; flip TRUE at live launch to
    require approved KYC before being fielded as a combatant.
- **Free wagering-compliance bonuses** from the same table: `date_of_birth` → 18+/21+
  gate; `verified_address_country` → jurisdiction geo-restriction. Wire these into the
  staking gate at live launch.

Tiering: sim-mode free play stays open (flags FALSE). KYC bites only at the staking
boundary in live mode. This matches the existing sim-vs-live split (Stripe Treasury,
marketplace).

---

## 5. Battle Chit framework

### Catalog (`battle_chit_definitions`, 086 + 103 columns)

Per-chit fields driving gameplay and animation:

- `effect_type` — one of `stat_boost, damage_shield, momentum_surge, counter,
  type_override, speed_burst, aura, disruption, wild_card`.
- `effect_value`, `effect_target` (`self`/`opponent`/`all`), `effect_duration_turns`,
  `stat_target`.
- `rarity` — `common → mythic`; drives acquisition + `per_match_use_limit`.
- **`animation_key`** (103) — explicit per-chit key, e.g. `chit_bronze_shield`. This is
  what animation production builds assets against. The `chit_used` battle_event carries
  it for the client to play.
- **`requires_target`** (103) — TRUE for `disruption` (pick opponent) and `wild_card`
  (pick bench ally). UI must collect a target participant before calling the RPC.
- **`per_match_use_limit`** (103) — NULL = limited only by inventory; `1` for
  legendary/mythic (the "ultimate" tier).

### Acquisition
- `challenge_reward` (common+), `match_rng` drop on win (rare+, live in
  `process_battle_turn`), `marketplace_purchase` (uncommon+, `can_buy_in_marketplace`),
  `gift`/`event` (epic+).

### Usage — `battle_use_chit(match, participant, chit_def, target?)` (103)
1. Caller must own the participant (`auth.uid()`).
2. **Integrity:** caller (or KYC-linked alt) must not hold an active bet on the linked
   market (§2.2).
3. **Caps:** one chit per participant per turn; per-chit `per_match_use_limit` per match.
4. Decrement inventory; record in `battle_chit_uses` ledger; emit `chit_used` event with
   `animation_key`.

### Effect resolution
- **Immediate at use-time** (no turn-loop dependency):
  - `momentum_surge` → `momentum += value`.
  - `stat_boost` → `snap_<stat_target> += value` (whole-match; snap_* persists).
  - `aura` → `snap_<stat>` (or all) `× value` (whole-match).
  - `disruption` → delete one random active effect on the target opponent.
  - `wild_card` → immediate swap to a chosen bench ally, bypassing swap rules.
- **Duration effects mapped onto types `process_battle_turn` already resolves:**
  - `damage_shield` → stored as `save_state` (blocks an incoming hit ≤ shield value,
    consumed). v1 approximation of "absorb N"; refine when the dedicated absorb hook
    lands (§6).
  - `speed_burst` → stored as `speed_debuff` with a **positive** `effect_value` (the
    turn-order CTE sums it, so positive = faster).
- **Deferred mechanical hooks** (stored with their own effect_type, currently expire
  harmlessly; the `chit_used` animation still plays):
  - `counter`, `type_override` — see §6.

---

## 6. Known gaps / build checklist

- [x] **`counter` + `type_override` combat hooks** in `process_battle_turn` (migration
      106) — counter reflects dealt damage to the attacker (+ attacker faint/forced-swap
      handling); type_override floors the type multiplier at 1.0 (ignores disadvantage).
      Source pulled via `pg_get_functiondef` and edited surgically; validated in a
      rolled-back turn (all three effects consumed, `counter_reflect` event emitted).
- [x] **`damage_shield` true absorb** (migration 106) — absorbs up to `effect_value`,
      carries the remainder, consumes when depleted. `battle_use_chit` now stores
      `damage_shield` under its own type (was approximated as `save_state`).
- [x] **Stripe Identity `identity_hash` population** — `stripe-webhook` handles
      `identity.verification_session.verified`: SHA-256 of normalized name+DOB →
      `kyc_verifications.identity_hash`; 23505 collision → account marked `rejected`.
- [x] **Client KYC flow** — `kyc-create-session` edge function (sim: `kyc_simulate_approve`;
      live: Stripe Identity `VerificationSession` w/ `metadata.user_id` + pending row +
      hosted-flow redirect, gated by `KYC_MODE` env). Flutter `kyc` module
      (`myKycProvider`, `KycService`, `/verify-identity` screen) + "Verify identity" CTA on
      the bet sheet's KYC error. Mode flip for live: set `KYC_MODE=live`, `STRIPE_SECRET_KEY`,
      `platform_integrity_settings.require_kyc_for_staking=true`.
- [ ] **`aura` on charisma/influence** — these stats are not yet in the damage formula,
      so the multiplier is currently future-proofing only. Wire when stat coverage expands.
- [ ] **Live combat screen** — `battle_match_screen.dart` is still a `test-match`
      placeholder; the chit inventory sheet is wired and ready but only calls the RPC in a
      real match context.
- [ ] **Acquisition flows** — challenge/pack/gift paths are scaffold-only; only
      `match_rng` is live.
- [ ] **Bench/target UX** — `wild_card`/`disruption` target pickers exist in `ChitSheet`;
      wire them into the live combat menu when the combat screen lands.

## Hard rules added (see CLAUDE.md)
- Battle Chits are the canonical powerup system; `arena_abilities`/`arena_trigger` are
  legacy-only — do not extend them.
- Combatant ≠ bettor on the same match; enforced at the DB layer across KYC-linked alts.
- Chit usage is participant-only and blocked while the caller holds a stake on the
  linked market.
