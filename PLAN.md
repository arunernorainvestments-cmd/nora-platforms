# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-07-13.
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

## 2026-07-11 — NEXT PHASE: UI/UX shell + mint-flow polish (diagnostic-driven)

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
