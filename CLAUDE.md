# NORA Platforms — CLAUDE.md
# Last updated: 2026-07-02

## Project
Flutter web prediction-market + **card-battler** platform ("Moments" — the v3 CCG pivot),
one wallet, plus two community systems (Emergency Fund, Licensing Marketplace).
Pre-launch — July 4 2026. The v3 build path lives in `NORA_PLATFORMS_BUILD_SPEC_v3.md` (canonical
spec); P0–P6 are SHIPPED and the P7 launch-hygiene remainder is tracked in PLAN.md.
Repo: arunernorainvestments-cmd/nora-platforms
Supabase ref: cceisywxwhgljdpisjrl | Domain: noraplatforms.com (Cloudflare → Vercel → Flutter)

This repo keeps four docs. **CLAUDE.md** = canonical rules + how to build safely
(this file). **PLAN.md** = where we're going (future state not yet built). **ARCHIVE.md** =
where we've been (history, full schemas, scoring formulas, infra, runbooks, testing,
deprecated specs). **RECONCILIATION.md** = the cross-repo contract with the nora-arena mobile
app (what it consumes from this backend + open platform-side decisions). If CLAUDE.md and
ARCHIVE.md ever disagree, CLAUDE.md wins.

## Tech Stack
- Flutter web: plain Riverpod only (FutureProvider.autoDispose / Provider). NO @riverpod, NO build_runner, NO codegen. Ever.
- Backend: Supabase (PostgreSQL + RLS + Deno Edge Functions)
- Routing: GoRouter + PathUrlStrategy (clean URLs, no #)
- Hosting: Vercel catch-all rewrite → Flutter index.html
- Battle animations: Flame (sprites) + Lottie JSON (effects) + Flutter native (UI)
- LLM calls use claude-sonnet-4-6 (Hot Topic scoring, Emergency Fund AI). Never hardcode keys.

## Theme
bg #0A0A0F | surface #1A1A2E | primary #6C63FF | secondary #03DAC6 | success #00C896 | danger #FF4757

## Hard Rules
1. Plain Riverpod only — no codegen, no @riverpod, no build_runner
2. sync-platform-metrics stays a single Edge Function — never split
3. Never modify display_score outside sync-platform-metrics
4. Never modify heat_score outside sync-platform-metrics (exception: arena-monday-rollover resets Spotlight winners)
5. All token movements logged in token_transactions with type + reference_id. **Amounts are
   SIGNED — debits negative, credits positive** (mig 180). Reconciliation and reporting read
   the `token_ledger_signed` view's `signed_amount`, **never** `token_transactions.amount`:
   rows written before the 2026-07-25 cutover stored debits as positive magnitudes, and the
   view normalises by type across both. **Money math belongs in a SECURITY DEFINER RPC, not an
   edge function** — debit with one guarded `UPDATE … WHERE available_tokens >= cost` in the
   same transaction as the thing being paid for. Never read-a-balance-then-write-it-back: that
   loses a debit under concurrency (audit #5). Never treat a failed credit as success.
6. ON CONFLICT DO NOTHING wherever badges are inserted
7. Passive effects are read-only at query time
8. Handle HTTP 429 gracefully — log and skip, never throw
9. Never hardcode API keys
10. noraplatforms.com everywhere — no vercel.app references
11. Read every file in full before modifying
12. flutter analyze zero issues before every commit
13. is_market_maker = true AND pending_opt_out = false for eligibility
14. Cooldowns via active_boosts only
15. Test accounts filtered from all ranking/discovery queries
16. Arena and Markets are independent reward loops
17. Arena never modifies display_score, heat_score, or token_balances except via Back action, Trigger action, and match resolution
18. ArenaScore is in-memory only — never persisted post-match
19. Spotlight has two sections — compute-spotlight produces both independently
20. arena_trigger() writes effects directly to arena_state.active_effects
21. Battle and Arena are entirely separate — all Battle artifacts prefixed battle_
22. INCLUDE_TEST_ACCOUNTS filter pass (Slice 2) tracked separately
23. Emergency Fund AI evaluator facilitates only — never recommends approve/deny (Hard Rule: ubi_*)
24. ubi-documents Storage bucket has NO client-accessible signed URLs, ever — documents are AI-only
25. Individual vote values in ubi_panel_votes are forever private — no client SELECT policy, no index on vote column
26. One role per match: for a match with an open battle_outcome market, a verified human is COMBATANT (uses chits, cannot bet) or SPECTATOR (bets, cannot influence) — never both. Enforced at the DB layer across KYC-linked alts (identity_hash). Never weaken the bets/arena_events integrity triggers (migration 102)
27. **Naming (v3):** "Battle Chits" the single-use **powerup** collectibles live in `battle_chit_definitions`/`user_battle_chits` and are now **legacy/dormant** under the v3 card-battler. The v3 **card asset** — the minted-moment creature/spell that IS the game — is the **"moment chit"** in `moment_chits` (see Systems + PLAN P1). Do not conflate the two tables. The legacy powerup rule still holds: arena_abilities/arena_trigger are legacy-only, do not extend; legacy chit usage is participant-only and blocked while the caller holds a stake on the linked market.
28. identity_hash partial-UNIQUE on approved KYC rows is the sybil anchor — never drop it; Stripe Identity webhook populates it in live mode
29. lkn_agreements is append-only: after INSERT only status fields change (revoked/expired/suspended/transferred). terms_snapshot is immutable — verification reads the snapshot, never the live template. Enforced by the migration 111 BEFORE UPDATE guard trigger; never weaken it.
30. lkn_license_templates contract text is produced only by lkn-generate-contract from the pre-approved clause library — never generate novel legal language from AI.
31. lkn-verify validates the API key (X-NORA-API-Key header) and enforces the daily rate limit BEFORE any license data is read. Never return license data without a valid key.
32. The signing private key lives only as the NORA_SIGNING_PRIVATE_KEY edge-function secret (PKCS8 PEM). Never log it, return it, or commit it. lkn-verify degrades to signature:null when it is absent.
33. Battle prediction markets settle in **real money (USD)**, Markets settle in **tokens** — never cross the two currencies.
34. A chit's **archetype/effect-family and damage numbers come from the authored `tier_ladder`**, never user-set. Tier is **cost-banded** (higher tier = stronger AND costlier Aura) — never strictly-better-for-cost. *(Amended 2026-07-12:)* the **family label** may be user-chosen from the fixed 10-family allowlist (mint wizard "Automatic / pick it yourself", `moment-classify` `family_override`) — but the **effect is always server-selected from that family's authored, balanced library** (never client-supplied), and tier/cost/atk/hp stay engagement-derived. Family choice changes style, never power.
35. Real-money `battle_outcome` markets exist **only for matches where both players are KYC-verified** (per decision gate G-MON). Non-KYC matches run non-monetized.
36. Tier **ascension is one-directional** (never de-rank), applies **between matches only**, and matches **snapshot chit stats at start** — mid-match ascension can never alter an active match.
37. Chits are minted **only from a post the user owns** (OAuth-verified account link); source allowlist TikTok/Instagram/YouTube; **no arbitrary-URL minting**. *(Amended 2026-07-04, Minting_Workflow.md:)* because the platform APIs never hand out the video file, the clip itself is uploaded from the user's device — but **only tethered to an already-approved owned moment** (moment-ingest first), trimmed in-browser to 1–15s, into the **private `mint-staging` bucket** under the owner's prefix; `moment-clip-attach` then **re-moderates sampled frames of the actual upload** and runs a **thumbnail-vs-frame similarity check** (mismatch → human review, never silent mint). Untethered/anonymous uploads remain forbidden. **Pre-generation moderation runs before any generation; the minor-safety/CSAM screen is absolute and cannot be bypassed** — on source AND on the uploaded clip.
38. Every minted cutscene MP4 is stored in the **`battle-media`** bucket (**never a hotlinked provider URL**) and the chit carries `match_cut_template_id`, `anchor_plate_version`, `prompt_template_version`, `generation_seed`. (`final_frame_camera` is deprecated — Unity owns the camera pose via its local `MatchCutAnchor`, authored against the plates.)
39. Anchor plates + motion prompt templates are **house-owned and versioned, never per card** (`match_cut_anchor_plates`, `match_cut_prompt_templates`). *(Amended 2026-07-04, Minting_Workflow.md:)* launch ships **two character/template-AGNOSTIC plates** — start = the glowing BattleChit card, end = the cyber impact flash (`assets/plates/agnostic_*_plate_v1_16x9.png`); Unity's zoom-into-card lead-in and impact-flash particle bracket every cutscene, so lead-in variety lives in Unity, not in per-template plates (per-template plates are a future expansion, not launch). Plates are authored at **16:9** (generation aspect follows the reference frames). The prompt's **STYLE (style-lock) and CONSTRAINTS blocks are never user-influenced or omitted**. **Post-generation moderation on the finished MP4 is mandatory — clean bookends never vouch for the middle.** The user must preview the card in a practice battle before the chit finalizes.
40. **Marketplace (migs 153–156):** fixed config prices only (`marketplace_tier_pricing`) — never supply/demand, never value accrual (G-CARDVAL parked). The A/S sale fee is a **BURN**, never platform income. All marketplace writes go through the `marketplace_*` SECURITY DEFINER RPCs — no client table writes; `marketplace_sales` and the acquisition ledger stay append-only. **Provenance lock:** a copy acquired with tokens can never be resold for USD (`acquired_currency` stamp) — free token emission must never reach USD. The USD lane opens only via `marketplace_usd_lane` (founder gate) AND settles per `battle_payments_mode`; USD sales never touch `token_transactions` (Rule 33). A listed chit is HELD: escrowed out of holdings, ascension frozen, swap-retire blocked, self-mint slot still occupied.

41. **Mystery Box (mig 175, Collections N6):** Boxes are **NEVER sold** — not for money, not for
    tokens. There is deliberately **no purchase RPC**; `mystery_box_grant` is server-only (REVOKEd
    from `authenticated`) and idempotent per gameplay `context_key` (one win = one box). This is
    structural, not config — the paid-randomized-pull is the brightest legal line in the spec
    (G-COLL/G-MYSTERY). `mystery_pool_settings.mode` defaults to **`disabled`** in beta and both
    money-moving RPCs RAISE while it is; the submit button renders with its explainer, disabled.
    Platform-authored **generic cards** (`moment_chits.is_generic`) are in-game use only and may
    **never** reach the marketplace — enforced in `marketplace_list_chit_internal`. Submitted
    copies rest in copy state `mystery_pool` with attribution intact; submission pays the fixed
    per-tier config rate on the **USD rail only** (Hard Rule 33).

42. **Clip Campaigns (mig 176, Collections N7):** New namespace `clip_campaign*` — the archived
    mig-089 `campaigns` tables stay archived, untouched. **No un-moderated clip is ever visible to
    a Market Maker** — enforced in RLS (`clip_campaign_submissions` returns a row to the campaign
    owner only in `approved|accepted|paid`), never in application code. `clip_submission_moderate`
    is **service-only**; minor-safety is absolute and queues to `clip_campaign_moderation` (no
    client policies, ever — the mig-141 posture). Budget is **escrowed in full at creation** and
    leaves ONLY via `clip_campaign_accept` (one payment per submission, UNIQUE-anchored) or the
    cancel/expire refunds. Clippers **submit freely; KYC gates PAYMENT**, not submission.
    **REPO-CHECK 1.6 consent chain (Hard Rule 37 is NOT weakened):** a campaign may carry
    `source_moment_id`, a tether to a post the Market Maker already proved they own (OAuth via
    moment-ingest, moderation-approved). **Tethered** → an accepted clip is the device-clip leg of
    HR37 for that post and may feed a mint; **untethered (default)** → the campaign is
    **licensing-only**: payment + profile display, no mint feed. Either way the campaign system
    **never mints** — it hands the clip to the existing pipeline, which owns consent.

43. **Standard Playset (migs 181–182):** the 30 platform-authored starter cards granted free to
    every account at signup are `is_generic AND is_starter` and are **never listable, tradeable,
    barterable, stakeable, collectible, or ascendable** — enforced in the marketplace, barter,
    wager-escrow, `collection_chits` and ascension paths, not in UI. They are **unserialized**
    (the `chit_copies` machinery skips starters): supply is unbounded by design, so the mig-170
    invariant reads "quantity == owned copies **for every non-starter chit**". Platform cards are
    authored ONLY through `admin_seed_chit` (service-role): moderation is **not** skipped for
    platform content, stats stay ladder-derived (HR34), and the tier is targeted by feeding the
    band's engagement FLOOR through `tier_for_engagement` — never hand-set. **No A/S (or B)
    starters**, enforced in the RPC: the free floor must never outclass the paid ceiling. The
    grant's unit of idempotency is the **(account, card)** receipt row
    (`starter_playset_grants`, PK-enforced via ON CONFLICT DO NOTHING) — so a card can never
    be granted twice AND a starter authored after launch **tops up** every existing account
    on the next call, instead of reaching new signups only; signup wires it
    best-effort and `claim_starter_playset()` self-heals. Users keep exactly **one** personal
    self-mint — the seed path bypasses the per-USER slot and nothing else.

44. **Share loop + marketing (migs 183–184):** every mint ends in a shareable 9:16 **reveal asset**
    (`moment_chits.reveal_asset_url`, battle-media only — HR38); sharing is **never gated** behind
    KYC or any friction, and referrals **never** pay out cards (sybil guard). Marketing renders are
    a **separate budget line** from mint spend (`marketing_generations`, capped by
    `marketing_budget_config.cap_cents`, default 0 = no spend authorised). **Nothing publishes
    unreviewed:** `marketing_spot_publish` RAISEs without an approved render carrying a named human
    `reviewed_by` — the anti-slop gate is schema, not process. The G-COLL language ban extends to ad
    copy (the copy-guard trigger refuses investment/return/yield/dividend/revenue-share/profit/ROI/
    appreciation). Founding Market Makers are **real accounts** — a profile can never be both
    `is_founding_market_maker` and `is_test_account` (HR15).

## The game (v3 — "Moments" card-battler, canonical)
> **v3 supersedes the v2.x 1v1 archetype-fighter model entirely.** The build path is `NORA_PLATFORMS_BUILD_SPEC_v3.md`
> (P0–P6 shipped, migs 116–137; P7 remainder in PLAN.md). Backend owns ALL game logic; Arena is display-only/server-authoritative.

Each player has **Life** (default 30), builds a **lean deck** (size 20, max 2 copies/chit) of **moment chits**, and on
their turn spends **Aura** (auto-ramp +1/turn to a cap of 10, refills each turn, **no land cards**) to summon chit
**creatures** (ATK + HP only, **no AP**, field cap **3**) onto a shared-3D field or cast one-shot **spell-moments**.
Win by reducing the opponent's Life to 0. Combat is **server-authoritative** — `process_battle_turn` resolves and emits
ordered `battle_events`; the client computes nothing.

- **The asset = the moment chit** (`moment_chits`, P1). A card minted from a real **viral moment** (a user's social post,
  consent at link). Owned/collected/traded. Card art = the viral thumbnail; body = a shared 3D humanoid rig + a minted
  cel-shaded moment video composited by camera cut on summon. Two value layers: **consent-minted user moments** (free to
  mint/collect, the base) and **licensed creator/celebrity moments** (premium packs on the `lkn_*` rail).
- **Tier ladder** (`tier_ladder`, P2) is the balance core: tiers **F/E/D/C/B/A/S**, **cost-banded** (higher tier stronger
  AND costlier — Hard Rule 34). Tier is assigned from engagement at mint; a chit's cost/atk/hp/effect are **derived**,
  never user-set. Archetype **families** (athlete/musician/artist/scientist/comedian/…) are the **effect-family classifier**.
- **Fusion** (`fusion_rules`, P2/P3) is **tag-based** — authored patterns on `{family, keyword, element, count}`, not
  per-card recipes — so it works for any user-minted chit.
- **Two resource gates:** **Aura** (personal, "can I afford it?", auto-ramp) and **Vibe** (`match_vibe`, P4 — shared,
  symmetric, market-driven, server-authoritative, passive floor; "is the crowd hyped?"). Premium ultimate chits need both.
- **Minting + ascension** (P6): moments → chits (link → recommend → animate → classify → tier-assign → moderate → mint).
  **Ascension** is one-directional, definition-level (all copies together), ≤1/7 days per user, between-matches only (Hard Rule 36).
- **Minting + Match Cut + Cinematic Engine** (specs: `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md` +
  `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md`, the latter supersedes the retired anchor-plate doc): the web-side
  minting pipeline (Companion-App model — mint on web, off the 30% store fee). OAuth-owned post → pre-gen
  moderation → classify/tier → stylized illustration → **cutscene MP4 bracketed by fixed per-template anchor
  plates** (Seedance 2.0 via Segmind, first/last-frame conditioned, seeded) → post-gen moderation → preview
  battle → store in `battle-media` (Hard Rules 37–39). ~6 `match_cut_templates` (role-keyed camera geometries:
  ground_slam/sky_descent/projectile_strike/radial_burst/aura_surge/counter_veil) make the 2D→3D seam; Unity
  brackets the MP4 with a local anchor. **Naming: the specs say "battlechit"/`battle_chits` — in this repo that
  IS `moment_chits`** (Hard Rule 27 naming stands; `chit_ownership` already exists, mig 117). Also queued from
  the minting spec: **one active self-minted chit per user** (swap = warn → delete old chit + media → mint new,
  never delete before the new mint confirms), **`wager_match` mode** (chit escrow, winner takes loser's chit,
  `original_minter_handle` attribution survives transfer), `profiles.avatar_loadout`, `is_monetized` per G-MON.

## Systems (current, built)
- **Markets**: bet on creator Display Score direction, settled in **tokens** (Hard Rule 33). Pool: 90% winners / 5% platform / 5% Market Maker.
- **Battle prediction markets** (v3): `battle_outcome` markets over card-battler matches, settled in **real money (USD)**.
  Created **only when both players are KYC-verified** (decision gate **G-MON**, Hard Rule 35); non-KYC matches run
  non-monetized. Payout split routes the creator/passive slices to the **moment-owners of the chits actually played**
  ("summon your friend, your friend earns") — see PLAN P5.
- **Hot Topic**: celebrity buzz leaderboard, independent of games. 25 celebs, Claude scoring twice daily via Currents API.
- **Likeness Cards**: collectible character cards + stat sheets (6 stats). Marketplaces + weekly polls persist; **weekly
  polls/stat-multipliers go DORMANT under v3** (P7). Stat sheets are cosmetic-only in the card-battler.
- **Emergency Fund** (`/emergency-fund`, `ubi_*`): community mutual-aid pool, sim mode. Contribute → AI privately evaluates request → random contributor panel votes → Stripe Treasury disburses. Platform holds zero funds.
- **Licensing Marketplace** (`/licenses`, `lkn_*`): Right of Publicity licensing; now also the rail for **premium chit packs**. Buyers purchase priced tiers governed by toggle-driven templates → append-only `lkn_agreements` (Hard Rule 29). Public registry `/license/:id` (no PII). Verification REST API `GET api.noraplatforms.com/v1/verify`, X-NORA-API-Key auth, rate-limited (Hard Rule 31), ECDSA P-256 signed (Hard Rule 32). License IDs `LKN-[year]-[8 chars]`. Payments sim-mode (`LKN_PAYMENTS=sim`).
- **Chit marketplace** (`marketplace_*` tables, migs 153–156; spec `NORA_PLATFORMS_MARKETPLACE_SPEC.md`): public
  **fixed-price** resale of minted moment chits. Token lane LIVE (config prices per tier F–S; A/S fee **burned**);
  USD lane built like-live but **OFF** behind `marketplace_usd_lane` (founder gate) with KYC-on-USD + the
  **provenance lock** (token-bought → token-resale-only). RPC-only writes; listing = escrow on the acquisition
  ledger; ascension freezes while listed. Web-only surface (`/market`, M3 pending); mobile deep-links. Hard Rule 40.
  Distinct from the LEGACY powerup marketplace (`chit-marketplace-*` edge fns over `battle_chit_definitions` — HR27).

## Deprecated / retired by v3 (archive, don't drop)
- **The 1v1 archetype-fighter model**: the 6-player turn-based Battle resolver, **D&D six-stat characters**, per-archetype
  **move-sets** (`battle_abilities`), and **license-per-character battle eligibility** (`check_battle_eligibility` gating).
  Eligibility under v3 is "you own moment chits and have a legal deck." Retired schemas stay in place (P7 archives, never DROPs).
- **Legacy Arena** creator-vs-creator live 5-min 1v1 (ArenaScore in-memory, Back/Trigger) + legacy `battle_spectator_bets`
  path — walled off by integrity triggers (Hard Rules 26–28), retained until mobile bet path is settled (RECONCILIATION R3).
- **Legacy powerup "Battle Chits"** (`battle_chit_definitions`) — dormant; superseded by the moment-chit asset (Hard Rule 27).
- **Campaigns**: ARCHIVED (migration 089, replaced by Likeness Cards). Tables `campaigns_archived_*`, read-only. Do not resurrect.

## Building future work safely (governance)
Everything queued in PLAN.md must respect these, in addition to the Hard Rules above:
- **Migrations** apply only via the git-driven `supabase db push` flow so the
  `schema_migrations` ledger stays consistent. NEVER hand-run DDL through the Management API
  query endpoint — it applies the change without recording it and breaks the next push.
- **Likeness/card language** is collectible game assets, never financial instruments. Never use
  "investment", "return", "yield", "dividend", or "revenue share" in card-facing copy or code.
- **Append-only ledgers** — `likeness_card_transfers`, `lkn_agreements`, `campaigns_archived_ledger`
  — are INSERT-only. Never UPDATE an existing row (status-only changes on lkn_agreements per Rule 29).
- **sim vs live** is a per-feature mode flag (campaigns/cards/Emergency Fund/licensing). Build new money
  flows in sim first; KYC + payment gates flip on at live launch only. All monetary values are integer
  USD cents — no floating point anywhere in money math.
- **KYC staking gates** (`platform_integrity_settings`) default off in sim; flipping them on is the live-launch
  switch. `enforce_one_role_per_match` stays TRUE always (money-independent integrity).
- **IAP / token credit** functions must be idempotent (ON CONFLICT DO NOTHING + a receipt ledger) — web Stripe
  and mobile RevenueCat both credit the same `token_transactions`.
- **No backend in the mobile repo**: nora-arena is frontend-only. All tables, edge functions, and pg_cron
  stay in this Supabase project. Mobile reaches licensing only through `api.noraplatforms.com/v1/verify`.
- **Dev tooling** (arena bot-backer, test-match maintainer, dev_* RPCs) must be removed before launch — see the
  pre-launch reset sequence in ARCHIVE.md.

## Reference
- v3 card-battler spec (canonical *what*): **NORA_PLATFORMS_BUILD_SPEC_v3.md**
- Minting + Match Cut spec (web minting, consent/moderation stack, templates, wager mode): **NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md**
- Minting workflow v2 (device-clip upload + trimmer, V2V middle, AGNOSTIC plates + bridge stitch — **governs where it conflicts with the two specs above**; naming: its "battle_chits" = `moment_chits`): **Minting_Workflow.md**
- Cinematic Engine spec (anchor plates + motion prompts + Seedance/Segmind generation; supersedes the anchor-plate doc; §4 prompt grammar + moderation stack still govern under v2): **NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md**
- Chit marketplace spec (fixed-price, token-first; M1+M2 shipped, M3+ queued): **NORA_PLATFORMS_MARKETPLACE_SPEC.md**
- Crossplay spec (web↔Arena shared matchmaking queue + play/spectate contract; migs 159–160 LIVE): **NORA_PLATFORMS_CROSSPLAY_SPEC.md**
- Standard Playset + launch seeding (30 starter cards, admin seed path, marketing pipeline, mint-reveal
  share loop, Founding Market Makers; S1–S4 built, migs 181–184): **NORA_PLATFORMS_STANDARD_PLAYSET_SPEC.md**
  · cohort runbook `tools/playset/FOUNDING_COHORT_RUNBOOK.md` · marketing review gate `tools/marketing/README.md`
- Effect system: design principles **NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md** · reactive-depth roadmap
  **NORA_INTERACTION_LAYER_SPEC.md** (the live Wave-1 library is the DB `effect_templates`; design record in ARCHIVE)
- Where we're going, with build checklists (incl. the v3 P7 remainder): **PLAN.md**
- Doc map / entry point for a new agent: **README.md**
- History, scoring formulas, DB schemas, infra (edge fns / pg_cron / routes), Arena testing, deploy runbooks,
  deprecated Campaigns framework, redesign migration ledger: **ARCHIVE.md**
- Arena + Battle mobile app lives in a separate repo (`arunernorainvestments-cmd/nora-arena`, its own CLAUDE.md). Shares this backend. Cross-repo contract + open decisions: **RECONCILIATION.md**.
