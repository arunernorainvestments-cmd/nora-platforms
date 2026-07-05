# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-05.
# Rules for HOW to build any of this live in CLAUDE.md ("Building future work safely").
# Full specs / schemas / build history for anything referenced here live in ARCHIVE.md.
#
# ⚠️ v3 PIVOT (2026-07-01): the game is the "Moments" card-battler. Canonical spec:
# NORA_PLATFORMS_BUILD_SPEC_v3.md; phased tracker (P0–P7): NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md.
# The v2.x 1v1 archetype-fighter plan is RETIRED (bottom).

---

## Status snapshot (where we are, 2026-07-05)

- **Live & built (v2.x base, reused by v3):** Markets, Hot Topic, Likeness Cards + stat sheets +
  marketplaces, celebrity integration, KYC flow, Emergency Fund (sim), Licensing Marketplace (backend +
  Flutter). Legacy 1v1 Battle + Arena exist but are **superseded by the v3 card-battler** (see Retired).
- **v3 card-battler:** P0–P6 BUILT + applied to prod (migs 116–137); the CCG engine, tier ladder, effects,
  fusion, Vibe, real-money rail, minting + ascension all live. P7 (launch hygiene) partial.
- **Mint pipeline is now END-TO-END** (2026-07-02→05, migs 138–152 — full build history in ARCHIVE
  "2026-07-02→05"): `/mint` post-verify → device-clip trim → moderation → **classify + effect selection**
  → generate (sim) → **web Preview (CardFace with real rules/flavor/serial)** → finalize → `/collection`.
  Cards now carry a **real, balanced, printable effect** selected from the authored library. Cancel/discard
  works; sim-mode media shows honest placeholders. Cloud Run stitch worker (`nora-stitch`) live for §4.
- **Migration ledger:** remote DB in sync at **152** (via `supabase db push`). Next = **153**.
  138–147 cinematic/minting-v2 · 148 chit display fields · 149 `{VIDEO_DESC}` · 150 mint-cancel ·
  151 effect-library framework cols + derivation · 152 Wave-1 template seed (10 families × 3).
- **`flutter analyze` / `deno check`:** clean (2026-07-05).
- **Config flags:** `MINT_INGEST_MODE=live` · `MOMENT_CLASSIFY_MODE=sim` · `CINEMATIC_MODE=sim` ·
  `MODERATION_MODE=sim` · `MINT_CLIP_MODE=sim` · `SEGMIND_API_KEY` set · TikTok **sandbox** creds · IG none.
  Flipping any to live is a spend/creds/G-MON decision (below).

**Two active build tracks are next — see "Where we're going next."**

---

## Where we're going next

### Track A — Minting v2 §2–§4: the generation back half  ⟵ *needs `CINEMATIC_MODE=live` + Segmind spend*
Governing doc: `Minting_Workflow.md` (device-clip pivot, wins on conflict) + `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md`
§4 grammar/moderation. Everything is buildable **sim-first**; the Segmind key only unlocks real renders.
The seam is bracketed by **two character-AGNOSTIC anchor plates** (Hard Rule 39; Unity supplies lead-in variety).

- [ ] **§2 V2V stylization**: attached clip (`clip_status='attached'`) → Wan-class video-to-video via Segmind
      (`runway-gen4-aleph` is the audited candidate) → cel-shaded `Core_Clip.mp4`. Prompt = frame-derived
      `{SUBJECT_DESC}` + the persisted `{VIDEO_DESC}` (mig 149, V2V core ONLY — never the bridges) + the house
      style-lock block (never user-influenced). Persist seeds/versions per stage on `cinematic_generations`.
- [ ] **§3 Bridges**: Intro (Kling-class I2V: `image`=agnostic START plate, `image_tail`=Core frame 0) + Outro
      (`image`=Core last frame, `image_tail`=agnostic END plate), ~1.5s each (gen 5s, trim), seeded.
- [ ] **§4 Stitch + audio dub**: concat Intro+Core+Outro via the **Cloud Run `nora-stitch` worker** (live);
      overlay ORIGINAL clip audio on the middle only, honoring `clip_keep_audio`. Audio-licensing exposure is an
      accepted OPEN issue (revisit before live). Orchestrate the state machine in `cinematic-mint` (moderation
      gates between phases → `moderation_escalations`; per-step seeds/ledger; 429-skip; sim testable).
- [ ] **Finalize**: post-gen moderation on the finished MP4 (mandatory — clean bookends never vouch for the
      middle, HR39) → card art from the stylized clip → store `battle-media` → real practice-battle preview
      gate → write via `cinematic_complete_mint`.
