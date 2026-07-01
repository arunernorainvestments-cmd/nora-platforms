# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-01.
# Rules for HOW to build any of this live in CLAUDE.md ("Building future work safely").
# Full specs / schemas / history for anything referenced here live in ARCHIVE.md.
#
# ⚠️ v3 PIVOT (2026-07-01): the game is now the "Moments" card-battler. The canonical spec is
# NORA_PLATFORMS_BUILD_SPEC_v3.md; the phased tracker (P0–P7, repo-grounded) is
# NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md. The v2.x 1v1 archetype-fighter plan is RETIRED (bottom).

---

## Status snapshot (where we are, 2026-07-01)

- **Live & built (v2.x base, mostly reused by v3):** Markets, Hot Topic, Likeness Cards + stat sheets +
  card/chit marketplaces, celebrity integration, KYC flow, Emergency Fund (sim), Licensing Marketplace
  (backend + Flutter merged). Battle (1v1 turn-based, Phases A–C + matchmaking) + legacy Arena exist but
  are **superseded by the v3 card-battler** (see Retired).
- **Migration ledger:** remote DB at **115**. Next new migration = **116**. 080–106 = redesign Docs 1–4 +
  integrity/chit/KYC. 107–113 = Licensing. 114 = `profiles.fcm_token_mobile`. 115 = `mobile_iap_receipts`
  (on an UNMERGED branch `doc6-mobile-iap-confirm` — a v3 P5 live-flip prereq).
- **`flutter analyze`:** clean as of the last redesign session.
- **v3 status:** Phase 0 (docs) DONE. Phase 1 (asset layer) BUILT — migrations **116–121** written +
  self-reviewed + committed on branch `v3-p1-chit-asset-layer`, **not yet pushed to prod**. P2–P7 not started.
  (P1.6 physical archival deferred to P7 — mig 121 sets deprecation markers only.)

---

## v3 build plan — P0→P7 (detail + checklists in NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md)

Work in order; each phase = one atomic PR. `flutter analyze` zero issues before/after each. Migrations only
via `supabase db push`. Integer USD cents. Append-only ledgers INSERT-only. Honor every DO-NOT.

- **P0 — Canonical model + governance** (docs only). Rewrite CLAUDE/PLAN/RECONCILIATION/ARCHIVE to the
  card-battler; add Hard Rules 33–36; reconcile the moment-chit vs legacy-powerup naming. ← *current*
- **P1 — Chit catalog + collection + deck + barter.** `moment_chits` catalog (distinct from legacy
  `battle_chit_definitions`), `chit_ownership` + append-only acquisition ledger, `decks`/`deck_chits`
  (size 20 / max 2), `chit-barter` (KYC only on licensed-crossover swaps), premium packs on `lkn_*`.
  Archive `battle_abilities` move-sets; remove license-per-character eligibility.
- **P2 — Tier ladder + effects + fusion DATA** ⭐ *critical path.* `tier_ladder` (cost-banded) +
  `engagement_tier_thresholds`, `effect_templates` (family × timing, tier-scaled), timing types +
  keywords + families enumerated, `fusion_rules` (tag-based patterns + starter set), and the
  `(family,timing,tier)→(cost,atk,hp,effect)` derivation function.
- **P3 — CCG combat engine** (`process_battle_turn` rebuilt) — largest build. Board-state engine (Life/
  Aura/hand/deck/field ≤3/Vibe), turn resolution, fusion detection/resolution, match-start stat snapshot,
  ordered `battle_events` with `*_after` reconciliation.
- **P4 — Vibe Meter backend** (parallel w/ P3). `process_battle_vibe_tick` + `match_vibe` (no legacy
  dependency), multi-factor floored Vibe over Realtime; engine reads thresholds at round boundary.
- **P5 — Real-money rail + G-MON gating + payout.** `currency` on markets/bets + branched settlement
  (token→balances, USD→Treasury); market created **iff both players KYC'd**; rewrite `match_revenue_config`
  split routing creator/passive slices to **moment-owners of played chits**; wire Stripe Connect/Treasury
  behind config. **Live-flip prereqs:** merge `doc6-mobile-iap-confirm` (mig 115) + rotate
  `NORA_SIGNING_PRIVATE_KEY`.
- **P6 — Minting pipeline + tier-ascension.** link→recommend→animate→classify→tier-assign→moderate→mint
  (`moment_chits`); ascension job (weekly, ≤1/7d/user, one-directional, definition-level, between-matches
  only) + authenticity/moderation guards + large-jump review queue. *(Build mint before P5 payout wiring.)*
- **P7 — Fusion expansion + deprecation cleanup + Fund + launch hygiene.** Expand `fusion_rules`; execute
  the retirements below; weekly polls/multipliers → DORMANT; Emergency Fund live behind config; pre-launch
  reset (ARCHIVE §A8) + remove dev tooling; smoke tests.

**🚧 One open product call — G-MON:** real-money `battle_outcome` market created iff both players KYC'd;
royalty routes to moment-owners; licensed celeb chits premium; consent at mint, KYC at cash-out. Build the
gate; confirm the rule before real-money go-live.

---

## Cross-cutting work that survives v3 (not phase-specific)

### Licensing Marketplace (Doc 5) — remaining
- [ ] **Gateway routing**: point `GET api.noraplatforms.com/v1/verify` at deployed `lkn-verify` (Cloudflare
      route or Vercel rewrite → `…functions.supabase.co/lkn-verify`). Unblocks mobile License Sync. Runbook in ARCHIVE.
