# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-08.
# Rules for HOW to build any of this live in CLAUDE.md ("Building future work safely").
# Full specs / schemas / build history for anything referenced here live in ARCHIVE.md.
# Cross-repo (nora-arena) contract: RECONCILIATION.md. Doc map: README.md.
#
# ⚠️ v3 PIVOT (2026-07-01): the game is the "Moments" card-battler. Canonical spec:
# NORA_PLATFORMS_BUILD_SPEC_v3.md. P0–P6 SHIPPED (migs 116–137); the P7 launch-hygiene
# remainder is tracked HERE (§"P7"). The v2.x 1v1 archetype-fighter plan is RETIRED (bottom).

---

## Status snapshot (where we are, 2026-07-08)

- **Live & built (v2.x base, reused by v3):** Markets, Hot Topic, Likeness Cards + stat sheets +
  marketplaces, celebrity integration, KYC flow, Emergency Fund (sim), Licensing Marketplace (backend +
  Flutter). Legacy 1v1 Battle + Arena exist but are **superseded by the v3 card-battler** (see Retired).
- **v3 card-battler:** P0–P6 BUILT + applied to prod (migs 116–137); the CCG engine, tier ladder, effects,
  fusion, Vibe, real-money rail, minting + ascension all live. P7 (launch hygiene) tracked below.
- **Mint pipeline END-TO-END** (2026-07-02→05, migs 138–152 — history in ARCHIVE "2026-07-02→05"):
  `/mint` post-verify → device-clip trim → moderation → classify + effect selection → generate (sim) →
  web Preview (CardFace, real rules/flavor/serial) → finalize → `/collection`. Cloud Run stitch worker live.
- **Chit marketplace M1+M2+M3 SHIPPED** (2026-07-08, migs 153–156 + Flutter `/market` — spec
  `NORA_PLATFORMS_MARKETPLACE_SPEC.md`, history in ARCHIVE "2026-07-08"): fixed-price **token lane LIVE**
  end-to-end (list/buy/delist RPCs, escrow over the acquisition ledger, A/S fee **burned**, ascension frozen
  while listed) with the web client (browse/buy/delist on `/market`, Sell from `/collection` + mint-success);
  **USD lane built like-live but OFF** behind `platform_integrity_settings.marketplace_usd_lane` (founder
  gate) — KYC-on-USD gates + **provenance lock** (token-bought → token-resale-only) already enforced; sim
  settlement on the mig-132 rail. ⚠️ Not yet browser-verified (see the 2026-07-08 next-steps entry below).
- **Migration ledger:** remote DB in sync at **156** (via `supabase db push`). Next = **157**.
  138–147 cinematic/minting-v2 · 148 chit display fields · 149 `{VIDEO_DESC}` · 150 mint-cancel ·
  151/152 effect library · 153–155 marketplace M1 · 156 marketplace M2 (USD seam).
- **`flutter analyze`:** clean (2026-07-08). **`deno check`:** ⚠️ 9 pre-existing fns fail under the
  Codespace's Deno 2.9/TS 5.7 strictness (`lkn-verify`, `resolve-markets`, `apply-promotion`,
  `arena-dev-*`, `hot-topic-resolve-week`, `likeness-{buy-listed,purchase}-card`,
  `ubi-assemble-voting-panel`) — type-level only, unrelated to recent work; sweep queued below.
- **Config flags:** `MINT_INGEST_MODE=live` · `MOMENT_CLASSIFY_MODE=sim` · `CINEMATIC_MODE=sim` ·
  `MODERATION_MODE=sim` · `MINT_CLIP_MODE=sim` · `SEGMIND_API_KEY` set · TikTok **sandbox** creds · IG none ·
  `battle_payments_mode=sim` · `marketplace_usd_lane=FALSE`. Flipping any is a spend/creds/founder decision.

**Active build tracks — see "Where we're going next."**

---

## 2026-07-08 — post-M3 next steps (identified during the marketplace build + inventory audit)

