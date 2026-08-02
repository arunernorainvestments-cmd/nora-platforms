# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-25.
# Rules for HOW to build any of this live in CLAUDE.md ("Building future work safely").
# Full specs / schemas / build history for anything referenced here live in ARCHIVE.md.
# Cross-repo (nora-arena) contract: RECONCILIATION.md. Doc map: README.md.
#
# ⚠️ v3 PIVOT (2026-07-01): the game is the "Moments" card-battler. Canonical spec:
# NORA_PLATFORMS_BUILD_SPEC_v3.md. P0–P6 SHIPPED (migs 116–137); the P7 launch-hygiene
# remainder is tracked HERE (§"P7"). The v2.x 1v1 archetype-fighter plan is RETIRED (bottom).

---

## Status snapshot (where we are, 2026-07-25)

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
- **Collections spec N1–N7 COMPLETE** (2026-07-23→25, migs 170–176, PRs #47–#53 — spec
  `NORA_PLATFORMS_COLLECTIONS_SPEC.md`, history in ARCHIVE "2026-07-23→25"): serialized `chit_copies`
  ("# of N"), Collections + primary sale + USD-first copy resale, profile surfaces, card-centric
  prediction markets (token-settled), **Mystery Box** (built, beta-**disabled**, boxes structurally
  unsellable — HR41), and **Clip Campaigns** (moderation-wall in RLS, escrowed payouts — HR42).
