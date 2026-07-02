# passbacktoclaude.md — Open questions from the Alignment Build Spec cross-reference

**What this is:** I read `NORA_PLATFORMS_ALIGNMENT_BUILD_SPEC.md` in full and cross-referenced it
against the repo (CLAUDE.md, PLAN.md, ARCHIVE.md, RECONCILIATION.md, `supabase/migrations/*`,
`supabase/functions/*`). Below are the **issues of concern that leave open-ended questions** — places
where the spec assumes something the repo doesn't yet support, contradicts an existing Hard Rule or
contract, or makes a decision that needs a human/product answer before Claude Code can safely build it.

Items are ordered roughly by how blocking they are. The spec already self-flags a few things (the
`match_revenue_config` split numbers, R1–R4); those are restated only where I found extra friction.

Verified state at time of writing: remote/local migration ledger runs 066→115 (matches PLAN.md "115").
`battle_archetype` does **not** exist anywhere yet. `entertainment_game` appears in `lkn-verify` but in
**no** battle-eligibility function. `match_revenue_config` (mig 088) currently credits **tokens**.

---

## A. Real-money rail / currency model (Phase 3) — the biggest unanswered area

### A1. The shared `bets`/`markets` table has no currency dimension — how do USD battle bets coexist with token Markets bets in the same table?
- Spec §1 + Phase 3: **Battle prediction-market bets settle in real money (USD)**; **Markets bets stay
  token-only.** But Phase 3 routes battle settlement through `markets` + `bets` rows with
  `resolution_type='battle_outcome'` (mig 100) — **the same table Markets and Hot Topic use.**
- In the repo today, `bets.amount` feeds `markets.yes_pool/no_pool` (mig 004 trigger, taught team
  positions in mig 100) and everything is **token-denominated**. There is no `currency`/`denomination`
  column on `bets` or `markets`, and no link from a `bets` row to `sim_usd_balances` / a Stripe charge.
- **Open question:** How is currency represented per-market/per-bet so that the *same* `distribute_*`
  and pool-update plumbing settles `battle_outcome` markets in USD while leaving Markets in tokens?
  Options the spec doesn't choose between: (a) a `currency` enum column on `markets` + parallel USD
  pool columns/ledger; (b) a separate `battle_bets`/USD-pool table and keep `bets` token-only; (c) store
  integer-cents in `amount` for battle markets and branch on `resolution_type`. Each has very different
  blast radius on the existing `handle_bet_pool_update` trigger, `battle_bet_sheet`, and RLS. **This is
  the central plumbing decision of Phase 3 and the spec leaves it implicit.**

### A2. Spec's new revenue split doesn't map onto the existing `match_revenue_config` keys.
- Existing `match_revenue_config` (mig 088) keys: `active_participants_pct 0.10` (winning team **only**),
  `creator_pct 0.05`, `passive_owners_pct 0.05`, `platform_pct 0.05` — totals **0.25**, with the
  remaining ~75% implicitly going to correct predictors (no `predictors_pct` row exists).
- Spec Phase 3 wants: **80% predictors / 8% players (winner-weighted 6/2, winners AND losers paid) /
  2% creators / 5% passive **license** holders / 5% platform** (= 100%).
- **Open questions:** (1) The player slice changes from *winner-only 10%* to *winner+loser 8%* — confirm
  the loser-pays-too change is intended (it changes incentive design). (2) There's no `predictors_pct`
  config key today; is predictors derived as the residual or made explicit? (3) The spec itself flags
  "exact numbers flagged for product to set" — **these percentages are not yet product-confirmed; do not
  hardcode 80/8/2/5/5 as final.**

### A3. Cross-repo contract break: battle bets change from **tokens → real money**, but mobile is mid-Unity-rewrite and built against tokens.
- RECONCILIATION §1 freezes `battle_place_spectator_bet(p_match_id, p_team_number, **p_tokens_wagered**)`
  and `nora-arena-api-token-balance` as live contracts; the Unity client (per RECONCILIATION §0) is only
  at **Phase 3 of 6** (character pipeline), with markets/betting (Phase 5) **not started**.
- The spec resolves R3 by making `bets`/`battle_outcome` canonical AND flipping that path to USD. That's
  **two simultaneous breaking changes** for mobile (path + currency), plus it pulls KYC/age/jurisdiction
  gating in front of every spectator bet.
- **Open question:** Is nora-arena aware that spectator betting becomes **real-money, KYC-gated**, not a
  token sink? The current mobile bet UI assumes tokens. This needs to be mirrored into RECONCILIATION as
  a contract change, not just "migrate to the new path." Sequencing: the spec says don't delete legacy
  062 until mobile migrates — good — but doesn't say what currency mobile bets in *during* the overlap.

---

## B. License-as-asset & the 10 seed characters (Phases 1–2) — legal/compliance open questions

