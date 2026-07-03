# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-03.
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
- **Migration ledger:** remote DB in sync at **145** (applied via `supabase db push`, 2026-07-03). Next
  new migration = **146**. 080–106 = redesign Docs 1–4 + integrity/chit/KYC. 107–113 = Licensing. 114/115 =
  mobile prep. 116–137 = v3 phases (116–121 asset layer · 122–125 tier ladder/effects/fusion · 126–129 CCG
  engine · 130–131 Vibe · 132–134 real-money rail · 135–136 minting + ascension · 137 fusion expansion).
  138–145 = cinematic/minting track (138 registries · 139 plates/prompts · 140 generation pipeline ·
  141 ingestion consent + pre-gen moderation · 142 one-active-card + wager escrow · 143/144 latent
  P3/P1 bug fixes surfaced by the wager smoke · 145 M-P5 glue: avatar_loadout / is_monetized / bet RPC).
- **`flutter analyze`:** clean as of the last redesign session.
- **v3 status:** P0–P6 BUILT + applied to prod; P7 partial (fusion expansion + balance pass, commit 6028765).
- **NEW TRACK (2026-07-02): Minting + Match Cut + Cinematic Engine** — see section below; specs
  `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md` + `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md`, contract in
  RECONCILIATION §7, Hard Rules 37–39. ← *current*

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

> **⏸️ SESSION CHECKPOINT — 2026-07-03 (Claude: read this first on resume).**
> **ALL build phases of this track are DONE** (Phase 0, C0–C3, M-P1, M-P4, M-P5) — migs 138–145
> applied to prod, `cinematic-mint` (swap flow) + `moment-ingest` deployed, every smoke PASSED
> (M-P1 ingest · M-P4 wager/swap · M-P5 loadout round-trip · C2 mint regression). What remains is
> EXTERNAL (below) + the next tracks in "Cross-cutting work" / v3 P7 launch hygiene.
> Full state in auto-memory `project_cinematic_engine.md`.
> Waiting on user: SEGMIND_API_KEY · TikTok/IG OAuth app creds (backend wired; `oauth-initiate`
> returns 503 for them until `TIKTOK_CLIENT_KEY`/`INSTAGRAM_CLIENT_ID` secrets are set; then flip
> `MINT_INGEST_MODE=live`) · ANTHROPIC_API_KEY as an edge secret + `MODERATION_MODE=live` for live
> vision moderation · visual sign-off on the 12 plates (then re-run
> `tools/cinematic/generate_anchor_plates.ts` live with FORCE=1 and flip rows to 'signed_off').
> Remove this note when the track completes.

## Minting + Match Cut + Cinematic Engine track (specs added 2026-07-02)

The web-side minting pipeline + the cutscene generation engine. Naming: the specs' `battle_chits` = our
`moment_chits` (RECONCILIATION §7). Vendor final: Seedance 2.0 via Segmind (fallback BytePlus ModelArk);
sim-first behind `CINEMATIC_MODE` per governance. Build order:

- [x] **C0 — Registries + tool wiring** (mig 138): `match_cut_templates` (6 role-keyed geometries),
      `match_cut_anchor_plates` + `match_cut_prompt_templates` (versioned), cinematic/minting columns on
      `moment_chits` + `moments`; Segmind client module (image + Seedance Fast/standard, seed capture,
      draft-vs-final config, sim mode); `battle-media` bucket; round-trip smoke test.
- [x] **C1 — Author plates + prompts** *(built; plate visual sign-off pending)*: 6 motion prompt templates (§4 grammar, style-lock fixed) seeded;
      12 anchor plates generated 16:9 house-style (**needs `SEGMIND_API_KEY`**); versions registered.
      **Gate: user visual sign-off against the Arena anchor poses before C2 finalization.**
- [x] **C2 — Generation pipeline** (mig 140 + `cinematic-mint`): classify→template select→illustration→Seedance cutscene (plate
      bookends, fixed seed)→post-gen moderation (reject → adjust `{SUBJECT_DESC}` only, re-run)→preview
      battle→store `battle-media`→write chit fields. End-to-end mint proof.
