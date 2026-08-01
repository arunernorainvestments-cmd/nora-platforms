# NORA Platforms — Standard Playset & Launch Seeding Build Spec
**For Claude Code. Phased. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md, HANDOFF.md, `NORA_PLATFORMS_MARKETPLACE_SPEC.md`, and `NORA_PLATFORMS_COLLECTIONS_SPEC.md` in full before touching any file.**
Compiled: 2026-07-31 · Seeds the platform with a launch-ready **Standard Playset** — enough authored cards that every new user can build a legal 20-card deck on day one, understand the product instantly, and still have their one personal mint — plus the Segmind marketing-video pipeline that promotes it.

> **Ambiguity handling:** as in the Collections spec — **❓ REPO-CHECK** items must be resolved against the repo (read named files in full, Hard Rule 11) and recorded in the PR description; **[FOUNDER]** items are surfaced, never guessed.

---

## 0. The two corrections to the original brief (read first — they change nothing you want, and remove two landmines)

### 0.1 The IP posture: the platform cannot mint other people's viral videos
The brief as given ("upload meme/pop-culture videos and mint them") would have the platform minting third-party content — the exact thing Hard Rule 37 and the whole OAuth-consent stack forbid users from doing, done commercially by the platform itself (copyright infringement + right-of-publicity, at sale). **This spec does not do that.** Instead, the Standard Playset is built from four IP-safe content lanes that deliver the same product outcome — instantly-recognizable, meme-fluent cards:

| Lane | What it is | Legal basis | Priority |
|---|---|---|---|
| **A — Original meme-FORMAT content** (primary) | Platform-produced original videos riffing on meme *formats*, trend *archetypes*, and cultural *moments* — original characters, original footage/generation. A format ("dramatic slow-zoom escalation," "confident-walk-into-disaster," "bottle-flip triumph") is an idea; ideas aren't copyrightable — specific videos and characters are. Generated with the **cinematic engine already built** (Segmind, house cel-shaded style). | Original works, platform-owned | **The default. ~80% of the set.** |
| **B — Licensed creator moments** | Real creators' real moments, licensed through the **existing `lkn_*` rail** — literally what it was built for ("celebrities return as licensed premium chits"). | License agreement | Optional, budget-dependent; strongest marketing value |
| **C — Public-domain / properly-licensed stock** | PD footage, CC-licensed-for-commercial-use with attribution honored | PD / license terms | Filler; verify per-asset |
| **D — Commissioned originals** | Pay creators to produce original clips for the platform (work-for-hire; the Clip Campaigns machinery from the Collections spec is the natural vehicle) | Contract | Post-launch pipeline |

**Parody note [FOUNDER + counsel]:** parody enjoys fair-use protection but is fact-specific and NOT a safe harbor for a commercial card product; Lane A stays on the *format/archetype* side of the line (evoke the vibe, never reproduce the specific video, character, or person). Any card that names or depicts a real person goes through Lane B or is cut.

### 0.2 No rule gets suspended
The one-active-self-minted rule constrains **users**. Platform seeding runs through an **admin/service-role mint path** (the `celebrity-integration-seed` pattern: platform-managed identity, no login), which bypasses the *per-user slot* but **never bypasses moderation or ladder-derivation**. Users keep exactly one personal mint; the Collections economy's disincentive structure (pay to mint collections) is untouched. Nothing user-facing changes, so nothing needs re-tightening later.

---

## 0.5 Virality priority review (2026-07-31 — governs sequencing)

A decision audit against one question — *what maximizes the probability of viral spread?* — reordered this spec. The finding: **the playset buys comprehension and retention; it does not spread.** Starter cards are non-tradeable platform generics with no external audience attached. Spread comes from two places, in order:

1. **The mint reveal is the viral atom.** "My post became a playable card" is the shareable unit, and the person sharing it carries their own audience. It must be a **product feature, not a marketing message**: every completed mint auto-generates a watermarked 9:16 reveal clip with one-tap share (§1.4, built in Phase S4). Every minter becomes a distributor.
2. **Creators minting on camera are the launch engine.** A Founding Market Makers cohort (Phase S4) out-leverages any ad spend: their mints are free (own posts, normal consent flow), each reveal is a product demo, and their reach is theirs.

**The resulting priority stack:**
| Rank | Item | Why |
|---|---|---|
| 1 | Mint-reveal share asset (S4) | every mint = an ad with a built-in audience |
| 2 | Founding Market Makers cohort (S4) | distribution with reach attached; each mint is a demo |
| 3 | Transformation marketing spot (S3) | the core pitch, platform-owned channels |
| 4 | Playset @ 30 cards (S1/S2) | comprehension + retention floor — necessary, not viral |
| 5 | Timed spikes: GTA VI Nov 19; seasonal | ride the loudest scheduled moments |

**Decisions changed by this review:** card count 50 → **30** (renders/calendar reallocated to ranks 1–3; 50 is the post-launch stretch) · World Cup cluster **downgraded to conditional** (decaying — final was July 19; use only if launch lands within ~2–3 weeks) · 2016-nostalgia cluster promoted to lead (months of runway; rides the authenticity current) · anti-slop guardrail **elevated from marketing note to hard gate** (slop doesn't just underperform — it suppresses sharing; nothing publishes without human review, including reveal-clip templates).

---

## 1. The model (canonical)

### 1.1 What the Standard Playset is
- A set of **platform-authored generic cards** (`is_generic=TRUE` — the Collections-spec N6 concept, now pulled forward): full Arena gameplay, **never marketplace-listable, never tradeable, never barterable** — enforced in every listing/barter/wager RPC.
- **Granted free to every account at signup**: the full playset, 2 copies of each card (max legal deck copies).
- Non-tradeable is load-bearing three ways: (a) zero sybil value — farming accounts yields nothing sellable; (b) zero pollution of the collection economy — scarcity and price live only in user-minted/collection cards; (c) zero IP-sale exposure — generic cards are in-game assets, not commercial goods.
- Every user still gets their **one free personal mint** — the playset is the floor that makes that mint meaningful ("here's a real deck; now add YOUR moment to it").

### 1.2 Card count (recommendation + math)
Deck = 20 cards, max 2 copies per chit ⇒ a legal deck needs ≥10 unique chits. Ten uniques = zero deckbuilding choice — the moment of "I choose my deck" is the hook, so the playset must be meaningfully larger than one deck.

**Recommendation: 30 unique cards** = 10 archetype families × 3 cards each (revised down from 50 per the §0.5 virality review — render budget and calendar reallocate to the share loop and creator cohort; growing to 50 is a post-launch content drop, which itself becomes a marketable "new set release" beat, TCG-style). Grant 2 copies of all 30 (60-card pool) → still thousands of viable 20-card decks from minute one.
- Per family (3 cards): 2 creatures + 1 spell-moment, anchored on the family's Wave-1 signature effect.
- **Tier spread: F×10 · E×9 · D×7 · C×4. No A/S starters** — high tiers stay scarce, reserved for the real economy (viral mints, collections, Mystery Box pulls). This is also the balance guard: the free floor must never outclass the paid ceiling.
- Coverage check: all 4 timing types, all 4 keywords, and ≥2 cards satisfying each launch `fusion_rules` pattern (players must be able to *discover fusion* with starters alone — at 30 cards this is tighter; the seed script's coverage assertion is mandatory, and if the launch fusion rules can't all be satisfied within 30, cover the 3 starter-set rules first and note the gap).
- **❓ REPO-CHECK 1.2:** verify against `tier_ladder` + the Wave-1 `effect_templates` (migs 151/152) that 30 cards can draw effects without exceeding `min_tier_band` gates at F–C; adjust the tier spread if the ladder disagrees.

### 1.3 The content slate (trend-informed, Lane-A format archetypes)
Researched 2026-07-31. These are **format/archetype briefs for original content** — none is a specific third-party video. Slot into `{SUBJECT_DESC}` per the §4 prompt grammar (style-lock untouched).

| Theme cluster | Why now (research) | Example card briefs (original) | Family fit |
|---|---|---|---|
| **2016-nostalgia wave ("the Great Meme Reset")** — LEAD cluster | "2026 is the new 2016" movement; users recreating classic-era formats; months of runway and rides the authenticity current (§0.5) | "The Perfect Bottle Flip," "Frozen Crowd" (mannequin-style freeze), "Dab of Victory," "Dance-Craze Ghost" | gamer/influencer/comedian |
| **Stadium / sports-glory energy** — CONDITIONAL | World Cup final was July 19; the wave is decaying. Author these as *timeless* sports-glory formats (not WC-specific) so they hold value regardless; lean WC-adjacent only if launch lands within ~2–3 weeks | "Last-Minute Volley," "Keeper's Miracle Save," "Trophy-Lift Roar," "Heartbreak in the Stands" | athlete |
| **Escalation formats** | "Saxophone Gets Louder"-style dramatic-escalation edits are the reigning template | "This Is Fine → It Is Not," "The Slow Zoom," "Volume Rising" | comedian/musician |
| **Absurdist-news energy** | KitKat-Heist-style real-news absurdism memes | "The Great Chocolate Caper," "Breaking: Local Legend" | business/politician |
| **Creator-life / studio chaos** | Evergreen creator-economy self-reference; fits the product's own story | "Ring Light Down!", "1M Subs Button," "The Collab" | influencer/artist |
| **Science/tech spectacle** | Evergreen; AI-era fascination | "Rocket Sticks the Landing," "The Experiment Works," "Robot Learns to Dance" | scientist |
| **🔮 GTA-VI-adjacent open-world chaos (get-ahead pick)** | **GTA VI releases Nov 19, 2026** — plausibly the biggest entertainment launch ever; gaming-chaos content will saturate every platform for months | Original "open-world mayhem" archetypes: "Physics Glitch Ballet," "Five-Star Getaway (original city, original characters)," "NPC Moment" | gamer/actor |
| **Q4 seasonal (get-ahead)** | Halloween → holidays; event-energy content wins | "Costume Reveal," "Decoration Overkill," "The Feast" | comedian/artist |

**[FOUNDER]** approves the final 30-card list; this table is the sourcing brief.

### 1.4 The viral atom: the mint-reveal share loop (rank 1, §0.5)
Every completed mint auto-generates a **shareable reveal asset**: a 9:16 vertical MP4 composed from artifacts the pipeline already produces (card art + cutscene + tier reveal + CardFace frame), watermarked with the NORA mark + a join link/QR, surfaced at mint completion with one-tap share (native share sheet → TikTok/IG/YT Shorts/X). The minter's post carries their handle, their moment, their audience — the platform's growth loop is *their* flex. Built in Phase S4; reuses the `nora-stitch` worker; costs one template, not per-card generation spend. The reveal template itself passes the anti-slop human-review gate before launch — it will be the most-seen artifact the platform produces. **Marketing-existential note:** research shows a live anti-"AI-slop" backlash powering the nostalgia wave. Lane-A content must read as *crafted* — the house cel-shaded style, consistent art direction, real comedic timing in the motion prompts. Budget human review/curation per card; a slop-looking starter set is worse than a small one.

---

## 2. Decision gates & locked decisions

| Item | Status |
|---|---|
| 🚧 **G-IP (content posture)** | Lane A (original formats) is the default and needs no counsel. Lane B rides existing `lkn_*` (already governed). Any card referencing a real, identifiable person or a specific copyrighted work: **cut or Lane B — no exceptions.** One counsel pass over the final 30-card list before launch [FOUNDER schedules]. |
| **Starter cards are generic: never listable/tradeable/barterable** | LOCKED (enforced in code, N6-style). |
| **No user-rule suspension; admin path instead** | LOCKED (§0.2). |
| **No A/S starters** | LOCKED (economy guard). |
| **Playset grant: full set × 2 copies at signup** | LOCKED (default; [FOUNDER] may trim). |
| 30-card slate contents (grow to 50 post-launch as a "new set" drop) | [FOUNDER] approves final list. |
| Segmind marketing spend + `CINEMATIC_MODE=live` | [FOUNDER] — same unblock already gating Track A. |

---

## PHASE S1 — Admin seed-mint path + generic-card enforcement
**Effort:** M · **PR:** `playset-s1-seed-path`

- [NEW] `moment_chits.is_generic` (default FALSE) + enforcement: listing, barter, wager-escrow, and (future) collection RPCs all reject generic chits. **❓ REPO-CHECK S1.1:** if the Collections spec's N6 already added `is_generic`, extend; else this migration owns it.
- [NEW] **`admin_seed_chit(...)`** — service-role-only mint path: takes a content brief (family, target tier, `{SUBJECT_DESC}`, media refs), runs the FULL moderation gates (pre-gen + post-gen — platform content is not exempt; HR37–39 minus the OAuth-ownership check, since the platform owns Lane-A content outright), derives stats via `create_moment_chit`/`derive_chit_stats` (HR34 — no hand-set stats, ever). Tier assignment for platform cards: **❓ REPO-CHECK S1.2:** `tier_for_engagement()` expects engagement counts; determine the sanctioned way to target a tier for authored content (default: pass the tier band's threshold floor as synthetic engagement, recorded as `seed_source='platform'` so ascension logic永 skips platform cards — they never ascend).
- [NEW] Platform-managed minter identity via the `celebrity-integration-seed` pattern; `original_minter_handle` renders as "NORA" + no source-platform badge (**❓ REPO-CHECK S1.3:** confirm CardFace handles a null `source_platform` gracefully or add a platform variant).
- Media: Lane-A videos through the existing cinematic pipeline (sim placeholders until Segmind spend lands; cards are grantable/playable with placeholder media — the P6 pattern).

**Deliverables:** `is_generic` enforced everywhere · admin path mints ladder-derived, moderated, non-ascending platform cards · 2–3 smoke cards minted in sim.
**DO NOT** hand-set stats · skip moderation for platform content · let generic cards reach any marketplace/barter/wager path · let platform cards ascend.

---

## PHASE S2 — The 30-card authoring run + signup grant
**Effort:** L · **Depends:** S1, [FOUNDER] slate approval · **PR:** `playset-s2-grant`

- [NEW] Author the approved slate as data (briefs → `admin_seed_chit` batch; a `tools/playset/seed_playset.ts` script, idempotent, re-runnable as media upgrades from sim→live renders).
- [NEW] **`grant_starter_playset(p_user)`** — idempotent (once per account, receipt-ledger pattern); grants 2 copies of every `is_generic` playset card; wired into signup/onboarding completion. **❓ REPO-CHECK S2.1:** backfill decision for existing beta accounts (default: backfill all).
- [NEW] Onboarding touch: after the grant, route the user into deck-building with a "now mint YOUR moment" CTA (the product-comprehension beat the founder wants). **❓ REPO-CHECK S2.2:** read the shipped 6-page onboarding walkthrough; extend, don't rebuild.
- Coverage validation in the seed script: asserts the fusion-discovery, keyword, and timing-type coverage rules from §1.2.

**Deliverables:** 30 cards live (sim media OK) · every new + existing account holds the playset · deck legal-check passes on starter-only decks · fusion discoverable with starters · `flutter analyze`/`deno check` clean.
**DO NOT** grant twice · ship any card not on the approved slate · let starter power creep past C-tier.

---

## PHASE S3 — Segmind marketing-video pipeline
**Effort:** M · **Depends:** S2 slate, Segmind spend ([FOUNDER]) · **PR:** `playset-s3-marketing`

- [NEW] `tools/marketing/` generation scripts reusing the cinematic client: card-reveal spots (plate → card cutscene → CTA), fusion-demo clips, "mint your moment" explainers — each authored per-platform aspect (9:16 primary) and length (6–15s hooks).
- Formats to produce (maps §1.3 to ad creative): starter-card reveals · a "your post becomes a playable card" transformation spot (the core product pitch — highest priority) · fusion spectacle · World-Cup-energy athlete cards while the moment lasts · a GTA-VI-week gamer-card drop **scheduled for Nov 19** (prep now, post then).
- **Channel plan** (recommendation): **TikTok + IG Reels + YT Shorts** (primary tri-post, same 9:16 asset) · **X** (clips + card-art stills; crypto/collector audiences live here) · **Facebook Reels** (older collector demo) · **add: Discord** (a server is table-stakes for a card game community — organic, not ads) · **Reddit** (organic dev-log posts in gaming/TCG subs — earnest dev-story content only; ads read as slop there) · **Twitch** (post-launch: creator battles using their own minted cards — the content markets itself).
- Anti-slop guardrail (research-driven): every published asset passes human review; lean on the crafted cel-shaded identity; never publish raw unreviewed generations.
- **❓ REPO-CHECK S3.1:** confirm marketing generations run through a separate Segmind budget/ledger from user mints (cost attribution), reusing `cinematic_generations` seed/version persistence or a marketing twin.

**Deliverables:** repeatable per-platform generation scripts · launch asset pack (≥10 spots, transformation spot first) · Nov-19 drop prepped · human-review step documented.
**DO NOT** publish unreviewed output · use real persons/copyrighted characters in marketing (same G-IP line) · promise card value/appreciation in any ad (G-COLL language ban applies to marketing).

---

## PHASE S4 — The share loop + Founding Market Makers (virality ranks 1–2)
**Effort:** M · **Depends:** mint pipeline (shipped); real renders gated on Segmind spend · **PR:** `playset-s4-share-loop`

### S4.1 Mint-reveal share asset (§1.4 — product code, not marketing)
- [NEW] `mint-reveal-compose` edge step (or a `nora-stitch` job type): on `cinematic_complete_mint`, compose the 9:16 reveal MP4 (card-art beat → cutscene excerpt → tier/CardFace reveal → watermark + join link), store in `battle-media`, attach to the chit (`reveal_asset_url`).
- [NEW] Mint-completion UI: the reveal plays; one-tap native share sheet; copyable link. Sim mode composes from placeholder media (honest placeholder, same as the mint pipeline).
- **❓ REPO-CHECK S4.1:** confirm `nora-stitch` can take a template overlay (watermark/QR) or whether a second lightweight compose worker is needed; confirm Flutter web share-sheet support per target browser and fall back to download+copy-link.
- Referral note: the join link may carry a referral token feeding the existing challenge/referral milestone design — wire the token, defer any reward logic to the challenge-emission framework (marketplace spec §6). Starters stay non-tradeable; **no card rewards for referrals** (sybil guard).

### S4.2 Founding Market Makers cohort (ops + light product)
- [NEW] A `founding_market_maker` flag + invite path: 10–25 mid-size creators ([FOUNDER] selects; suggested profile: 50k–500k followers, clip-native niches — gaming, sports commentary, comedy) white-gloved through KYC + social link + their own mint **before public launch**, with live renders (this is the strongest argument for unlocking Segmind spend early — their reveals ARE the launch campaign).
- Their asks: post the reveal on their own channels at launch; optionally seed one card to the future Mystery Pool (when G-MYSTERY opens). Their mints are their own posts through the normal consent flow — free, no licensing needed; Lane B licensing only if the platform wants to *feature* their content beyond their own posting.
- [NEW] Light product support: a "Founding Market Maker" profile badge (cosmetic); launch-day featured row on the market surface.
- **❓ REPO-CHECK S4.2:** confirm the cohort can be onboarded against prod safely pre-launch (test-account filter interplay, Hard Rule 15 — founding MMs are REAL accounts, must NOT be flagged `is_test_account`).

**Deliverables:** every mint ends in a shareable, watermarked reveal with one-tap share · referral token wired (reward logic deferred) · cohort flag/badge/featured row shipped · onboarding runbook for the cohort documented.
**DO NOT** gate sharing behind KYC or any friction · reward referrals with cards · publish the reveal template without the human-review pass · flag founding MMs as test accounts.

---

## 4. The founder question bank (the questions to ask, answered where I can)

**Economy & product**
1. *Should starter cards ever become tradeable?* Recommend **no, permanently** — the moment they're sellable, sybil farming and economy pollution both activate. If you want a tradeable on-ramp later, add a cheap collection, don't unlock generics.
2. *Identical playset for everyone, or variety (e.g., pick 1 of 3 starter boxes)?* Identical ships faster and keeps balance trivial; pick-a-box is a nice retention beat post-launch. Default: identical now.
3. *Do platform cards ascend?* Recommend **no** (locked into S1) — ascension is the reward for *real* engagement on *your* content; platform cards ascending would inflate the free floor.
4. *What happens to the playset when the collection economy matures?* Plan (not build) a sunset lever: new-account playsets can shrink over time as the minted-card supply grows — config, not code.

**Legal (schedule counsel once, ask all of these)**
5. Final 30-card slate review for IP/likeness exposure (G-IP pass) — include the reveal-clip template and all S3 marketing assets in the same pass.
6. Parody posture in writing — where's OUR line for Lane-A briefs?
7. Does granting free non-tradeable game assets trigger any sweepstakes/promotion rules in target jurisdictions? (Likely no; confirm.)
8. Marketing claims review: the G-COLL language ban applied to ad copy.

**Marketing**
9. *Budget split: paid ads vs creator seeding?* **RESOLVED by the §0.5 review** — creator seeding is rank 2 and now Phase S4.2 (Founding Market Makers). Paid ads are secondary.
10. *Is the anti-AI-slop risk priced in?* **RESOLVED** — elevated to a hard publish gate (§0.5); marketing leads with the human transformation story, and the reveal template itself passes review.
11. *What's the Nov 19 (GTA VI) play, concretely?* Prep the gamer-card drop + creator collabs now; the window will be loud and short.
11b. *What is the single shareable unit, and does the product manufacture it?* **RESOLVED** — the mint reveal, now a product feature (§1.4 / S4.1), not a marketing hope.

**Ops**
12. Segmind budget for ~30 cards × (draft + final) + the marketing pack + the S4 reveal template + cohort live renders — get the per-render cost from the `tools/cinematic/trial_*.ts` micro-trials before committing the slate size.
13. Who owns human review of generated content pre-publish? (Name a person; make it a checklist step.)

---

## Cross-repo contract (mirror into RECONCILIATION.md)
| Platforms provides | Arena consumes |
|---|---|
| `is_generic` on `moment_chits` | no sell/trade affordances on generic cards |
| Starter playset grant at signup | collection view shows playset; deck-builder works day-one |
| Platform-minter attribution variant ("NORA", no source badge) | CardFace/Unity render the variant |
| Platform cards never ascend | no ascension UI on generics |

## Per-phase report template
```
Phase Sx — <name>
- REPO-CHECKs resolved: <id → finding → decision>
- [FOUNDER] items surfaced: <list>
- Slate status: <n/30 minted, media sim|live>
- flutter analyze / deno check: <clean/issues>
- G-IP audit: <no real persons/IP in shipped cards & marketing? y/n>
```