- **Admin console iteration 3** (mig 177, PR #54): campaign-clip review queue, `admin_audit_log`
  (append-only), the Mystery gate in Config, and the missing pg_cron schedule for campaign expiry.
- **Money-path audit — 6 bugs found, all fixed + prod-verified** (migs 178–180, PRs #55–#56). Every one
  was in a TypeScript edge function; every in-database plpgsql money path passed live invariant checks.
  Headline: **the token Markets rail had never settled a single market** — a void UPDATE failed a CHECK
  and the error was never inspected, so markets sat 'open' since 2026-04-12 while the run reported
  success. Also fixed: a Stripe double-credit race, payouts recorded that never happened, and
  read-then-write balance races that LOST debits. HR5 now encodes signed ledger amounts +
  "money math belongs in an RPC, not an edge function".
- **Migration ledger:** remote DB in sync at **184** (via `supabase db push`). 181–184 (Standard
  Playset S1–S4) **APPLIED 2026-08-01**, all apply-time smokes passed. Next push = 185.
  138–147 cinematic/minting-v2 · 148 chit display fields · 149 `{VIDEO_DESC}` · 150 mint-cancel ·
  151/152 effect library · 153–155 marketplace M1 · 156 marketplace M2 (USD seam) · 157–169 (see
  ARCHIVE) · 170–176 Collections N2–N7 · 177 admin iter 3 · 178–180 money-path audit fixes.
- **`flutter analyze`:** clean (2026-07-25); `flutter test` 5/5. **`deno check`:** ⚠️ 9 pre-existing fns fail under the
  Codespace's Deno 2.9/TS 5.7 strictness (`lkn-verify`, `resolve-markets`, `apply-promotion`,
  `arena-dev-*`, `hot-topic-resolve-week`, `likeness-{buy-listed,purchase}-card`,
  `ubi-assemble-voting-panel`) — type-level only, unrelated to recent work; sweep queued below.
- **Config flags:** `MINT_INGEST_MODE=live` · `MOMENT_CLASSIFY_MODE=sim` · `CINEMATIC_MODE=sim` ·
  `MODERATION_MODE=sim` · `MINT_CLIP_MODE=sim` · `SEGMIND_API_KEY` set · TikTok **sandbox** creds · IG none ·
  `battle_payments_mode=sim` · `marketplace_usd_lane=FALSE` · `mystery_pool_settings.mode=disabled`
  (G-MYSTERY) · `ALLOW_DEV_TOOLS` **still set — recommended to disarm now**, it keeps `arena-dev-reset`
  destructive-callable. Flipping any is a spend/creds/founder decision.

**Active build tracks — see "Where we're going next."**

---

## 2026-08-02 — ✅ FIXED: the mint pipeline's two silent degradations (the "Goggins → Goku" run)

> Founder report: minted a David Goggins clip; **card art came back Goku again**, and the cutscene
> had **no plate bookends and no audio** — the same symptoms as the Arnold-era regression. Traced to
> **two independent faults**, both of which had been failing SILENTLY (the wizard reported success).

**Fault 1 — kling-o3 rejects our trimmed clips: non-square pixels.** Prod switched the V2V core to
`kling-o3` on 2026-08-02 (Runway sunset `gen4_aleph` on 07-30). But the 2026-07-14 micro-trial had
ALREADY found kling's technical input check — *"non-square pixels detected, PAR should be 1:1"* — and
the fix (`setsar=1` in both trimmers) was **parked** because Aleph was working at the time. Switching
providers made the parked bug the live bug. The stored Goggins clip: `1280x706, SAR 25247:25252`. The
SAR comes from our own filter chain — the `-2` height rounding makes ffmpeg fudge the SAR to preserve
the display aspect (`1918x1058 → 1280x706 SAR 30775:30778`). Every kling call therefore failed
(`"The model did not produce an output"`), the mint fell back to Seedance, and the fallback costs the
restyle, the ORIGINAL audio, and the plate bookends (`bookendsOn` requires `v2vUsed !== null`).
- **Fixed** in BOTH trim paths (must stay in lockstep): square the pixels first
  (`scale='if(gt(sar,0),trunc(iw*sar/2)*2,iw)':ih`, a no-op at SAR 1:1, and it corrects a true
  anamorphic source at its display geometry), then the existing 1280 cap + 720 width floor, then
  `setsar=1`. Verified across odd-ratio / anamorphic (both directions) / portrait / unknown-SAR sources.
- **PROVEN on prod, not assumed:** the staged clip was repaired in place (`setsar=1` re-encode, original
  backed up beside it as `clip.presar1.mp4`) and re-submitted through `dev-segmind-probe` — kling-o3
  **accepted it and rendered** (req `fe8021a9df9228bb0ece4b8c45eb7ce8`, 114s, 5.1MB, 1292x712) **with the
  original 4.35s AAC soundtrack intact** (`keep_audio`). Same clip, same prompt, same card-art ref that
  failed 40 minutes earlier. Output parked at `mint-staging/v2v-trials/`.

**Fault 2 — the invalid `ANTHROPIC_API_KEY` is what makes the art generic (this is the "Goku" cause).**
`MOMENT_CLASSIFY_MODE=live` is set correctly, but prod's key returns **HTTP 401 "API key is invalid"**
(visible in the edge logs as `pre-gen moderation fail-closed: provider_error_401`). `liveClassify` and
`describeClipFrames` both **swallowed** the non-OK response and returned the placeholder — so
`subject_desc` was *"Nora in their signature moment"* and `video_desc` the stub. `{SUBJECT_DESC}` is the
only post-derived slot in the illustration prompt, so with nothing real in it the model draws the
archetypal shonen hero — the identical failure as the 2026-07-13 DBZ audit, and an IP exposure as well as
a quality one. **The V2V restyle then inherits it**: the trial above came back on-model with the card art,
i.e. a cel-shaded Goku doing the real bench press, with the real audio.
- **Fixed (visibility, not the key):** both call sites now log status + body, `moment-classify` returns a
  `degraded` reason, and the wizard warns at Review — *before* the user pays for a render — that the art
  can only be generic. sim mode reports `classify_mode_sim` for the same reason.
- ⚠️ **FOUNDER ACTION — nothing else will fix the art:** set a valid key, then restore live moderation:
  `supabase secrets set ANTHROPIC_API_KEY=sk-ant-…` then `MODERATION_MODE=live` (in that order — live
  mode fail-closes on a bad key and every mint reports "did not pass content moderation"). The same key
  breaks Hot Topic scoring (pg_cron, twice daily) and the Emergency Fund evaluator. `MODERATION_MODE=sim`
  since 2026-08-02 was to be reverted by **2026-08-05**.

**Re-minting the Goggins card:** its clip is already repaired, so retire chit `8b522f3c` to release
moment `552c6b30` and generate again — but do the API key first, or the art will be generic a third time.

**Key reactivated 03:52 → attempt 3 is a fully healthy run** (`v2v_provider: kling-o3`,
`audio_source: original`, real vision-derived `subject_desc` + `video_desc`, final MP4 8.14s vs a
4.4s core = bookends present, zero failure lines in the edge logs). Both faults above are closed.

### ⚠️ FOUNDER DECISION 2026-08-02 — real-person LIKENESS is now allowed on every mint

The art was still "nothing to do with Goggins" after the key came back, because three separate
layers were *instructing* it not to be him: the classifier wrote `subject_desc` with "no names of
real third parties", and both `illustrationPrompt` and `v2vRestylePrompt` demanded "an original
character design / no celebrity likeness". Founder call, made with the exposure stated: **allow a
stylized likeness of the real person on every mint, house seeds of public figures included.**

- **Changed:** `illustrationPrompt` now asks for "a faithful stylized likeness of the real person…
  keep their build, face, hair and clothing recognizable"; `v2vRestylePrompt` gained a `[LIKENESS]`
  block ("stylized but not replaced"); the classifier now describes the PERSON and may name a
  recognizable public figure.
- **UNCHANGED and not in scope:** the copyrighted-FICTIONAL-character ban (the 2026-07-13 DBZ audit
  guardrail) survives in both prompts, with a test pinning it. Real face ≠ Goku.
- **🔴 ACCEPTED RISK, revisit before public launch:** an unlicensed right-of-publicity likeness of a
  real public figure can now reach a **tradeable** asset. This is the exposure the `lkn_*` licensing
  rail exists to clear and it stacks with deferred IP item 7. It is fine for single-operator
  pre-launch authoring; it is **not** fine at open signup. Options when revisited: gate likeness to
  OAuth-owned moments only (the user's own face), or clear celebrity seeds through `lkn_agreements`.
  Consider promoting this to a Hard Rule either way — it is currently prompt text, so a future
  "cleanup" could silently revert it.

**Second defect fixed in the same pass — the classifier was blind to the footage.** `subject_desc`
described the ACTIVITY ("bench pressing a heavy barbell in a raw gym setting"), so the model drew a
*scene* instead of a hero portrait; and because a platform-seed moment has **no thumbnail**, the
classifier had only the post title to go on and contradicted the real clip (title said bench press,
the footage is DUMBBELLS — the art came back with a barbell). `moment-classify` now signs up to 3
frames of the actual uploaded clip and sends those, falling back to the thumbnail, then to text; the
system prompt tells it the frames are ground truth when they disagree with the title, and to
describe who is in frame rather than what they are doing.

---

## 2026-08-01 — ✅ APPLIED TO PROD: Standard Playset S1–S4 (migs 181–184)

> **Applied 2026-08-01** (same day, later session). Root cause it fixed: the web app auto-deploys
> from `main` but migrations are manual, so prod ran schema 180 against a client built for 184.
> `moment_chits.is_starter` did not exist → PostgREST 42703 → **"Could not load your collection"**
> on My BattleChits, plus a silently broken public profile, founding-cohort row, and a 404 on
> `mint-reveal-compose`. `db push` applied all four cleanly; every smoke passed; **30 starter cards
> seeded, 210 grants across 7 accounts** (backfill). `mint-reveal-compose` deployed. Verified via
> the REST API: 30 starters, tier spread F10/E9/D7/C4, 20 creatures / 10 spells, 10 families,
> **0/30 with card art, 0/30 with cutscenes**. Steps 1–3 below are DONE; step 4 (stitch worker) is
> **still outstanding**.
>
> ⚠️ **Structural follow-up:** nothing in `.github/workflows/deploy.yml` runs `supabase db push`, so
> any merge pairing a schema change with client code that reads it will ship the client first and
> break prod again. Worth gating web deploy on migration parity.

Spec: `NORA_PLATFORMS_STANDARD_PLAYSET_SPEC.md`. Branch `playset-standard-set`, six commits
(S1 · S2 · S3 · S4 · docs · `--clip`), merged. `flutter analyze` clean, `flutter test` 5/5,
`deno check` clean on everything new.

**Rollout status:**
1. ✅ `supabase db push` — 181–184 applied 2026-08-01, all smokes passed. 30 cards seeded,
   210 grants across 7 accounts.
2. ✅ Coverage contract verified via REST + the migrations' own apply-time smokes. (The
   `seed_playset.ts --report` path needs a service-role key and was not run.)
3. ✅ `supabase functions deploy mint-reveal-compose --no-verify-jwt` — deployed; now 401 (was 404).
4. ⏭️ **STILL OUTSTANDING** — redeploy the Cloud Run stitch worker; `workers/stitch/server.js`
   gained the `watermark` overlay the reveal composer needs. Requires GCP auth (project
   `nora-stitch-v2`). Until then reveals degrade honestly (share sheet still works).

**CLI constraint found while applying:** this repo's `config.toml` needs supabase CLI **≥ ~2.75**
(v2.30 fails to parse it; v2.111 is a bun rewrite that crashes in Codespaces). **v2.75.5 works.**
Also: the migration history is **not replayable from scratch** — a local `db reset` dies at mig 013
(drops `heat_score` while `trg_update_spotlight` still depends on it), so local validation of new
migrations is not available; rely on the apply-time smokes.

**⚠️ The cards ship with NO ARTWORK.** `card_art_url` is null on all 30, so CardFace renders its
fallback: mechanically complete, visually bare. `--render-art` (Segmind image, one call per card)
or hand-authored art via `--attach` fills it. Worth sequencing before public exposure — a blank
starter set is the first thing every new user sees.

- **S1 (mig 181) — admin seed path + generic/starter enforcement.** `admin_seed_moment` /
  `admin_seed_chit` / `admin_seed_attach_media` (service-only): platform Lane-A content, moderated
  like everything else, stats ladder-derived, tier targeted by the band's engagement floor. Closed
  the four leak paths N6 left open on generics — barter, wager escrow, `collection_chits`,
  ascension — and made starters **unserialized** so a 2-copies-per-account grant cannot exhaust the
  1000-serial supply cap (that was a latent signup-breaking bug the moment a playset shipped).
- **S2 (mig 182) — the 30-card slate + the grant.** 10 families × 3 (2 creatures + 1 spell),
  F10/E9/D7/C4, no A/S. Covers all 4 timing types, all 4 keywords, and **all six** active launch
  fusion rules with starters alone. `grant_starter_playset` is idempotent per **(account, card)** —
  so cards authored after launch top up existing accounts automatically, and
  `tools/playset/seed_playset.ts --add` authors one end-to-end (ladder-derived, granted to all).
  Wired best-effort into `handle_new_user`, self-healed by `claim_starter_playset()`, and
  backfilled to every existing non-test account.
- **S3 (mig 183 + `tools/marketing/`) — marketing pipeline.** Spot briefs, render ledger (the
  `cinematic_generations` twin — REPO-CHECK S3.1 resolved as "twin", since a spot has no moment and
  no plate FKs), a budget cap that refuses the render rather than reporting it afterwards, the
  G-COLL language ban enforced on ad copy by trigger, and a publish gate that RAISEs without a named
  human reviewer. Six launch spots seeded as briefs, incl. the **Nov 19** gamer drop.
- **S4 (mig 184 + `mint-reveal-compose` + stitch watermark) — the share loop + cohort.** Every mint
  ends on a 9:16 reveal with one-tap share and a referral-carrying join link; `is_founding_market_maker`
  + cosmetic badge + `/market` featured row; runbook at `tools/playset/FOUNDING_COHORT_RUNBOOK.md`.

**Open [FOUNDER] items surfaced by this build (none guessed):**
1. Approve the final 30-card slate (§1.3 sourcing brief → the shipped names) and schedule the single
   counsel pass over it **plus** the reveal template and all S3 marketing copy (gate **G-IP**).
2. `marketing_budget_config.cap_cents` is **0** — no marketing spend is authorised until it is raised.
   Calibrate per-render cost from `tools/cinematic/trial_*.ts` first (spec §4 Q12).
3. Name the human who owns pre-publish review (`reviewed_by`; spec §4 Q13).
4. Select the 10–25 Founding Market Makers and decide whether their mints get **live** renders
   (the strongest case for unlocking Segmind spend early).
5. Author + review the reveal watermark plate (`battle-media/reveal/nora_reveal_watermark_v1.png`) —
   it will be the most-seen artifact the platform produces.
6. Playset trim lever: `starter_playset_settings` (`is_enabled`, `copies_per_card`) is config, not
   code — the planned sunset path as minted supply grows (spec §4 Q4).

### Open decisions carried out of the 2026-08-01 session (raised, not yet answered)

**A. Five weak cards in the shipped slate.** Found by deriving every card's real stats off the
ladder rather than reading the briefs. Fixing them is edits to the slate data in mig 182 and
nothing else, but the tier swaps must stay inside a family so the F10/E9/D7/C4 spread survives.

- **`Comeback Breath` (athlete, D, spell) does literally nothing.** Its effect is `heal` with
  target `self`; `ccg_apply_card_effect` only heals cards with a HP value and a spell has none, so
  it is a 3-cost blank. Athlete has no spell-friendly template (rush/highlight/secondwind are all
  self- or damage-targeted), so the clean fix is to make it a **creature** (3-cost 4/5 that heals
  itself 6) and give scientist the second spell (`formula` at E, "shield an ally 4" — ally-targeted,
  so it works). That breaks the per-family "2 creatures + 1 spell" smoke assertion, which would
  relax to per-family-3 plus a global 20 creatures / 10 spells.
- **Four cards cost more for the same effect**, because cost scales with tier but count-type
  effects carry `magnitude_scales = FALSE` (deliberately — an S-tier draw would otherwise draw 8).
  Flat effect + high tier = strictly worse card:
  `The Filibuster` (D, 3 Aura → refund 1) · `Hostile Acquisition` (D, 3 → draw 1) ·
  `The Clapback` (C, 4 → discard 1) · `Stunt Double Swap` (D, 3 → grant taunt).
  Each is beaten outright by a 1–2 cost card with the same effect **and** a body.
  Proposed swaps (within family, spread preserved): Filibuster→F / Local Legend→D ·
  Acquisition→F / Caper→D · Clapback→F / Ring Light→C · Stunt Double→F / Understudy→D.
- Cosmetic: musician, comedian and gamer all read as "damage to ALL enemies" at F/E — samey.

**B. Whether to hold 183/184 back from the launch push.** They are inert (new tables nobody reads,
columns nobody writes, a worker param no existing caller sends), so applying all four is safe. If
the smallest possible launch surface is wanted, S3+S4 can move to their own branch so `db push`
carries only 181+182. Not done — it would rewrite history again and the migrations are harmless.

**C. Source footage for the 30 cutscenes.** `--clip` (2026-08-01) is the pipeline half: local file
→ staged → Segmind V2V restyle → stored for review → `--attach`. Sim mode exercises it with no
spend. Note the practical constraint: the V2V providers screen the **input**, and recognisable
likeness/copyrighted footage trips it — `CINEMATIC_SKIP_PROVIDER_MODERATION` only bypasses the
Seedance layer, not the V2V models, and the platform's own post-gen screen is never skippable.
Test cards and shipped cards need not be the same set: `--clip` produces a file, and nothing
reaches a player until a human attaches it.

---

## 2026-07-19 — ✅ SHIPPED + DEPLOYED (PRs #39–#45): deck-builder, /arena v3, admin iter 2, P7 7.5 VERIFIED, RLS-recursion fix

One pass through the post-sweep queue (parked items untouched per founder: dead-code
deletions, Phase 2 morph bridges, P7 7.2 archival, 7.4 reset). All merged same day;
migs 168+169 pushed to prod (ledger at **169**); admin-review redeployed; web CI green.

**Same-day follow-through (founder token supplied):**
- **P7 7.5 CLOSED for its two e2e legs, run against PROD:** `smoke_crossplay.ts`
  (deck-entry pair → RLS hand privacy → real summon turn → forfeit) and
  `smoke_money_roundtrip.ts` (G-MON market over a real queue-paired match →
  combatant-bet + non-KYC-bet guards RAISE → $10/$6 sim-USD bets → summon → forfeit →
  settlement asserted **to the cent**: predictors 1280¢, winner 96¢, loser 32¢,
  **moment-owner royalty 32¢**, passive holders 40¢/40¢, platform 80¢ retained).
- **mig 169 (PRs #43–#45): CCG RLS recursion fix — a REAL prod bug the smoke caught.**
  The mig-126 participant policies were mutually recursive (matches↔players); every
  authenticated read of `ccg_match_players`/`ccg_match_cards` raised "infinite
  recursion" — the web play client's hand/seat/resume reads had been silently erroring
  into empty states since launch of the play client. Fixed with SECURITY DEFINER
  helpers (`ccg_is_participant`/`ccg_participant_seat`/`ccg_match_is_test`); privacy
  line unchanged (own hand only; field/graveyard spectator-visible). The crossplay
  smoke now FAILS on read errors instead of passing vacuously.
- Residual smoke identities (`crossplay-smoke-*`, `money-smoke-*`) are FK-anchored
  (append-only ledgers) — flagged `is_test_account` (HR15) and added to the 7.4 sweep.
- ⚠️ The session's SUPABASE_ACCESS_TOKEN appeared in transcript → rotation list.
1. **Web deck-builder** (PR #39): `/decks` list (create/rename/delete, legality chips)
   + `/decks/:id` editor (copy steppers capped at min(owned,2), live 20-count, Aura-curve
   histogram, CardFace preview, friendly `deck_set_chits` validation errors). Unblocks a
   real user fielding a 20-card deck from the web — the P7 deck-entry prerequisite.
2. **/arena rebuilt as the v3 Moments Arena hub** (PR #39): the page still sold the
   retired Phase-D creator arena. Now: mint→deck→battle loop, crossplay queue CTA, live
   CCG spectate tiles, resume banner; legacy creator arena demoted to a collapsed
   section (screens NOT deleted — gated retirement stands).
3. **Admin console iteration 2** (PR #40, **mig 168** — APPLIED; fn redeployed): Users
   tab (search; flags; KYC *status*; balance; audited token adjustments — new
   `admin_adjustment` ledger type, balance-guarded, note required), Config tab
   (kill-switches over platform_integrity_settings; `enforce_one_role_per_match`
   rendered locked-ON and NOT toggleable; USD lane + payments-mode as danger founder
   gates), Market tab (admin delist → escrow returns to seller, same money semantics
   as seller delist). Hamburger menu shows "Admin console" to is_admin users.
   **Login: noraplatforms.com/admin.** NOTE (found applying the mig):
   `token_transactions.reference_id` is **TEXT on prod** (drift vs mig 002's uuid).
4. **P7 7.5 money round-trip smoke** (PR #41 + fixes): `tools/battle/
   smoke_money_roundtrip.ts` — ✅ RUN AND PASSED on prod same day (see above).
5. **Hygiene** (PR #41): `deno check` clean on ALL edge fns (the 9 pre-existing
   failures — untyped-client generics, pkcs8 buffer type, builder `.catch`); **icon
   tree-shaking re-enabled in CI** (MaterialIcons 1.6MB→32KB; C10 closed).

---

## 2026-07-18 — ✅ SHIPPED: POC leftovers + launch-hygiene UX phase + admin MVP (PRs #33–#38)

One sweep through the standing queue (everything below deployed to prod same day):
1. **POC gaps 2+3** (PR #33, mig 167): chosen card name survives any resume
   (`cinematic_generations.requested_name` + parked-render stash + `moment-ingest
   draft_name` + wizard prefill); attempt now derives from `max(attempt)+1` so a
   post-delete re-mint never overwrites the prior attempt's stored MP4.
2. **Web shell launch hygiene** (PR #34): branded splash, viewport meta, v3
   title/description, OG/Twitter cards + `og-image.jpg` (from the NORA Rocket key
   art), branded manifest, themed 404 (GoRouter errorBuilder), per-route document
   titles. **`tools/site_diagnostic.sh` exits 0 against prod.** (Icons were already
   NORA art — no replacement needed. Item C icon tree-shaking still open, budget passes.)
3. **Mint wait UX** (PR #35): elapsed clock + "usually 1–3 minutes" on Generating,
   retry-is-safe copy on failure, and the Review step now shows the server-selected
   effect's description (`moment-classify` returns `effect_desc`) — item 8's
   held-for-review state had already shipped with the violence-hold flow.
4. **Spectate feed** (PR #36): the engine's `'effect'` events (migs 128/151/152) now
   render as readable lines across the full Wave-1 kind/target vocabulary; all other
   emitted event types verified covered; vibe meter confirmed on spectate + play.
5. **Marketplace loop VERIFIED on prod** (PR #37): new repeatable
   `tools/marketplace/smoke_market_loop.ts` drives the exact UI RPCs — list (escrow
   asserted) → delist (copy returned) → re-list → cross-account buy (tokens moved
   price-for-price, `chit_sale`/`chit_purchase` rows, listing `sold`, provenance
   stamped `tokens`). A founder browser click-through remains a nice-to-have.
6. **Admin console MVP** (PR #38, `/admin` + `admin-review` edge fn): moderation
   review queue (held cutscenes w/ signed frames, approve/reject/reopen), open
   escalations (resolve; minor-safety never auto-approves), similarity-flagged clip
   verdicts, stuck mint-job detection + mark-failed. Gated on `profiles.is_admin`
   (founder flagged; 401/403 verified live). The held-for-review flow no longer
   needs raw SQL — and 8 real open escalations surfaced on first load.
   NOT yet in the MVP (next iterations): user/account ops, config/kill-switches,
   token adjustments, marketplace disputes — see the 2026-07-15 callout below.

Deliberately NOT touched per founder: dead-code deletions (campaigns/discover/
notifications) and Phase 2 morph bridges.

---

## 2026-07-15 — ✅ PROOF OF CONCEPT: the mint pipeline works E2E (revert anchor `poc-v2v-mint-2026-07-15`)

Founder-verified on prod: chit **87f599ae "You're Fired"** (moment 66c370f4, gen 5e5c6326) —
the source clip **stylized into the game's cel-shaded animation with the ORIGINAL audio kept**,
past live moderation, resumable at every failure point. Founder: "This is proof of concept…
literally exactly what we want going forward." If a later change breaks the pipeline, this is
the state to revert to:

- **Git**: main @ `8b40d99` (tag `poc-v2v-mint-2026-07-15`). Includes: V2V core (PR #27),
  violence hold-for-review + sports carve-out (PR #28), wizard resume surface (PR #29).
- **Config (edge secrets)**: `CINEMATIC_V2V_PROVIDER=runway-aleph` ·
  `CINEMATIC_SKIP_PROVIDER_MODERATION=true` · `CINEMATIC_MODE=live` · `MODERATION_MODE=live` ·
  `MOMENT_CLASSIFY_MODE=live` · `MINT_INGEST_MODE=live` · render tier default (720p).
- **Pipeline shape**: ingest → clip trim (browser wasm, cloud `/trim` fallback) → attach +
  re-moderation + live clip desc → classify → card art (clip mid-frame reference) →
  **Runway Aleph V2V restyle of the actual clip** (one RAI re-roll, then Seedance fallback) →
  stitch-worker **original-audio overlay** → post-gen screening (violence → HOLD, others hard)
  → complete → preview battle → finalize. Stitch worker rev `nora-stitch-00004`.
- **Known gaps at this checkpoint** (next refinements, in founder priority order):
  1. ✅ **SHIPPED 2026-07-15 (same day): plate bookends composed INTO the final MP4** —
     `CINEMATIC_PLATE_BOOKENDS=stitch` is LIVE. The stitch worker (rev `nora-stitch-00007`)
     gained still-image segments (zoompan push-in/pull-back on the house 16:9 agnostic
     plates), `xfade` transitions (fadewhite seams; `setsar=1` normalization — xfade
     refuses mismatched SAR), and `audio_from_segment`; `cinematic-mint` composes
     start-plate → core → end-plate + audio in ONE worker pass (best-effort: any compose
     failure falls back to the plain overlay/store — bookends never fail a mint).
     Deterministic + free + house-owned imagery; post-gen screening runs on the COMPOSED
     final. Verified on the Arnold cutscene (4.6s, audio offset correct). REVERT = delete
     the `CINEMATIC_PLATE_BOOKENDS` edge secret (media pipeline returns to the checkpoint
     behavior). NOTE: GCP Secret Manager entries were recreated this session (they had
     vanished) — new STITCH_SECRET synced to edge secrets. **Phase 2 (fallback/upgrade,
     only if the crossfade seam feels cheap): Seedance first/last-frame micro-bridges**
     (plate→core-frame morphs), stitched with the same worker.
     Also shipped same-day: **summon-cutscene playback in /collection** (card detail →
     "Watch summon cutscene", shared `CutsceneVideo` widget with the mint preview).
     **Phase 1b same-day (PR #31, mig 166): ANIMATED universal bookends LIVE** — two
     one-time Seedance generations (house plates + white-frame conditioning; only house
     imagery reached the provider) now bracket every mint: intro 2.0s (card energy vortex →
     camera into the igniting core → full-frame white flash) and outro 2.5s (white flash →
     lightning/glass-shard shockwave → settled energy core), stored at
     `battle-media/plates/agnostic/v1/{intro,outro}.mp4` with 4s raw masters in
     `mint-staging/v2v-trials/`. White-into-white fadewhite seams splice invisibly onto ANY
     core. `match_cut_anchor_plates.start/end_motion_url` (mig 166) — set NULL to revert to
     the zoompan stills; probe gained the `plate_motion` one-time submit mode.
  2. ✅ SHIPPED 2026-07-18 (PR #33) — the chosen name survives resume (mig 167).
  3. ✅ SHIPPED 2026-07-18 (PR #33) — attempt derived from history, no overwrite.

---

## 2026-07-15 — CALLOUT: Admin app / operations console (needed pre-scale; not yet scoped)

Founder call-out, not a plan yet: the platform needs an **admin surface** with built-in
functionality that streamlines the issues we can already predict once many users are on the
app. Today every operational intervention is raw SQL / management-API calls by hand. Known
needs observed so far (seed list for whenever this gets scoped — deliberately not designed now):
- **Moderation review queue** — the new held-for-review flow (2026-07-15: `graphic_violence`
  HOLDS post-gen instead of hard-rejecting; nsfw/hate/minor_safety stay hard) needs a human
  surface: view sampled frames, approve/reject (`cinematic_moderation_verdict`), see escalations
  (`moderation_escalations`), clip similarity-mismatch flags, and third-party-likeness flags.
  Extending hold-for-review to the two PRE-gen screens (ingest thumbnail, clip-attach) is
  blocked on this existing — a pre-gen hold today would be a dead end with no clear path.
- Mint pipeline ops: stuck/parked `mint_jobs`, re-run/refund decisions, provider-state inspection
  (today: `dev-segmind-probe`, which must be DELETED before launch — the admin app replaces it).
- User/account ops: KYC state, identity_hash collisions, test-account flags, token adjustments
  (audited via `token_transactions`), marketplace disputes/delistings.
- Config/kill-switches behind auth instead of raw secrets edits (mode flags, provider selection,
  spend caps, `marketplace_usd_lane`, `battle_payments_mode`).
- Emergency Fund + licensing ops respect their privacy Hard Rules (23–25, 29–32) — admin sees
  status/queues, never private votes or ubi documents.

---

## 2026-07-14 — Founder feedback after the first fully-working E2E mint (RESUME HERE)

The Tom Brady mint completed end-to-end on prod (chit 7af184fb): ingest → cloud-trim fallback →
live classify → illustration → async render → park/auto-resume → live screening → card.

**What now WORKS (founder-verified):**
- The card face: "looks good… captures the spirit of exactly what we are going for."
- Live Claude vision reading the clip + producing the description "works well for the card."
- Delete card → re-mint loop; cloud-trim fallback (browser wasm OOM → stitch-worker ffmpeg);
  async render survival + auto-resume (PR #24); live moderation auto-approving clean output.

**What still needs work (founder feedback, next iteration):**
1. **The cutscene doesn't use the source media.** ByteDance rejected the (third-party NFL) clip
   as a reference for copyright, so the video fell back to prompt-only — nothing of the actual
   moment is in it. Founder view: heavy-handed, given consented/linked accounts and the amount
   of such content recirculating publicly; there is also no channel to tell the provider "we
   have consent from the person via their linked social account."
   Next-iteration tracks (in order):
   a. **Verify the core case first**: a SELF-SHOT, first-party clip through the clip-reference
      path — still unverified whether ByteDance's filter passes ordinary owned footage or
      blocks any real face. This decides everything below.
   b. **Stylize-first (Track A / V2V, Minting_Workflow §2)** — this is exactly the case the
      spec's "stylize-first order is load-bearing" note anticipated: restyle the clip into
      cel-shaded animation with a V2V-capable model FIRST (runway-gen4-aleph was the audited
      candidate; also evaluate Grok Imagine per founder, Wan/Kling on Segmind), then feed the
      STYLIZED (no-real-likeness) footage to Seedance as the reference / core. May fix both
      the likeness-filter and copyright-filter false positives without policy games.
   c. **Provider evaluation** — docs-verified 2026-07-14, micro-trial is the next step
      (founder OK with dropping ByteDance for the core):
      * **Kling O3 video2video-edit (Segmind, Kuaishou)** — strongest fit: input video →
        prompt restyle, 3–15s output, **keep_audio preserves the ORIGINAL soundtrack by
        default** (kills feedback item 2 for free), up to 4 `@Image` refs (pass the card
        illustration for character consistency). Input moderation undocumented → trial with
        the Arnold/Brady clips decides.
      * **Runway Gen-4 Aleph (Segmind)** — required `video` (≤16MB; our trims are 1–3MB),
        restyle prompt + `reference_image`, seeded; "Content/RAI blocks surface as FAILED"
        (nature unknown). Silent output → lay original clip audio via the stitch worker's
        existing audio-overlay path.
      * Pipeline either way = Track A collapsed to one V2V call: trimmed clip → restyle with
        the style-lock prompt + card-art reference → cel-shaded core WITH audio → Unity
        zoom-in/impact-flash covers the seams (or stitch plate bridges) → battle-media.
        Seedance remains for no-clip mints only. Also on the eval list: Grok Imagine
        (off-Segmind), Wan (self-hosted, zero input policy).
   d. For genuinely third-party celebrity moments (like this NFL clip): that content is what
      the **licensed lane (lkn_*) exists for** — the consent story only covers the LINKED
      account's own posts. Product answer may be "self/owned moments = clip-referenced;
      celebrity moments = licensed packs with cleared media."
2. **No audio on the cutscene.** Two cheap fixes to trial: flip Seedance's `generate_audio`
   (we currently omit it → false) for generated SFX, and/or lay the ORIGINAL clip audio under
   the cutscene via the stitch worker's existing audio-overlay path (`/stitch` already
   supports it; `keep_audio` is already collected at trim) — the Minting_Workflow §2 plan.
3. General output tuning once (1) lands: judge bookend quality of clip-mode's prompt-described
   card-back/impact-flash vs the plate-anchored no-clip mode; `CINEMATIC_RENDER_TIER=standard`
   (1080p) when ready to pay for final quality.

**BUILD 2026-07-14 (items 1c + 2 — code complete, sim-verified; deploy + paid trial pending):**
- **V2V client** in `_shared/segmind.ts`: `generateV2VRestyle` (sim) + `submitV2VRestyle`
  (Segmind v2 async queue) for **`kling-o3-video2video-edit`** and **`runway-gen4-aleph`**
  (schemas re-verified against Segmind docs — NOTE Kling `keep_audio` actually defaults
  FALSE, we set it explicitly; `duration` is a string 3–15; no seed param; input width
  must be 720–2160px. Aleph: `video` ≤16MB + `reference_image` + int seed; silent output).
  House restyle prompt `v2vRestylePrompt` in `cinematic_directives.ts` (style-lock +
  constraints constant, slots sanitized — tests added).
- **cinematic-mint wired** behind **`CINEMATIC_V2V_PROVIDER`** (unset = today's Seedance
  behavior): clip mode restyles the trimmed clip into the core (card art as character ref),
  same park/resume stash (v2v fields added), fallback chain V2V → Seedance-with-clip →
  prompt-only (never bricks). Ledger: mig **165** adds `v2v_provider` + `audio_source`.
- **Audio (item 2) built both ways**: Seedance calls now send `generate_audio: true`
  (`CINEMATIC_SEEDANCE_AUDIO=off` to disable); Kling keeps the original soundtrack
  (`keep_audio`, honoring `clip_keep_audio`); a silent Aleph core gets the original clip
  audio laid back in via the stitch worker `/stitch` overlay (tier-matched canvas,
  best-effort — failure stores the silent core).
- **Micro-trial surface**: `dev-segmind-probe` gained POST `{v2v, moment_id, …}` (signs the
  moderated clip, assembles the prompt, submits) and `?id=…&store=1` (bytes → private
  `mint-staging/v2v-trials/`, signed review URL); runner `tools/cinematic/trial_v2v.ts`
  needs only `DEV_PROBE_SECRET`. Run it on the Arnold + Brady moments — that decides the
  provider, then flip `CINEMATIC_V2V_PROVIDER`.
- **Discovered in the Seedance schema while verifying:** a `skip_moderation` boolean
  ("bypasses BytePlus content filter") exists on Seedance 2.0 — a possible answer to the
  heavy-handed input-copyright filter on the SEEDANCE path, but it's a founder policy call
  (interacts with deferred IP-exposure item 7 + our own screens stay absolute). NOT wired.
- **DEPLOYED + TRIALED same day (founder token supplied):** mig 165 applied (`db push`,
  ledger at 165), both fns deployed (`--no-verify-jwt --use-api`), fresh `DEV_PROBE_SECRET`
  set (old value was lost — rotated), DB password re-reset (management API — the standing
  runbook). **Micro-trial on the ARNOLD clip (the ByteDance-rejected worst case):**
  * **runway-gen4-aleph: PASSED E2E** — accepted the real-face celebrity clip, rendered a
    1.35MB cel-shaded core (req 315eddb9d…, seed 1008167968, output parked at
    `mint-staging/v2v-trials/`), frames verified on-style (bold ink-outline cel look,
    original stylized character), live post-gen screen APPROVED it.
    **→ `CINEMATIC_V2V_PROVIDER=runway-aleph` is LIVE on prod.**
  * **kling-o3: failed on a TECHNICAL input check, not moderation** — "non-square pixels
    detected, PAR should be 1:1": our trimmed clips carry a non-1:1 pixel aspect ratio.
    Fix if Kling is ever wanted: `setsar=1` in both trimmers (nora_trim.js + worker /trim).
    Parked — Aleph + the stitch audio overlay already covers audio.
    **→ UNPARKED THE HARD WAY (2026-08-02):** Aleph was sunset, prod switched to kling-o3,
    and this parked bug became the live one — three days of mints silently losing the
    restyle, the audio and the bookends. Fixed + prod-proven; see the 2026-08-02 entry at
    the top. Lesson for the next park: a known provider-input defect is only "parked" while
    that provider is unused — re-read the trial notes BEFORE flipping `CINEMATIC_V2V_PROVIDER`.
- **Also flipped (founder call 2026-07-14, "IP-exposure is not a block for testing"):**
  `CINEMATIC_SKIP_PROVIDER_MODERATION=true` — sends Seedance's documented `skip_moderation`
  (bypasses the BytePlus INPUT filter only; NORA's own pre/post-gen screens are untouched
  and ran live on the trial output). Revisit with deferred IP item 7 before public launch.
- **Founder test next:** re-mint Arnold through the wizard (slot swap off the Brady chit is
  the expected flow). Note: Arnold's `clip_video_desc` is still the sim stub — re-attach
  the clip during the re-mint to get a live description; the restyle rides on the actual
  video either way. This session's token + service key appeared in transcript → rotation
  list (post-launch, pre-live).

---

## 2026-07-13 — Generation quality: the "DBZ card" audit (fix checklist 1–6 SHIPPED; see section above for what's next)

First fully-live user mint succeeded (async `mint_jobs` pipeline, migs 158–161, PRs #16–#19) but the
OUTPUT was wrong end to end: card art was a Dragon Ball–style character (nothing to do with the moment)
and the cutscene, while opening/closing exactly on the anchor plates, contained zero content from the
uploaded clip. Full trace (prod `cinematic_generations` row + code + Segmind/ByteDance docs) found five
causes — audit report artifact: https://claude.ai/code/artifact/cb7c960c-f87e-4c27-bbc2-4b1e19b3ec3c
(also summarized in agent memory `segmind-live`). None are fixed yet; this section is the checklist.

**Root causes (evidence in the report):**
- `MOMENT_CLASSIFY_MODE=sim` → `subject_desc` was the placeholder *"N O R A Platforms in their signature
  influencer moment"*; with the style-lock's "cel-shaded anime, dynamic hero pose" and no visual subject,
  Seedream drew the archetypal anime hero. The classifier never saw the thumbnail/clip.
- `MODERATION_MODE` **unset** on prod (→ sim) → the pre/post-gen safety screen is a deterministic stub
  AND `describeClipFrames` returned the stub `video_desc` ("the subject moves through their signature moment").
- The uploaded clip is **not wired into generation at all** in the current build (only moderated /
  described / stored) — the V2V core + bridges + stitch is Track A below, unbuilt. The live prompt
  templates carry no `{VIDEO_DESC}` slot (mig 149 feeds the future V2V node only).
- **API bug:** the Seedance call sends `reference_image_url` (singular, wrong name) ALONGSIDE
  first/last-frame conditioning — per Segmind docs the real param is `reference_images[]` and it is
  **mutually exclusive** with frame conditioning, so the card-art reference is silently dropped while the
  prompt says "kept exactly on-model from the reference illustration" → subjectless plates + light ribbons.
- **IP exposure:** the illustration CONSTRAINTS block never forbids existing/copyrighted characters or
  celebrity likeness, and the moderation screen classifies only nsfw/violence/hate/minor-safety — a
  recognizable copyrighted character passes onto a tradeable asset.

**Fix checklist — items 1–6 SHIPPED 2026-07-13 (migs 162–163 applied; cinematic-mint / mint-cancel /
moment-classify / moment-clip-attach redeployed):**
- [x] 1. `MOMENT_CLASSIFY_MODE=live` — Claude vision derives a real `subject_desc`.
- [x] 2. `MODERATION_MODE=live` — real safety classification + real `{VIDEO_DESC}` persistence.
      NOTE: moments clip-attached BEFORE the flip still carry the stub desc — re-attach (or re-mint
      after delete) to get a real one.
- [x] 3. `illustrationPrompt` hardened: "original character design… never any existing anime/manga/
      video-game/comic/cartoon character, no celebrity likeness, no franchise costume or hairstyle";
      style-lock reworded off "cel-shaded anime" to a house cel-shaded look.
- [x] 4. Seedance call fixed: `reference_image_url` removed (wrong name, silently dropped; the real
      `reference_images[]` is mutually exclusive with the mandatory plate bookends). Subject identity
      now travels in the prompt + the clip reference (below).
- [x] 5. **Clip wired into generation** (one call, replaces the specced three-node Track A):
      `cinematic-mint` signs the moderated `mint-staging` clip (≥2s trim) and sends it as
      `reference_videos[0]`; **prompt template v2** (mig 163, all 6 templates) carries a `{CLIP_REF}`
      slot ("recreate the subject and action of reference video 1…") that collapses when no clip
      rides. **Live-trial findings (2026-07-13/14, 5 paid runs, tools/cinematic/smoke_clip_mint.ts):**
      (a) ByteDance forbids reference media with ANY frame anchor (Segmind's doc claims only
      `reference_images` conflicts — wrong; and a FAILED async request reports as HTTP 422), so
      clip mode sends NO plates: constant `[OPENING]`/`[ENDING]` directives describe the card-back
      glow and the impact-flash whiteout, and Unity's zoom-in + flash particles cover both seams.
      No-clip mode keeps both plate bookends. **Trial 5 proved the clip path E2E on prod**
      (`clip_reference_used=true`, gen 95ea59da, proof media under moments/91226187…).
      (c) Edge background workers get reaped ~90s in → **async render survival** (mig 164): live
      cutscenes submit to Segmind's v2 queue, stash the request id on `mint_jobs.provider_state`,
      park at `cutscene_rendering` after 60s; any later Generate click resumes the SAME render
      free (results retained 1h provider-side).
      (d) **BLOCKER: the prod ANTHROPIC_API_KEY is INVALID (401)** — live classify silently falls
      back to the keyword heuristic and every live mint holds at post-gen screening (fail-closed).
      Needs a fresh key; until then unblock a held mint with
      `SELECT cinematic_moderation_verdict('<gen-id>', true, NULL)` + re-click Generate (free).
      (b) ByteDance also MODERATES input clips: third-party celebrity footage → 
      `InputVideoSensitiveContentDetected` (copyright). cinematic-mint degrades gracefully — one
      retry without the clip (prompt-only, both plates, `clip_reference_used=false`) so a flagged
      clip never bricks the mint. Whether ordinary self-shot face footage passes is UNVERIFIED —
      the founder's next real mint answers it. Track A (Wan/Kling/stitch) stays parked unless
      this path proves insufficient.
- [x] 6. Full assembled prompts + provider request ids + `clip_reference_used` persisted on
      `cinematic_generations` (mig 163).
- [ ] 7. DEFERRED (founder call 2026-07-13: IP-exposure work is secondary to a working pipeline) —
      add an IP/likeness flag to the post-gen screen prompt (hold recognizable copyrighted characters
      for review). The prompt-side constraints from item 3 are in force.

**Also shipped 2026-07-13 — delete a minted card (founder testing need):** `chit_delete_owned`
(mig 162) retires a FINALIZED self-minted chit (minter-only, no foreign-held copies, not
wagered/listed), frees the self-mint slot, purges decks, and releases the source moment for an
immediate re-mint; `mint-cancel` gained `allow_finalized: true` (deletes media too); /collection
card dialog gained a danger "Delete this card" action. Deleting + re-minting the same moment is
now the intended test loop.

---

## 2026-07-11 — ✅ SHIPPED 2026-07-18 (PRs #34/#35, except C10 icon tree-shaking + D11 dead-code): UI/UX shell + mint-flow polish (diagnostic-driven)

Founder asked for a UX audit ahead of today's live user mint test. Diagnostic run 2026-07-11:
`flutter analyze` 0 issues · `flutter test` 5/5 pass · **new repeatable check
`tools/site_diagnostic.sh`** (curl-based launch-surface audit; run against prod any time).
Result: routing (8 routes incl. /mint /market /battle), www→apex 308, and payload budget
(main.dart.js 1.26 MB gzipped < 1.5 MB) all PASS; **8 launch-hygiene checks FAIL** — those
failures are this phase's checklist. Acceptance = the script exits 0 against prod.

**A. Web shell / first impression (all in `flutter_app/web/` — no Dart, one PR):**
1. **Branded loading splash** in `index.html` (`id="nora-splash"`): logo + spinner on the
   existing #0A0A0F body; Flutter's first frame removes it. Today a first visit is a blank
   dark screen while 1.26 MB of JS loads. Add the missing `<meta name="viewport">` too.
2. **v3 meta copy**: `<title>` + description still say "creator prediction market" (pre-pivot).
   Rewrite for Moments (card-battler + markets, launch framing).
3. **Open Graph + Twitter card tags** — currently ZERO; links shared to socials render bare.
   Needs a 1200×630 og-image asset (founder to supply, or generate from card art).
4. **manifest.json**: still stock Flutter (`nora_platforms`, "A new Flutter project",
   theme #0175C2). Brand name/short_name/description; theme_color #6C63FF, background
   #0A0A0F; replace stock `icons/Icon-*.png` with NORA icons.
5. **Branded 404**: GoRouter has no `errorBuilder` — unknown URLs get the stock error text.
   Add a themed not-found screen with a home CTA.
6. **Per-route document titles** (browser tab/history currently one static title for every
   screen) — small GoRouter observer setting `document.title` per route.

**B. Mint flow, live-mode wait UX (`mint_moment_screen.dart` — matters now that Seedance is live):**
7. The `generating` step is one indeterminate spinner + "this can take a moment". Live renders
   take minutes. Stage the copy (illustrating → animating → safety screening), add an elapsed
   hint ("usually 1–3 minutes"), "keep this tab open", and — since the server resume path makes
   re-clicking Generate free — say so on failure/timeout instead of looking like a dead end.
8. Friendly held-for-review state for the 202 `pending_moderation` response (fail-closed screen
   moderation): explain the card isn't lost, it's queued for review; /collection already has the
   finalize-pending flow to complete it after approval.
9. Review step: show the server-selected effect + rules preview before Generate (carried from
   APP_INVENTORY §3 — user currently confirms a card without seeing its effect).

**C. Payload watch (not urgent — budget passes):**
10. CI builds with `--no-tree-shake-icons`; try re-enabling icon tree-shaking (find and fix
    whatever dynamic-icon usage forced it off) before the bundle creeps past budget.

**D. Carried from APP_INVENTORY (cheap, protects launch demos):**
11. Zero-risk dead-code deletions (campaigns/, discover/, notifications/, dead spotlight provider).
12. Spectate screen: verify Wave-1 effect-event vocabulary renders (migs 151/152 added kinds
    after the screen shipped) + confirm vibe meter displays.

---

## 2026-07-10 — ✅ SHIPPED 2026-07-11: nora-stitch redeployed to a new GCP project

Context: **CINEMATIC_MODE=live is ON and proven end-to-end** (PR #15, main `a2122f0`: real Seedance
cutscene + card art generated, frame-reviewed, approved, completed into a chit via the new resume
path). Spend guards shipped in `cinematic-mint`: pending-generation RESUME (zero provider calls on
re-click), per-user daily cap (`CINEMATIC_DAILY_CAP`, default 6), post-gen **screen** moderation
(stitch-worker frames → fail-closed classifier — Hard Rule 39). But the old GCP account's trial
expired → the **`nora-stitch` Cloud Run worker is DOWN** (persistent 503). Until rewired, live mints
generate fine and HOLD at "Held for safety review"; recovery = manual verdict
(`SELECT cinematic_moderation_verdict('<gen-id>', true, NULL)`) + re-click Generate (free resume).

Agreed plan (do in the Codespace session, not Gemini):
1. **User prerequisite (browser):** billing account with a payment method on the NEW Google account.
   Same Google account keeps YouTube OAuth on the OLD project untouched (OAuth needs no billing —
   but verify YT connect still works, and keep the old project alive so the OAuth client survives).
2. Install the gcloud CLI in the Codespace; user runs `! gcloud auth login` (new account).
3. Agent then: `gcloud projects create` → link billing → enable run/cloudbuild/artifactregistry →
   generate `STITCH_SECRET` (`openssl rand -hex 32`, NO trailing newline — the v1 gotcha) → deploy
   from repo root: `gcloud run deploy nora-stitch --source workers/stitch --project <NEW_ID>
   --region us-east1 --allow-unauthenticated --memory 2Gi --cpu 2 --timeout 300 --max-instances 3
   --min-instances 0 --set-env-vars SUPABASE_URL=https://cceisywxwhgljdpisjrl.supabase.co,
   STITCH_SECRET=…,SUPABASE_SERVICE_ROLE_KEY=…` (service key via the Supabase management API
   `api-keys?reveal=true` with the user's access token — ask the user for a fresh token).
4. Verify `GET <new-url>/status` → `{"ok":true}` (NOT /healthz — Cloud Run reserves it).
5. Update Supabase edge secrets `STITCH_WORKER_URL` + `STITCH_SECRET` (management API POST /secrets).
6. **Free E2E test:** re-call `cinematic-mint` as the cinematic-smoke user on a moment holding a
   'generated' row → resume re-screens via the new worker + completes, zero Segmind spend.
   (Pattern: tools/cinematic/smoke_mint.ts; smoke pwd = 'smoke-' + last 12 of service key.)

**Resolution (2026-07-11):** all six steps executed. New GCP project **`nora-stitch-v2`**
(account aruner.insurance@gmail.com, billing `014702-575901-BCFDD2`); worker live at
**`https://nora-stitch-747216546694.us-east1.run.app`** (`GET /status` → `{"ok":true}`); fresh
`STITCH_SECRET` set on both Cloud Run and Supabase edge secrets alongside the new
`STITCH_WORKER_URL`. Zero-spend E2E passed: no held row existed (yesterday's completed), so a
`'generated'` row was planted on storage-copied media from the 2026-07-10 live output → resume →
the NEW worker extracted 3 postgen frames into `mint-staging` → approved → chit `74a91243`
finalized (proof chit; yesterday's `cee4f6a2` was retired by the smoke slot-cleanup, its media
kept). Old GCP project stays alive for the YouTube OAuth client — verify YT connect on the next
real mint. Found in passing: **GoTrue admin `listUsers` 500s** ("Database error finding users") on
this project — `createUser`/`updateUserById` work fine; `tools/cinematic/smoke_mint.ts` relies on
listUsers as fallback, so set `SMOKE_USER_ID=42e7c0c8-5504-4aab-9aa3-f809fb97fc3c` when running it.

Also queued from the 2026-07-10 live test: flip `MODERATION_MODE=live` before public launch (pre-gen
+ screen classifier currently sim; ANTHROPIC_API_KEY already set); `CINEMATIC_RENDER_TIER` stays
`fast` (720p) until final-quality flip; card-art tuning (a Nike swoosh slipped past "no logos"; art
comes letterboxed in a white square canvas — want an aspect-ratio param or crop step).

---

## 2026-07-08 — post-M3 next steps (identified during the marketplace build + inventory audit)

What the M1–M3 build and the `APP_INVENTORY.md` sweep surfaced as needing modification, in rough
priority order. (Full row-level detail + verdicts live in APP_INVENTORY.md; this entry is the
timestamped pointer so the queue isn't lost.)

1. **Browser-verify the marketplace loop end-to-end** — mint → Sell from collection → buy with a second
   account → delist. Everything is analyze/PostgREST/prod-smoke-verified only; no live listing has ever
   been created through the UI. Also re-verify a fresh mint now that effects/rules populate (carried over).
2. **Ascension has NO user surface** — ✅ web half SHIPPED 2026-07-10: mig 157 (locks down the
   never-REVOKEd `moment_chit_rederive`/`chit_ascension_refresh`/`ccg_create_match`/
   `ccg_create_outcome_market` — the first was a live HR34 tamper vector — and makes the refresh return
   per-chit detail) + new `chit-ascension` edge fn (the live engagement re-read that mig 136 always
   assumed but nothing performed; readers shared with moment-ingest via `_shared/platform_meta.ts`) +
   `/collection` check-for-tier-ups button w/ tier-up celebration + review-queue/cooldown states.
   Unity mirror remains (same edge fn — RECONCILIATION).
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
  latest **2026-07-25**) and `NORA_SIGNING_PRIVATE_KEY` (known-compromised, generated in Codespace) — all
  post-launch, pre-live.
- **Collections-spec founder calls left open** (all surfaced, deliberately not self-answered):
  • **N5.2** — fate of the display-score markets. Default taken: they **run alongside** the new
    card-centric markets during beta. Retiring them is a product call.
  • **N6 / G-MYSTERY** — `mystery_pool_tier_config` payout rates + draw weights and `max_submit_pct`
    (20%) are placeholders. `mystery_pool_settings.mode` stays `disabled` until you flip it (now
    flippable from **/admin → Config**); the gameplay grant hooks get wired **with** that flip, not before.
  • **N7.1** — payout structure. Only the **per-accepted-clip** model is built (budget = payout × max,
    escrowed in full); contest/winner-takes-budget is **not**. `clip_campaign_fee_bps` (10%) is a placeholder.
  • **REPO-CHECK 1.1** — the two platform fee numbers in `platform_fee_config` are still placeholders.
- **Disarm `ALLOW_DEV_TOOLS`** (see P7 7.4). Not launch teardown — it keeps a destructive endpoint
  (`arena-dev-reset`: wipes arena state, hard-sets balances) callable on prod today.
- **Reconcile the drifted accounts.** `SELECT * FROM public.token_balance_drift();` (mig 180) lists real
  accounts whose balance ≠ ledger, caused by the now-struck manual top-up recipe. Each needs an explicit
  `admin_adjustment` (admin console → Users → Adjust tokens) — removing the dev tooling will NOT heal them.
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
      (`cinematic-smoke*@`, `mkt-smoke-1/2@`, `crossplay-smoke-*@`, `money-smoke-*@noraplatforms.com`
      + their ledger/sales residue — the crossplay/money ones are FK-anchored, all is_test-flagged).
      **Operational notes (money-path audit, 2026-07-25):**
      • **Unschedule BEFORE truncating.** `dev-test-match-maintainer` recreates a match within 2 min and
        `dev-bot-backer` starts backing it within 1 min, so truncating first just refills the tables.
      • **Also remove the `ALLOW_DEV_TOOLS` secret**, not just the crons — `arena-dev-reset` stays callable
        and destructive while it is set. (Recommended: disarm it NOW; it does not need to wait for launch.)
      • **Decide explicitly whether to purge the bot history.** As of 2026-07-25 the synthetic loop had
        produced 20k arena matches, 342k arena_events and **505,162 of 505,306 token_transactions rows
        (99.97%)**, growing ~100k rows/month since April. Retaining it means every future analytics or
        money-reconciliation query depends on the Hard Rule 15 test-account filter being right, forever.
      • **Strike the manual top-up recipe from ARCHIVE §A5** (`UPDATE token_balances SET available_tokens=…`).
        It writes a balance with no `token_transactions` row, which is what actually drifted the real
        (non-test) accounts — NOT the dev tools, which both filter to `is_test_account = true`. Post-mig-180
        the auditable way to move tokens by hand is an `admin_adjustment` via the admin console.
      • Removal does **not** heal existing drift: `SELECT * FROM public.token_balance_drift()` (mig 180)
        lists the accounts still off, and each needs an explicit `admin_adjustment` to reconcile.
- [x] **7.5 Final verification** — ✅ DONE 2026-07-19: `flutter analyze` clean; **real-money round-trip
      PASSED on prod** (`tools/battle/smoke_money_roundtrip.ts` — 2 sim-KYC users, sim USD: G-MON market →
      guarded bets → settle → moment-owner + passive-holder credits, asserted to the cent) and the
      **deck-entry** match e2e PASSED (`tools/battle/smoke_crossplay.ts` — two real 20-card decks through
      the live queue; hand-privacy RLS verified non-vacuously after the mig-169 recursion fix).
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