### B1. Seeding real living celebrities as platform-managed battle characters for **real-money** betting appears to contradict the entire Right-of-Publicity premise.
- Phase 2 seeds 10 **real, identifiable, living** people (Trump, Sabrina Carpenter, Ronaldo, Kanye,
  Palmer Luckey, Ninja, Alix Earle, Neil deGrasse Tyson, Arnold Schwarzenegger, Theo Von) as
  `managed_by_platform=TRUE` `profiles`, with named signature moves ("You're Fired", "Juno", "I'll Be
  Back") — and Phase 3 layers **real-money prediction markets** on matches featuring them.
- The Licensing Marketplace (`lkn_*`) exists precisely to make likeness use **consent-gated** (a licensor
  registers, approves templates, signs `lkn_agreements`). The Hot Topic system seeds celebs too, but only
  for a **buzz leaderboard** — not for monetized likeness combat.
- The spec asserts "**Compliance is build/refine, not design… legal review is considered complete.**"
  **Open question / concern:** Does "legal review complete" actually cover *platform-operated, real-money
  battle/betting using the names, likenesses, and catchphrases of specific non-consenting public figures*?
  This is the highest-risk item in the spec and it's stated as a settled assumption with no citation. I'm
  flagging it explicitly rather than building toward it silently. **Needs human legal confirmation before
  Phase 2 seeding + Phase 3 real-money go-live.**

### B2. Who is the **licensor** for the 10 platform-managed seed characters, and how do real users obtain a license to field them?
- Phase 2 gates battle eligibility on holding an **active `entertainment_game` license** for the character
  (`lkn_agreements`), "or are the platform-managed seed itself for dev."
- But `lkn_agreements` rows require a registered **licensor** (`lkn_register_licensor` / `lkn_licensors`,
  mig 108) and a priced **listing/template**. For the 10 seeds, there is no real creator account to be the
  licensor.
- **Open questions:** (1) Does the platform self-issue licenses for the seeds (platform-as-licensor)?
  (2) Are there `lkn_listings` for the seeds so users can actually *buy* a license to battle as them, or
  are the seeds spectate/dev-only at launch? (3) If platform self-issues, what's in `terms_snapshot` /
  who "signs" — and does that survive the Hard Rule 29/30 append-only + clause-library constraints? The
  spec ties eligibility to licenses but never says how a license for a platform seed comes into existence.

### B3. One-active-license-per-character constraint vs. append-only `lkn_agreements`.
- Phase 1 [NEW]: "a buyer may hold **one active license per character**," enforced at primary + secondary.
- `lkn_agreements` is append-only with status-only updates (Hard Rule 29). A partial-UNIQUE on
  `(licensee, listing) WHERE status='active'` is the natural enforcement, but resale/barter creates a
  *new* row while the old one's status flips to transferred — there's a window/ordering question.
- **Open question:** Confirm the constraint is `WHERE status IN (active)` partial-unique and that the
  transfer RPC flips the old row's status **before** inserting the new active row in one transaction, so
  the unique index never trips mid-transfer. Spec says "enforce" but not the mechanism, and getting this
  wrong either blocks legitimate resales or allows double-holding.

### B4. License↔Chit barter has no money leg but crosses two value systems with no stated valuation/abuse guard.
- Phase 1 [NEW] `lkn-barter-license`: trade a license for Battle Chits "with no money leg."
- **Open questions:** (1) A license is a real-money asset (KYC-gated); chits are bought with **tokens**
  (per §1 currency table). A money-free swap between a regulated asset and an unregulated token-bought
  asset is a potential **value-transfer / wash path around KYC** — is that acceptable, and does the barter
  require KYC on both sides? (2) What prevents using barter to launder a license's USD value into tokens
  (or vice-versa)? The spec treats this as a simple atomic inventory move; the compliance implication is
  unaddressed.

---

## C. Eligibility, archetype, and stat model (Phase 2)

### C1. `battle_archetype` is brand-new — confirm storage location (character vs. license vs. profile) and migration of existing data.
- `battle_archetype` exists **nowhere** in the repo today (verified). Spec says add it "to the
  character/license record" and expose it in `lkn_public_registry`. But there is no `characters` table —
  identity today lives across `profiles`, `likeness_offerings.archetype` (the CUT card system), and
  `lkn_listings`/`lkn_agreements`.
- **Open question:** Once cards are retired (Phase 1), the canonical home for `battle_archetype` and the
  D&D stat block is ambiguous. Is it a new `characters` table, columns on `lkn_listings`, or on the
  platform-managed `profiles`? Phase 2 relocates the `likeness_offerings.archetype` CHECK "onto the
  license/character record" but doesn't name the table — this needs to be pinned before the migration.

### C2. R2 fix (license→eligibility) confirmed still open in code.
- Verified: `entertainment_game` appears only in `lkn-verify`; **no** battle-eligibility function
  references licenses. `check_battle_eligibility`/`battle_enqueue` still gate on `likeness_cards`. The
  spec's Phase 2 plan to gate on an active license is correct and necessary — just confirming it's
  genuinely unbuilt, and that retiring cards (Phase 1) **before** wiring license-eligibility (Phase 2)
  would leave a window where *nothing* grants battle eligibility. **Ordering concern:** Phase 1 must not
  archive the card-eligibility path until Phase 2's license path is live, or battle entry breaks.

---

## D. Vibe Meter (Phase 4)

### D1. Salvaging `process_arena_tick` is plausible but the legacy tick engine is bound to legacy Arena tables being CUT in the same phase.
- Spec Phase 4 [REPURPOSE] keeps the tick/Realtime engine (`process_arena_tick`, migs 029/031/035/047/048)
  while Phase 4/6 [CUT] removes `arena_back`/`arena_trigger`/`arena_abilities` and Phase 6 archives the
  rest of legacy Arena.
- **Open question:** `process_arena_tick` reads legacy `arena_state`/momentum/match tables. Which of those
  tables does the Vibe Meter still depend on after the CUT, and which get archived? The spec says "salvage
  the mechanism" but the mechanism and the CUT tables are entangled. Need an explicit keep-list of legacy
  Arena objects the Vibe Meter retains vs. archives, so Phase 6 cleanup doesn't delete a table Vibe needs.

### D2. Vibe is driven by "real bet activity" — but if battle bets are KYC-gated real money (Phase 3), a low-liquidity match produces a near-dead Vibe Meter.
- **Open question:** Is the Vibe Meter computed from **USD bet volume/velocity** only? At launch, with KYC
  gating and presumably thin volume, the crowd-influence mechanic may rarely cross thresholds. Should Vibe
  also factor token activity, spectator count, or have a floor? This affects whether Vibe-gated moves are
  ever reachable in early matches — a gameplay dead-feature risk the spec doesn't address.

---

## E. Documentation / governance (Phase 0) and process

### E1. Phase 0 adds new Hard Rules and rewrites the Systems block — numbering/renumbering risk.
- Spec says add a real-money/token settlement Hard Rule and an archetype Hard Rule, "Keep Rules 26–32; do
  not renumber." Current CLAUDE.md has exactly 32 numbered Hard Rules. New rules should be appended as
  33/34+, not inserted. Just confirming the intent: **append only.** (Low risk, but worth stating since the
  spec also says "do not renumber existing rules without recovering the full current list first.")

### E2. Markets is described as "now token-only" — confirm there is nothing to *remove*, only to document.
- Markets has always settled in tokens in the repo (no real-money component exists to strip). So "now
  token-only" is a **documentation clarification**, not a code change. Flagging only so Phase 0/3 don't go
  hunting for a real-money Markets path to remove that was never built. (Non-issue, recorded to prevent
  wasted effort.)

### E3. Emergency Fund live-mode is "baseline = launch" in §1 but "cleanest item to hold at sim/post-launch" in Phase 6 — pick one.
- §1 KEEP says Emergency Fund "baseline = launch"; Phase 6 says "if timeline bites, this is the cleanest
  item to hold at sim/post-launch — flag, don't assume." **Open question for product:** is Emergency Fund
  **live** at July-4 launch or held at sim? The two passages hedge in opposite directions. Needs a single
  recorded decision (it gates whether the Stripe Treasury live wiring is launch-blocking).

---

## F. Smaller flags / confirmations

- **F1. Timeline vs. scope.** Launch target is **July 4 2026** (CLAUDE.md); today is 2026-06-28. This spec
  is six phases of substantial backend work (new USD bet plumbing, license market, 10-char seed + stat
  system, Vibe Meter, media pipeline, deprecations) **plus** a dependent Unity client only 50% through its
  own rewrite. **Open question:** Is the full spec a July-4 target, or is some of it explicitly fast-follow?
  Phases 5 (media) and 6 (chit-combination) self-describe as deferrable; A/B/C above probably can't all
  land in ~6 days. A phase-to-launch-vs-post-launch mapping would help.
- **F2. `LKN_PAYMENTS=sim→live` + signing-key rotation are coupled to going live.** PLAN.md already records
  the signing key is **known-compromised** (generated in a Codespace) and must be rotated on a secure
  machine before live. Phase 3 "flip to live" must not happen before that rotation — the spec doesn't
  mention the rotation dependency. Flagging so live-flip and key-rotation are sequenced together.
- **F3. Idempotency across Stripe + RevenueCat.** Phase 3 reuses `mobile_iap_receipts` (mig 115) — note
  that migration is on an **unmerged branch** (`doc6-mobile-iap-confirm`, per PLAN.md/MEMORY). Phase 3's
  "idempotent across web Stripe and mobile RevenueCat" assumes 115 is merged. Confirm the merge before
  building on it.
- **F4. "Palmer Luckey / Anduril" seed** mixes a person and a company under the `business` archetype —
  confirm whether the character is the individual or the brand (matters for both likeness rights and the
  authored stat/move identity).

---

## Suggested resolution path (not a decision — just what unblocks the most)
1. **Get a human answer on B1** (real-money battle/betting on non-consenting real celebrities) — it gates
   B2 and all of Phase 3 go-live. Everything else is engineering; this is the one that isn't.
2. **Decide the currency model for the shared `bets`/`markets` table (A1)** — it's the spine of Phase 3.
3. **Confirm the launch-vs-fast-follow phase split (F1)** and the Emergency Fund live/sim call (E3).
4. **Pin the canonical home of `battle_archetype` + stats (C1)** and the Phase 1→2 ordering (C2) so the
   card retirement doesn't strand battle eligibility.