- [ ] **Paid micro-trials per node BEFORE wiring** (`tools/cinematic/trial_*.ts`); then **first-render
      validation** of the agnostic start/end plates; iterate plate v2 only if renders demand it.
- [ ] **Live flips when creds/spend land**: `CINEMATIC_MODE=live` (Segmind) · `MODERATION_MODE=live`
      (ANTHROPIC key already set) · `MOMENT_CLASSIFY_MODE=live` · `MINT_CLIP_MODE=live` · `MINT_INGEST_MODE`
      already live (IG still 503s cleanly until creds; swap TikTok sandbox→prod at app approval).

### Track B — Effect system depth (Wave 2 → 3)  ⟵ spec: `NORA_INTERACTION_LAYER_SPEC.md`
Wave 1 (single-clause library + server-side selection) SHIPPED (migs 151/152 — see ARCHIVE + `NORA_CHIT_
EFFECT_LIBRARY_WAVE1.md`). The reactive/"instant" depth is engine work, sequenced so only the last piece
touches the turn loop. Framework: `NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md`.

- [ ] **Wave 2a — compound-clause resolver** (shared prerequisite): `effect_template_clauses` (or
      `secondary_effect_*`) → clause list snapshot on `ccg_match_cards` → `ccg_apply_card_effect` loops clauses
      → `compose_chit_rules` joins them. Unlocks `complexity=2` templates (already gated by `min_tier_band`, mig 151).
- [ ] **Wave 2 library expansion**: 4th/5th templates per family incl. compound cards, authored by cycle vs the
      §1 identity matrix; wider use of `summon_token` once the resolver stub (mig 128) is implemented.
- [ ] **Wave 2b — charge-up state** (Pillar C): per-card `charges` (in-match only) + `charge_gain`/`charge_spends`
      template hooks → "build a payoff later"; homes the deferred Combo (Gamer) / Encore (Musician) signatures. No turn-loop change.
- [ ] **Wave 3a — Secrets** (Pillar A): `armed` hidden zone + new trigger conditions (`on_enemy_summon/attack/
      spell/activated/face_damage`) + `ccg_check_secrets`; RLS hides armed cards from the opponent. Generalizes
      the existing `counter/when_attacked` seam — no priority system.
- [ ] **Wave 3b — `negate` effect kind** (Pillar B): the counterspell; the ONLY piece that changes the action
      loop (pre-commit interrupt) — isolate it, build last.
- [ ] **Open questions (spec §6)** for the user before building: secret chit_type vs flag · secret cap ·
      `negate` hardness + which families hold it · charge-up flavor · **whether Secrets gate to non-monetized
      matches** (hidden-card info-asymmetry vs real-money `battle_outcome` — ties to G-MON).
- [ ] **Wave-1 polish, low-lift**: auto-set `vibe_gate` on A/S-tier mints (premium needs Aura + Vibe);
      surface the selected effect + a rules preview in the mint Review step (step 4).

### External unblocks the user still owns (gate the above)
- `CINEMATIC_MODE=live` + Segmind spend (Track A) · `MODERATION_MODE=live` decision · production TikTok
  key/secret (swap the sandbox pair at app approval) + Instagram `INSTAGRAM_CLIENT_ID/SECRET`.
- **G-MON confirmation** before any real-money go-live (the gate is built; the rule needs sign-off).
- Rotate the `service_role` + `SUPABASE_ACCESS_TOKEN` (both appeared in session transcripts) and
  `NORA_SIGNING_PRIVATE_KEY` (known-compromised, generated in Codespace) — all post-launch, pre-live.
- Browser-verify a fresh end-to-end mint now that rules/effects populate (analyze/PostgREST-verified only).

---

## v3 build plan status (P0–P7) — condensed
Per-phase detail + checklists: `NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md`. Build history: ARCHIVE.

- **P0–P6 DONE + applied to prod** (migs 116–137): canonical model/governance · chit catalog + collection +
  deck + barter · tier ladder + effects + fusion data · CCG combat engine · Vibe meter · real-money rail +
  G-MON gate · minting pipeline + tier-ascension. Cinematic engine + minting v2 layered on top (138–152).
- **P7 — launch hygiene: OUTSTANDING.** Execute the archival retirements (schemas archived-not-dropped),
  weekly polls/multipliers → DORMANT, Emergency Fund live behind config, **pre-launch reset (ARCHIVE §A8) +
  remove all dev tooling** (arena bot-backer, test-match maintainer, `dev_*` RPCs, cinematic/mint smoke users),
  final smoke tests.
