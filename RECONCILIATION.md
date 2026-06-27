# Cross-Repo Reconciliation — nora-platforms ↔ nora-arena
# The backend/platform side of the contract. Last updated: 2026-06-27.
#
# Pairs 1:1 with nora-arena/RECONCILIATION.md (the client side). nora-arena is the
# Arena/Battle mobile app — a SEPARATE GitHub repo (arunernorainvestments-cmd/nora-arena,
# private) that shares THIS Supabase backend + licensing API. This file records what that
# client consumes from us, the open decisions it has handed to us, and discrepancies WE
# found that its own reconciliation log hasn't flagged. Append; don't silently rewrite —
# strike resolved items with a date.
#
# Legend: 🔴 needs a nora-platforms decision/change · 🟡 confirm / keep-in-sync · 🟢 FYI
# Backbone rule: nora-arena is frontend-only. It NEVER changes our DB, edge functions, or
# cron. If a contract must change, it changes here. (Its CLAUDE.md Hard Rules 2/3.)

---

## 0. nora-arena state as of this review (2026-06-27)

- **Repo exists** and is ahead of the `nora-arena/` scaffold embedded in this repo
  (pushed 2026-06-26, ~135 MB). The embedded scaffold is now stale vs the standalone repo.
- **Engine pivot: Flutter+Flame → Unity (C#) + Meshy 3D.** Unity 6000.0.32f1, IL2CPP, URP;
  `supabase-csharp` 1.1.1 vendored as DLLs; RevenueCat Unity + Firebase Unity (FCM) planned.
  The Flutter `lib/` is retained as legacy until each C# port lands, then removed.
- **Progress:** Phase 0 (docs) ✅, Phase 1 (Unity skeleton + C# backend bridge) ✅,
  Phase 2 (auth + session persistence + `battle_events` Realtime subscriber) ✅ on branch
  `phase-2-auth-realtime`. Phase 3 (character pipeline) IN PROGRESS — one archetype mesh
  (`gamer`) + 6 animations + a 3D playground render in a WebGL build on GitHub Pages; 9
  remaining meshes pending a Meshy key; animation clips are placeholders. Phases 4 (battle
  scene) + 5 (live markets) not started.
- **WebGL is an inspection/render tool only** — `supabase-csharp` uses `System.Net.Http` +
  `System.Net.WebSockets`, which have no Unity WebGL backend, so auth/realtime run only on
  iOS/Android IL2CPP, the Unity Editor, or via `tooling/terminal-login.sh`. **Launch target
  is mobile**, not WebGL.
- **Backend impact of all the above: none claimed** — same project `cceisywxwhgljdpisjrl`,
  same anon/publishable key, same contracts. This file is where we verify that claim.

---

## 1. What nora-arena consumes from this backend (freeze / notify-on-change)

Changing any of these without telling nora-arena will break the client. Treat as a
published contract.

| Contract | Where | Notes |
|---|---|---|
| `lkn-verify` REST — list mode `?licensee_nora_id=&use_category=entertainment_game` (JSON array) | functions/lkn-verify | ✓ verified: Mode A returns the array shape the client parses |
| `lkn-verify` REST — single signed mode `?license_id=&use_category=` (incl. `record_hash`, `signature`) | functions/lkn-verify | client will do **offline ECDSA P-256 verify** against the published public key |
| `X-NORA-API-Key` auth + per-key daily rate limit (Hard Rules 31) | functions/lkn-verify | client holds a per-app key from `lkn-register-api-key` |
| `lkn_public_registry` read (licensor_display_name, licensor_image_url, listing_category) | mig 113, public-read RLS ✓ | display assets, no PII |
| `creator_stat_sheets` read (6 base + 6 effective + weekly_poll_multiplier) | mig 080, public-read RLS ✓ | **cosmetic-only in battle** (their RECONCILIATION #5) |
| `battle_participants`, `battle_matches`, `battle_spectator_bets` reads | mig 060/062/083 | see §R3 — betting path |
| `battle_events` Realtime (replay ordered by turn_number, sequence_in_turn) | — | client is **display-only / server-authoritative** |
| RPC `battle_place_spectator_bet(p_match_id, p_team_number, p_tokens_wagered)` | mig 062 | **see §R3 — this is the legacy path** |
| RPC `check_battle_eligibility(p_user_id, p_creator_id)`, `get_eligible_characters(p_user_id)`, `battle_get_archetype_speed(...)` | mig 082/083/062 | see §R1, §R2 |
| `nora-arena-api-token-balance` / `nora-arena-api-market` | mig 114 era | bet-sheet convenience fns (deployed) |
| `mobile_iap_confirm(product_id, purchase_token)` + `mobile_iap_receipts` idempotency | mig 115 (branch) | RevenueCat → token grant; same `token_transactions` |
| `profiles.fcm_token_mobile` | mig 114 | push token sink |
| Shared models (`// SHARED MODEL`): BattleEvent, BattleParticipant, BattleMatch, BattleSpectatorBet, StatSheet, UnlockedCharacter, VerifiedLicense | — | keep JSON keys identical on any column change |

---

## 2. Open reconciliation items (decisions / changes that live HERE)

### 🔴 R1 — Archetype vocabulary drift (their RECONCILIATION #1; filed as issue nora-platforms#2)
We disagree with ourselves on the archetype set:
- **Battle set (canonical):** athlete · musician · business · comedian · artist · gamer ·
  influencer · scientist · politician · actor — enforced by `likeness_offerings.archetype`
  CHECK (mig 081), `battle_abilities.archetype`, `battle_type_chart`, `battle_get_archetype_speed`.
- **Category set:** `profiles.category_1` (mig 024) adds healthcare/performer/educator/religion
  and `get_eligible_characters` returns raw `LOWER(category_1)` for the self-branch.
- **Impact:** functional, not cosmetic. A self-fielded creator with `category_1='healthcare'`
  resolves to an archetype with **no `battle_type_chart` row and no abilities** → default
  speed, 1.0 damage, effectively unplayable. (Owned cards are safe — they carry a valid
  `likeness_offerings.archetype`.)
- **nora-arena's stopgap:** a client-side alias map (healthcare→scientist, educator→scientist,
  performer→actor, religion→politician, unknown→influencer) in `BattleArchetypes.cs`.
- **Our action (recommended):** (a) confirm the battle set is canonical [it is];
  (b) fix the `get_eligible_characters` self-branch to emit a battle archetype, not raw
  `category_1`; (c) **expose the resolved battle archetype in `lkn_public_registry`** (the
  client import path only sees `listing_category` today) so the client deletes its alias map;
  (d) publish the official `category_1 → archetype` map. → add to PLAN.md.

### 🔴 R2 — License → battle eligibility gap (WE found this; NOT in their reconciliation)
The whole mobile thesis is "buy a likeness **license** → play that character." But battle
entry as built gates on **likeness CARDS, not licenses**:
- `check_battle_eligibility` (mig 083) and `battle_enqueue`/matchmaking (mig 101) accept a
  fighter only if the user owns a `likeness_cards` row for that creator (or IS the creator).
  They reference `likeness_cards`/`likeness_offerings` only — **never `lkn_agreements`/licenses.**
- `lkn-verify` (the licensing marketplace, mig 108–113) is a **separate** ownership system from
  likeness cards (mig 080–082). A `lkn-purchase-license` creates an `lkn_agreements` row, **not**
  a card. So a user who bought a license but owns no card passes `lkn-verify` (mobile unlocks
  the character in the UI) and is then **rejected by `check_battle_eligibility`/`battle_enqueue`**
  at battle entry. The license→combatant loop does not close.
- This doesn't bite yet (mobile has only built license-sync + spectator; the combatant/
  matchmaking flow is Phase 4+), but it must be settled before that flow ships.
- **Our decision needed (recommended option a):** (a) extend `check_battle_eligibility` /
  `battle_enqueue` to also accept an active `entertainment_game` license (join `lkn_agreements`),
  making licenses first-class battle keys; or (b) auto-issue a battle entitlement when a
  game-use license is purchased; or (c) explicitly scope mobile to card-based fielding and treat
  licenses as spectator/registry only (contradicts doc6). → add to PLAN.md.

### 🔴 R3 — Spectator betting path divergence (WE found this; NOT in their reconciliation)
Mobile bets through the **legacy** path; the web redesign uses a **different** one:
- **Mobile (both Dart + C# `SpectatorMarketService`)** calls
  `battle_place_spectator_bet(p_match_id, p_team_number, p_tokens_wagered)` and reads
  `battle_spectator_bets` + `battle_matches.spectator_pool` (migration **062**).
- **Web redesign** routes battle betting through a `bets` row on a `markets` row with
  `resolution_type='battle_outcome'` (team_1/team_2 positions, mig **100**, `battle_bet_sheet`),
  settled by `distribute_match_revenue`. Our own scoring spec (now ARCHIVE.md §A1) flags
  `battle_spectator_bets`/`spectator_pool` as **legacy, unused by the redesign, cleanup candidate.**
- **Two problems:** (1) mobile and web would write to **different pools for the same match** →
  inconsistent odds/payouts; (2) if we ever drop the legacy 062 table/RPC, **mobile breaks.**
- **Our decision needed:** either (a) keep `battle_place_spectator_bet` alive and decide it is the
  canonical mobile bet path (and ensure it actually settles), or (b) point mobile at the redesign
  `bets`/`battle_outcome` path (the web path) and deprecate the legacy one for both. Until decided,
  **do NOT delete the legacy 062 spectator-bet table/RPC.** → add to PLAN.md.

### 🟡 R4 — `lkn_public_registry.listing_category` value domain
Mobile builds the character archetype from `listing_category` (lowercased, matched to the battle
set, unknown→influencer). Unclear whether that column holds battle archetypes, `category_1`
values, or free-form marketplace categories. **Action:** confirm the domain; ideally resolve via
R1(c) by exposing a real `archetype` column on the registry row.

### 🟡 R5 — `lkn-verify` contract stability + signing + gateway
- Confirm the §1 fields (esp. signed-mode `record_hash`/`signature` and that
  `use_category_permitted` reflects `entertainment_game`) are **stable** — the client will
  hard-depend on offline signature verification.
- Confirm `use_category` stays `entertainment_game` for Arena despite the real-money market layer.
- **Open in PLAN.md already:** the `api.noraplatforms.com/v1/verify` gateway route isn't live
  (client falls back to the direct `…functions.supabase.co/lkn-verify` URL), and the signing key
  is known-compromised (rotate before live so offline verify is trustworthy).

### 🟡 R6 — `arena-character-cache` Storage bucket — DEFERRED
The per-creator generated-likeness pipeline would want a public `arena-character-cache` bucket
keyed by `licensor_nora_id`. **Deferred at launch** — mobile ships generic archetype meshes with
name/portrait/stat personalization, so no per-creator asset is needed yet. Create the bucket
only when the "realistic likeness" pipeline ships. No action now.

### 🟢 R7 — Stale-doc heads-up they filed (now addressed here)
nora-arena flagged that our old `docs/infra.md` omitted the `lkn-*`, `nora-arena-api-*`, and
`mobile_iap_confirm` functions, and that `docs/battle-spec.md`'s archetype list diverged from
`category_1`. Those docs have since been **consolidated into ARCHIVE.md** (infra → §A2 now lists
all three function families; battle archetypes → §A3, with the divergence captured in R1 above).
The standalone repo's links to `docs/…` and `nora_redesign_doc6_…` are now stale — content moved
to ARCHIVE.md §A3/§A4/§B5. FYI for when nora-arena next syncs its pointers.

---

## 3. Answers we owe nora-arena (their UNITY_MIGRATION_HANDOFF §4 / §8)
- ✅ Battle archetype set is canonical (R1). We will also do R1(b/c/d) — tracked in PLAN.md.
- ✅ `battle_place_spectator_bet` signature is `(p_match_id, p_team_number, p_tokens_wagered)`
  (mig 062) — **but** see R3: that path is legacy here; expect a follow-up on the canonical bet path.
- ❓ R2 (license vs card eligibility) — our decision pending; this is the biggest blocker for the
  combatant flow.
- ▢ R5 — confirm `lkn-verify` shape stability + `entertainment_game`; gateway + key rotation in PLAN.md.
- ✅ Auth/session sharing unchanged (same project + anon key); no auth migration planned.

## 4. Verdict
The data contract is sound and what's built (license sync, spectator realtime) connects to the
real backend. **Three platform-side decisions gate the rest:** R1 (archetype exposure — easy win),
R2 (license→battle eligibility — the headline integration), R3 (which spectator-bet path is
canonical — and don't delete the legacy table until decided). All three are backend work that
lives here; their actionable forms should be mirrored into PLAN.md.

## 5. Pointers
- Client side of this contract: `nora-arena/RECONCILIATION.md` + `UNITY_MIGRATION_HANDOFF.md` + `STATUS.md`.
- Our backend reference: ARCHIVE.md (§A1 scoring/DB, §A2 infra, §A3 battle, §A4 chits/integrity, §B5 doc6).
- Our forward work: PLAN.md (R1–R3 + gateway/key-rotation belong there as concrete tasks).