- [ ] **`lkn-generate-contract`**: needs the attorney-seeded `lkn_contract_clauses` table (not yet created).
      Do NOT fabricate legal language (Hard Rule 30). Deferred until clause library exists.
- [ ] **Signing-key rotation** (also a v3 P5 prereq): current `NORA_SIGNING_PRIVATE_KEY` works but is
      known-compromised (generated in a Codespace). Regenerate on a local secure machine, update the secret +
      `.well-known/nora-public-key.pem`, before live launch.
- [ ] Featured/paid listing placement (post-launch).

### Mobile app (nora-arena, separate repo) — surviving items
Backend prep in THIS repo is done (mig 114 + four `nora-arena-api-*` wrappers + `mobile_iap_confirm`).
nora-arena has pivoted Flutter+Flame → **Unity (C#) + Meshy 3D**; launch target is mobile (WebGL is
inspection-only). Cross-repo contract: **RECONCILIATION.md**.
- [ ] **Merge `doc6-mobile-iap-confirm`** (commit ee5a782: `mobile_iap_confirm` + mig 115) — also a v3 P5 prereq.
- [ ] Gateway routing for `api.noraplatforms.com/v1/verify` (shared blocker with Licensing above).
- [ ] FCM push (battle invites, bet resolution) using `profiles.fcm_token_mobile`.
- [ ] RevenueCat IAP config (token packs / chit packs) → `mobile_iap_confirm`.
- [ ] Native iOS/Android shells, store submissions, deep links from web.
- [ ] The v3 CCG contract (moment-chit catalog, tier exposure, CCG `battle_events`, market gating,
      minting/ascension, fusion) replaces the old character-select contract — mirrored in RECONCILIATION.

### nora-arena reconciliation — platform-side decisions that survive v3
- [ ] **R1 — Archetype vocabulary.** Still relevant: archetype **families** are the v3 effect-family
      classifier. Fix `get_eligible_characters` self-branch to emit a battle archetype; expose the resolved
      archetype/family on `lkn_public_registry`; publish the `category_1 → archetype` map. (Client deletes its alias table.)
- [ ] **R3 — Canonical spectator-bet path.** v3 settles battle markets via `bets` on `battle_outcome`
      `markets` (the web/redesign path), now in **USD**. Point mobile at this path; deprecate the legacy
      `battle_place_spectator_bet`/`battle_spectator_bets` (mig 062). **Until the mobile cutover ships, do
      NOT delete the legacy 062 table/RPC.**
- **R2 is RETIRED by v3** — see Retired (license-per-character eligibility is removed; eligibility = own chits + legal deck).

### Slice 2 — test-account filter sweep
Systematic grep of `is_market_maker` / `is_test_account` across all providers to guarantee no test accounts
leak into ranking/discovery (Hard Rule 15). Tracked separately (Rule 22).

### Pre-launch polish (before July 4 2026)
- [ ] Celebrity profile pictures — `celebs.image_url` NULL for all 25 (UI falls back to initials).
- [ ] Onboarding walkthrough (4–5 slide PageView).
- [ ] Profile avatars from connected platform data.
- [ ] Marketing campaign + launch-day animation.
- [ ] Run the **pre-launch reset sequence** + remove all dev tooling (ARCHIVE §A8) — folded into v3 P7.

---

## RETIRED by the v3 pivot (do not resume; schemas archived-not-dropped in P7)

The v2.x 1v1 archetype-fighter model and its queued work are superseded by the card-battler. Kept here for
provenance; the retired schemas live under ARCHIVE §A3/§A4/§B (archived, never DROPped — v3 P7 executes the archival).

- **~~Next task: Battle bot-fill for solo testing~~** — the 1v1/2v2/3v3 matchmaking loop it served is replaced
  by the CCG engine (P3). Bot-fill, if needed, is re-scoped to the new engine.
- **~~Battle Phase D~~** (map affinity multiplier, type-chart/speed balance, `battle_match_telemetry`
  status-effects wiring, SpriteMaster/Flame schema) — the whole 6-player sprite Battle is retired.
- **~~Battle Chits (powerup) remaining~~** — `aura`/live-combat-screen/acquisition/bench-target UX for the
  legacy `battle_chit_definitions` powerups. Powerup chits are dormant (Hard Rule 27); the v3 "moment chit"
  is a different asset (P1).
- **~~R2 — license → battle eligibility~~** — v3 removes license-per-character eligibility entirely;
  eligibility is "own moment chits + legal deck." No longer a decision.
- **D&D six-stat characters / per-archetype move-sets (`battle_abilities`) / parody-celebrity avatars** —
  deprecated; celebrities return as licensed premium chits (P1). Stat sheets survive but are cosmetic.

---

## Long-horizon vision (post-launch, not scoped)
- **On-chain / NORA coin**: append-only ledgers (`likeness_card_transfers`, `lkn_agreements`, the new
  `chit_ownership` acquisition ledger, and archived `campaigns_archived_ledger`) are designed to migrate to
  on-chain settlement. Integer-cents, no floats, every ownership change a new row. Full migration path +
  original Campaigns royalty/Reg CF framework preserved in ARCHIVE.
- **Revenue data partnerships** (Spotify for Artists, YouTube Analytics, DistroKid/TuneCore) — the layered
  verification roadmap still informs licensing revenue-share and could feed engagement-tier signals for minting.
- **Battle V2 (Unity)** — the mobile client is already Unity; the Supabase data layer is engine-agnostic so
  the CCG engine (P3) drives both web and Unity clients from the same `battle_events` stream.