What the M1–M3 build and the `APP_INVENTORY.md` sweep surfaced as needing modification, in rough
priority order. (Full row-level detail + verdicts live in APP_INVENTORY.md; this entry is the
timestamped pointer so the queue isn't lost.)

1. **Browser-verify the marketplace loop end-to-end** — mint → Sell from collection → buy with a second
   account → delist. Everything is analyze/PostgREST/prod-smoke-verified only; no live listing has ever
   been created through the UI. Also re-verify a fresh mint now that effects/rules populate (carried over).
2. **Ascension has NO user surface** — `chit_ascension_refresh` (mig 136, the "viral upgrade" loop) has
   zero Dart callers. Users cannot tier-up their cards. Needs a Refresh button + tier-up celebration on
   `/collection` (and mirrors into Unity).
3. **Dead-code deletions (zero risk)** — `features/campaigns/` (~4k lines, routes already redirect to
   /plan), `features/discover/`, `features/notifications/` (no importers), `spotlightCreatorsProvider`.
   One PR, analyze-clean.
4. **Minimal web deck-builder** — `decks`/`deck_set_chits` (mig 118) have no UI anywhere; without one, no
   real CCG match can be entered by a user and P7's deck-entry e2e can't run. Unity owns the rich version;
   a minimal web builder unblocks testing.
5. **Spectate screen effect-vocabulary + vibe check** — `/battle/spectate/:id` predates the Wave-1 effect
   library (migs 151/152); verify new event kinds render (not unknown no-ops) and that Vibe is displayed.
6. **Mint Review step: show the selected effect** — user currently confirms a card without seeing its
   effect/rules preview (Track B "Wave-1 polish" item; now also an inventory NEEDS-EDIT).
7. **No-frontend backends to schedule an owner for** (web vs Unity, per APP_INVENTORY §2): barter (119),
   premium chit packs (120, post-G-MON), wager-match UI (142, Unity per spec), USD bet sheet (133/145,
   Unity canonical per R3), vibe reactions (`ccg_record_vibe_signal`).
8. **Slice-2 filter sweep + known-gaps hygiene** — HR15 test-account filters across discovery providers;
   move `celebrity_profile_screen.dart` into `hot_topic/`; seed `celebs.image_url`; sim→live copy pass on
   placeholder text when Track A flips; deno-check sweep (9 pre-existing type failures).
9. **Gated retirements (do NOT do early)** — legacy Arena screens + 1v1 Battle lobby/match/matchmaking
   screens wait on P7 7.2 archival + the nora-arena R3 cutover; polls → DORMANT at P7; legacy powerup
   "Chits" tab stays dormant (HR27).

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
Wave 1 (single-clause library + server-side selection) SHIPPED — migs 151/152; the live templates are the
DB (`effect_templates`); design record + the shipped Wave-1 decisions are in ARCHIVE ("2026-07-02→05" +
"2026-07-08 doc consolidation"). Framework: `NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md` (§1 identity matrix
still governs Wave-2 authoring). The reactive/"instant" depth is engine work, sequenced so only the last
piece touches the turn loop.

- [ ] **Wave 2a — compound-clause resolver** (shared prerequisite): `effect_template_clauses` (or
      `secondary_effect_*`) → clause list snapshot on `ccg_match_cards` → `ccg_apply_card_effect` loops clauses
      → `compose_chit_rules` joins them. Unlocks `complexity=2` templates (already gated by `min_tier_band`, mig 151).
- [ ] **Wave 2 library expansion**: 4th/5th templates per family incl. compound cards, authored by cycle vs the
      framework §1 identity matrix; wider use of `summon_token` once the resolver stub (mig 128) is implemented.
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

### Track C — Marketplace economy remainder  ⟵ spec: `NORA_PLATFORMS_MARKETPLACE_SPEC.md` (M1+M2+M3 shipped)
- [x] **M3 — Flutter client** SHIPPED 2026-07-08 (PR #13): `/market` browse/buy/delist w/ CardFace,
      Sell from `/collection` + mint-success, nav + wallet labels. ⚠️ Browser verification pending
      (next-steps entry item 1).
- [ ] **§6 token economy**: signup grant 500🪙 (currently 100 — decision + migration) · challenge emissions
      move open-faucet → **budgeted + tapered** (daily-streak / onboarding-funnel / burn-recycled ladder).
      Needs the CLAUDE.md currency-model governance edit (founder sign-off — spec §2).
- [ ] **USD lane flip** = founder gate: `marketplace_usd_lane=TRUE` (KYC gates + provenance lock already
      enforce themselves). Real money additionally needs `battle_payments_mode='live'` (Stripe Treasury /
      Connect seller payout — the mig-132 live branch, shared with P5).
- [ ] **M4 — battle pass / subscription**: analysis in spec §7. **GATED** — do not start before M1–M3 shipped
      AND the §6 emission model is re-run AND founder sign-off. Hooks already in place:
      `marketplace_listing_allowance()` (extra listing slots) + stipends land in the *bought* bucket.

### Track D — App inventory remediation  ⟵ queue: `APP_INVENTORY.md` (compiled 2026-07-08, post-M3)
The full FE↔BE coverage audit lives in **APP_INVENTORY.md**: what's wired, backend built with NO
frontend (deck builder, barter, packs, ascension, wager UI…), surfaces needing edits, and FE to
retire (campaigns/discover/notifications dead code now; legacy arena/battle screens gated on P7 +
the mobile cutover). Work it in that file's §6 order; move completed rows into ARCHIVE dated entries.

### Maintenance / small
- [ ] **deno-check sweep**: fix the 9 pre-existing type failures (see snapshot) so `deno check` is clean
      repo-wide under Deno 2.9/TS 5.7.

### External unblocks the user still owns (gate the above)
- `CINEMATIC_MODE=live` + Segmind spend (Track A) · `MODERATION_MODE=live` decision · production TikTok
  key/secret (swap the sandbox pair at app approval) + Instagram `INSTAGRAM_CLIENT_ID/SECRET`.
- **G-MON confirmation** before any real-money go-live (the gate is built; the rule needs sign-off).
- **`marketplace_usd_lane` + §6 economy sign-offs** (Track C).
- Rotate the `service_role`, `SUPABASE_ACCESS_TOKEN` (multiple tokens have appeared in session transcripts,
  latest 2026-07-08) and `NORA_SIGNING_PRIVATE_KEY` (known-compromised, generated in Codespace) — all
  post-launch, pre-live.
- Browser-verify a fresh end-to-end mint now that rules/effects populate (analyze/PostgREST-verified only).

---

## v3 P7 — launch hygiene (the remainder; P0–P6 are DONE)
P0–P6 shipped to prod (migs 116–137; per-phase history in ARCHIVE). What P7 still owes, with its gating:

- [ ] **7.2 Physical archival of retired schemas** (markers set in mig 121): rename/archive `battle_abilities`
      + the 1v1 stat/moveset tables; drop `check_battle_eligibility`/`get_eligible_characters`; weekly
      polls/stat-multipliers → DORMANT; retire parody-avatar scaffolding. **Archive, never DROP.**
      ⏸ Gated on the legacy-engine cutover + the nora-arena pivot — mobile still consumes the legacy fns
      (RECONCILIATION §1). Do NOT run before that.
- [ ] **7.4 Pre-launch reset** (ARCHIVE §A8) — destructive, run LAST on launch day: teardown test accounts,
      truncate test Arena/Battle rows, reset balances/bets/markets, re-grant signup bonuses; remove ALL dev
      tooling (`dev_*` RPCs, `arena-dev-*` fns, bot-backer/test-match-maintainer crons per ARCHIVE §A5);
      sweep dev-seed chits (P2/P3), `is_test` matches, and the smoke identities
      (`cinematic-smoke*@`, `mkt-smoke-1/2@noraplatforms.com` + their ledger/sales residue).
- [ ] **7.5 Final verification**: full `flutter analyze` + an e2e **real-money round-trip** (2 KYC'd users,
      sim USD: market → bets → settle → moment-owner + passive-holder credits) and a **deck-entry** match from
      two real 20-card decks — neither exercised end-to-end yet (per-phase apply-time smokes are green).
- **🚧 Open product call — G-MON:** real-money `battle_outcome` market created iff both players KYC'd; royalty
  routes to moment-owners of played chits; consent at mint, KYC at cash-out. Gate is built; confirm before go-live.

---

## Cross-cutting work that survives v3 (not phase-specific)

### Licensing Marketplace (Doc 5) — remaining
- [ ] **Gateway routing**: point `GET api.noraplatforms.com/v1/verify` at deployed `lkn-verify` (Cloudflare
      route or Vercel rewrite → `…functions.supabase.co/lkn-verify`). Unblocks mobile License Sync. Runbook in ARCHIVE.
- [ ] **`lkn-generate-contract`**: needs the attorney-seeded `lkn_contract_clauses` table (not yet created).
      Do NOT fabricate legal language (Hard Rule 30). Deferred until clause library exists.
- [ ] **Signing-key rotation** (also a P5 live prereq): current `NORA_SIGNING_PRIVATE_KEY` works but is
      known-compromised (generated in a Codespace). Regenerate on a local secure machine, update the secret +
      `.well-known/nora-public-key.pem`, before live launch.
- [ ] Featured/paid listing placement (post-launch).

### Mobile app (nora-arena, separate repo) — surviving items
Backend prep in THIS repo is done: mig 114 + four `nora-arena-api-*` wrappers + **`mobile_iap_confirm` +
mig 115 (MERGED 2026-06 — commit 2f09ddc; the old "merge the branch" task is complete)**. nora-arena is
**Unity (C#) + Meshy 3D**; launch target mobile (WebGL inspection-only). Contract: **RECONCILIATION.md**
(§5 CCG, §7 minting/cinematic, §8 marketplace).
- [ ] Gateway routing for `api.noraplatforms.com/v1/verify` (shared blocker with Licensing above).
- [ ] FCM push (battle invites, bet resolution) using `profiles.fcm_token_mobile`.
- [ ] RevenueCat IAP config (token packs / chit packs) → `mobile_iap_confirm`.
- [ ] Native iOS/Android shells, store submissions, deep links from web.
- [ ] Keep RECONCILIATION §5/§7/§8 mirrored as gates unblock (incl. `moment_chits` display fields
      `rules_text`/`flavor_text`/`card_serial` so Unity prints identical text).

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
- [ ] Run the **pre-launch reset sequence** + remove all dev tooling — folded into P7 above.

---

## RETIRED by the v3 pivot (do not resume; schemas archived-not-dropped in P7)
Detail + retired schemas in ARCHIVE §A3/§A4/§B (archived, never DROPped — P7 executes the archival).
- The v2.x **1v1 archetype-fighter** model: 6-player sprite Battle, Battle Phase D, D&D six-stat characters,
  per-archetype move-sets (`battle_abilities`), parody-celebrity avatars, license-per-character eligibility (R2).
  Celebrities return as licensed premium chits (P1); stat sheets survive but are cosmetic.
- **Battle bot-fill** for the old matchmaking loop — re-scope to the CCG engine only if needed.
- **Legacy powerup "Battle Chits"** (`battle_chit_definitions`) — dormant (Hard Rule 27); the v3 "moment chit"
  is a different asset (P1). Do not conflate the tables.
- **The v2.x Alignment Build Spec** + its open-questions doc — superseded whole by the v3 pivot; its
  still-relevant asks (real-money rail, R1/R3) were absorbed into P5 and this file (doc retired 2026-07-08).

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
already built (mig 142). **The shipped marketplace (migs 153–156) deliberately stays on this side of
the line: fixed config prices, fee burned, no accrual — and the provenance lock keeps free token
emission from ever reaching USD.**

**If G-CARDVAL is ever cleared, open design questions:** exact accrual formula and which markets
feed it; whether accrual attaches per-copy or per-definition; how set-completion redemption prices
out; interaction with ascension (value vs tier); anti-manipulation (wash-trading a card you also
rake into); and how any of it is disclosed without financial-instrument language.

---

## Long-horizon vision (post-launch, not scoped)
- **On-chain / NORA coin**: append-only ledgers (`likeness_card_transfers`, `lkn_agreements`, the
  `chit_ownership` acquisition ledger + `marketplace_sales`, and archived `campaigns_archived_ledger`) are
  designed to migrate to on-chain settlement. Integer-cents, no floats, every ownership change a new row.
  Full migration path + original Campaigns royalty/Reg CF framework preserved in ARCHIVE.
- **Revenue data partnerships** (Spotify for Artists, YouTube Analytics, DistroKid/TuneCore) — the layered
  verification roadmap still informs licensing revenue-share and could feed engagement-tier signals for minting.
- **Battle V2 (Unity)** — the mobile client is already Unity; the Supabase data layer is engine-agnostic so
  the CCG engine (P3) drives both web and Unity clients from the same `battle_events` stream.