- [x] **M-P1 — OAuth consent + ingestion** (mig 141 + `moment-ingest`, 2026-07-03; TikTok/IG OAuth wired, creds pending): extend platform linking with TikTok + Instagram (**needs
      OAuth app credentials — external**; YouTube exists via `oauth-initiate`); ownership gate; oEmbed
      ingestion; pre-gen vision moderation (minor-safety absolute, Hard Rule 37).
- [x] **M-P4 — One-active-card + `wager_match`** (migs 142–144 + `cinematic-mint` swap flow, 2026-07-03):
      `self_mint_slot` limit + swap flow (old chit retired in the SAME tx as the new mint; media
      deleted only after; decks purged + invalidated); `ccg_wager_escrow` + `ccg_create_wager_match`
      + settle-on-finish transfer preserving `original_minter_handle`; abandoned matches return stakes.
- [x] **M-P5 — Integration glue** (mig 145, 2026-07-03): `profiles.avatar_loadout` (persist-only, own-update
      RLS round-trip verified); `is_monetized` on `ccg_matches` stamped per G-MON + `ccg_match_is_monetized`
      spectator read; `battle_place_spectator_bet_usd(p_match_id, p_team_number, p_amount_dollars)` wrapper
      over the mig-133 USD path (KYC/one-role enforced by the existing triggers).
- [x] **C3 — Contract mirror**: RECONCILIATION §7 kept current as each phase lands (updated through
      M-P5, 2026-07-03; keep mirroring as external gates unblock).

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
- [x] Onboarding walkthrough — SHIPPED 2026-07-03 (6-page welcome tour, once per user, re-openable from drawer).
- [ ] Profile avatars from connected platform data.
- [x] Launch-day animation — SHIPPED 2026-07-03 (countdown → midnight ET; breakaway + rocket cutscene
      `assets/video/launch_rocket.mp4` with built-in fallback; lands on /home). **User still owes the MP4.**
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

## PARKED pending counsel — card-value accrual economy (decision gate G-CARDVAL)

Founder idea (2026-07-03), captured for future exploration. **Do not build or describe on any
user-facing page until legal counsel clears it** — see the compliance analysis below.

**The idea.** A Market Maker minting a moment chit chooses a finite sale quantity (e.g. 100 copies)
and lists them on the marketplace. A defined slice of prediction-market rake on markets involving
that Market Maker (or on battles where the copies are played) **accrues into the cards themselves**,
so the finite supply appreciates over time. Holders can trade card-for-card value inside the internal
marketplace but cannot freely cash out; a non-Market-Maker's only cash-out path is collecting **all**
copies of one Market Maker's card (set-completion redemption). Wager matches feed this loop: the
match loser surrenders a card of the winner's choice (that pick UX lives in nora-arena).

**Why it's parked (from the 2026-07-03 review).**
- A collectible whose value is *designed* to appreciate from platform revenue, bought with an
  expectation of profit from others' efforts, walks directly into Howey/investment-contract
  territory — the exact thing the CLAUDE.md governance rule ("cards are collectible game assets,
  never financial instruments; never use investment/return/yield/dividend/revenue-share language")
  exists to avoid. Restricted redemption (set-completion cash-out) does not cure this; it may also
  add money-transmission exposure.
- Rake accruing *into* tradable cards mixes the token and USD economies (Hard Rule 33: battle
  markets settle USD, Markets settle tokens — never cross).
- Finite-supply multi-copy self-minting also conflicts with the shipped **one active self-minted
  chit per user** rule (M-P4); multi-copy supply currently exists only via the licensed premium
  pack rail (`lkn_*`).

**The safe adjacent path (already spec'd, partially built).** P5 payout routing: the rake slice pays
the **creator** (KYC-verified Market Maker) each time their moment is played in a monetized match —
recurring creator earnings, no holder appreciation promise. Holders get gameplay power, scarcity,
permanent minter attribution, and player-set marketplace pricing. Wager-match card forfeiture is
already built (mig 142).

**If G-CARDVAL is ever cleared, open design questions:** exact accrual formula and which markets
feed it; whether accrual attaches per-copy or per-definition; how set-completion redemption prices
out; interaction with ascension (value vs tier); anti-manipulation (wash-trading a card you also
rake into); and how any of it is disclosed without financial-instrument language.

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