- **🚧 Open product call — G-MON:** real-money `battle_outcome` market created iff both players KYC'd; royalty
  routes to moment-owners of played chits; consent at mint, KYC at cash-out. Gate is built; confirm before go-live.

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
inspection-only). Cross-repo contract: **RECONCILIATION.md** (keep §7 mirroring as gates unblock; add the
new `moment_chits` display fields — `rules_text`/`flavor_text`/`card_serial` — so Unity prints identical text).
- [ ] **Merge `doc6-mobile-iap-confirm`** (commit ee5a782: `mobile_iap_confirm` + mig 115) — also a v3 P5 prereq.
- [ ] Gateway routing for `api.noraplatforms.com/v1/verify` (shared blocker with Licensing above).
- [ ] FCM push (battle invites, bet resolution) using `profiles.fcm_token_mobile`.
- [ ] RevenueCat IAP config (token packs / chit packs) → `mobile_iap_confirm`.
- [ ] Native iOS/Android shells, store submissions, deep links from web.
- [ ] The v3 CCG contract (moment-chit catalog + display fields, tier exposure, CCG `battle_events`, market
      gating, minting/ascension, fusion) replaces the old character-select contract — mirrored in RECONCILIATION.

### nora-arena reconciliation — platform-side decisions that survive v3
- [ ] **R1 — Archetype vocabulary.** archetype **families** are the v3 effect-family classifier. Fix
      `get_eligible_characters` self-branch to emit a battle archetype; expose the resolved archetype/family on
      `lkn_public_registry`; publish the `category_1 → archetype` map. (Client deletes its alias table.)
- [ ] **R3 — Canonical spectator-bet path.** v3 settles battle markets via `bets` on `battle_outcome` `markets`
      (USD). Point mobile at this path; deprecate legacy `battle_place_spectator_bet`/`battle_spectator_bets`
      (mig 062). **Until the mobile cutover ships, do NOT delete the legacy 062 table/RPC.**
- **R2 is RETIRED by v3** (license-per-character eligibility removed; eligibility = own chits + legal deck).

### Slice 2 — test-account filter sweep
Systematic grep of `is_market_maker` / `is_test_account` across all providers to guarantee no test accounts
leak into ranking/discovery (Hard Rule 15). Tracked separately (Rule 22).

### Pre-launch polish
- [ ] Celebrity profile pictures — `celebs.image_url` NULL for all 25 (UI falls back to initials).
- [x] Onboarding walkthrough — SHIPPED (6-page welcome tour, once per user, re-openable from drawer).
- [ ] Profile avatars from connected platform data.
- [x] Launch-day animation — SHIPPED (countdown → midnight ET; rocket cutscene w/ fallback). **User owes the MP4.**
- [ ] Run the **pre-launch reset sequence** + remove all dev tooling (ARCHIVE §A8) — folded into v3 P7.

---

## RETIRED by the v3 pivot (do not resume; schemas archived-not-dropped in P7)
Detail + retired schemas in ARCHIVE §A3/§A4/§B (archived, never DROPped — v3 P7 executes the archival).
- The v2.x **1v1 archetype-fighter** model: 6-player sprite Battle, Battle Phase D, D&D six-stat characters,
  per-archetype move-sets (`battle_abilities`), parody-celebrity avatars, license-per-character eligibility (R2).
  Celebrities return as licensed premium chits (P1); stat sheets survive but are cosmetic.
- **Battle bot-fill** for the old matchmaking loop — re-scope to the CCG engine only if needed.
- **Legacy powerup "Battle Chits"** (`battle_chit_definitions`) — dormant (Hard Rule 27); the v3 "moment chit"
  is a different asset (P1). Do not conflate the tables.

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
- **On-chain / NORA coin**: append-only ledgers (`likeness_card_transfers`, `lkn_agreements`, the
  `chit_ownership` acquisition ledger, and archived `campaigns_archived_ledger`) are designed to migrate to
  on-chain settlement. Integer-cents, no floats, every ownership change a new row. Full migration path +
  original Campaigns royalty/Reg CF framework preserved in ARCHIVE.
- **Revenue data partnerships** (Spotify for Artists, YouTube Analytics, DistroKid/TuneCore) — the layered
  verification roadmap still informs licensing revenue-share and could feed engagement-tier signals for minting.
- **Battle V2 (Unity)** — the mobile client is already Unity; the Supabase data layer is engine-agnostic so
  the CCG engine (P3) drives both web and Unity clients from the same `battle_events` stream.
