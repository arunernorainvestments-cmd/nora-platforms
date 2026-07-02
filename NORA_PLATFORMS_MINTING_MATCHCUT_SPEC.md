# NORA Platforms — Minting + Match Cut Integration Spec
**For Claude Code. Extends the completed `NORA_PLATFORMS_BUILD_SPEC_v3.md` — this is the next phase, not a rewrite. Read CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md first.**

> Context: the v3 CCG backend is built. This spec adds the **web-side minting pipeline** (Companion-App model: minting lives on Platforms web to avoid the 30% mobile-store fee and long mobile load screens), the **Match Cut** video contract that lets Unity seam 2D cutscenes into 3D gameplay, the **moderation + consent** stack, the **one-active-card** rule, and the **card-wager** game mode.

---

## 0. Principles

- Minting happens **outside combat**, on Platforms web: the user links a social post; Platforms generates the illustration + cutscene; the chit lands in the user's collection; Arena reads it live from Supabase.
- **Consent-based, not scraping:** users mint **their own** posts (OAuth-verified ownership). This is the legal spine — do not allow minting arbitrary third-party URLs.
- Money math integer cents; append-only ledgers INSERT-only; migrations via `supabase db push`; `flutter analyze` clean per phase.
- 🚧 **DECISION GATE G-MON** (carried from v3): a real-money market runs on a match **iff both players are KYC-verified**; royalty to moment-owners. Confirm before real-money go-live.

**Status tags:** [BUILT] · [NEW] · [REPURPOSE] · [CUT].

---

## PHASE 0 — Contract alignment

**Deliverables**
- [ ] CLAUDE.md: document the minting pipeline, the Match Cut contract (below), the moderation stack, the one-active-card rule, and the wager mode.
- [ ] Hard Rules (append): "Chits are minted only from a post the user owns (OAuth-verified); no arbitrary-URL or raw-upload minting at launch." · "Every minted cutscene MP4 is stored in `battle-media` (never a hotlinked provider URL) and carries a `match_cut_template_id` + `final_frame_camera`."
- [ ] RECONCILIATION.md: add the cross-repo contract — `battle_chits` gains `match_cut_template_id`, `final_frame_camera`, `original_minter_handle`, `source_platform`, `mp4_cutscene_url`; matches carry `is_monetized`; the spectator-bet RPC is `battle_place_spectator_bet_usd`.

**DO NOT** weaken KYC / minor-safety rules; they are load-bearing.

---

## PHASE 1 — Ingestion + consent + pre-generation moderation

**Goal:** get a moderated, owned, attributable source before any generation runs.

- [NEW] **OAuth account linking (Layer 0 consent):** link the user's TikTok / Instagram / YouTube account; minting is allowed **only for posts owned by the linked account.** Capture the creator handle for the card.
- [NEW] **Source allowlist (Layer 1):** **TikTok, Instagram, YouTube at launch** (strictest baseline moderation + clean oEmbed/APIs). X / Facebook deferred (require a stricter classifier). **No raw upload.**
- [NEW] **Ingest via official API/oEmbed** (not scraping): fetch thumbnail + representative frames + metadata (engagement count, creator handle, `source_platform`, post URL).
- [NEW] **Pre-generation vision moderation (Layer 2):** classify fetched frames before generating.
  - **Minor-safety / CSAM screening is absolute and non-negotiable:** hard-block any sexual content involving a minor or content that sexualizes a minor; route to human escalation; never generate. This screen runs first and cannot be bypassed.
  - Also block nsfw, graphic violence, hate content.
  - Flag third-party-likeness cases (the user's own post that prominently features other identifiable people) for review.

**Deliverables**
- [ ] OAuth linking for TikTok/IG/YT; ownership check gating mint.
- [ ] Source allowlist enforced; raw upload disabled.
- [ ] oEmbed/API ingestion capturing handle + engagement + platform.
- [ ] Pre-gen moderation with mandatory minor-safety block + nsfw/violence/hate + third-party-likeness flag.

**DO NOT** allow minting a post the user doesn't own. Don't accept off-allowlist sources or raw uploads. Never generate without passing the minor-safety screen.

---

## PHASE 2 — Classification + tier + generation

**Goal:** turn the owned, moderated source into a minted chit (illustration + cutscene + stats).

- [NEW] **Classify** content → `archetype_family` (the v3 effect-family classifier).
- [NEW] **Assign tier** from the v3 `engagement_tier_thresholds` using the post's current engagement (F–S). Derive cost/atk/hp/effect from the v3 cost-banded `tier_ladder`.
- [NEW] **Generate the illustration** (stylized cel-shaded keyframe in the game's style) — this is the card art.
- [NEW] **Generate the entry + exit keyframes** for the assigned Match Cut template (P3): stylized stills matching the template's opening camera and the exact `final_frame_camera` Unity resumes at.
- [NEW] **Generate the cutscene MP4** via a first/last-frame video model (Higgsfield API `input_images` + `input_images_end`, or Segmind workflow → Kling/Wan), conditioned on the entry+exit keyframes + the family-aesthetic prompt + the moment content; **`check_nsfw` on**.
- [NEW] **Post-generation moderation (Layer 4)** on the output MP4.
- [NEW] **Store the MP4 in `battle-media`** (CDN-fronted); write the CDN URL to `battle_chits.mp4_cutscene_url`. **Never hotlink the provider's expiring output URL.**
- [NEW] **Write the chit:** insert `battle_chits` (family, tier, cost/atk/hp/effect, `card_art_url`, `mp4_cutscene_url`, `match_cut_template_id`, `final_frame_camera`, `original_minter_handle`, `source_platform`) + grant via `chit_ownership`.

**Deliverables**
- [ ] Classify → family; tier from engagement; stats from the cost-banded ladder.
- [ ] Illustration + entry/exit keyframe generation.
- [ ] Cutscene generation (first/last-frame conditioned, `check_nsfw` on) + post-gen moderation.
- [ ] MP4 stored in `battle-media`; chit written + ownership granted.

**DO NOT** let the user set tier/stats. Don't skip post-gen moderation. Don't store the provider URL as the chit's video source.

---

## PHASE 3 — Match Cut template system

**Goal:** the finite set of camera geometries that make the 2D→3D seam invisible, plus the directive-assembly logic.

- [NEW] **`match_cut_templates`** — a launch set of ~6 (expandable to ~10), each keyed by gameplay **role** and defining: `entry_framing`, `exit_framing`, `final_frame_camera` (structured: angle/height/target/fov for Unity to align), `duration_s`, and the stage-transition (dim/fade behavior). **Archetype family + moment content fill the aesthetic within the geometry; the geometry is what Unity aligns to.**

| id | role | entry | exit (`final_frame_camera` → Unity resume) | dur |
|---|---|---|---|---|
| `ground_slam` | aggressive creature summon | low push-in on caster; stage dims to vignette | low-angle on entity's base hitting spawn point → Unity low-angle on 3D creature at spawn | 4–6s |
| `sky_descent` | majestic creature summon | crane up; stage dims | high-angle down as entity lands center-field → Unity high-angle on creature at spawn | 5–7s |
| `projectile_strike` | single-target attack spell | over-caster-shoulder toward opponent; stage dims | framed on opponent at white-flash impact → Unity cut to opponent hit-react (matching angle) | 3–5s |
| `radial_burst` | AoE spell | pull to wide/high overview; stage dims | top-down/wide of shockwave over field, edge-fade → Unity wide gameplay cam, all targets hit-react | 3–5s |
| `aura_surge` | buff/heal | orbit to center on target; partial dim | centered on target glowing → Unity cut to target 3D body + buff VFX (no hit-react) | 3–4s |
| `counter_veil` | counter/defensive | rapid push-in on caster; stage flash | caster in rebound stance facing threat → Unity cut to caster, attacker recoils | 2–4s |

- [NEW] **Directive assembly:** given a chit's `chit_type` + role → pick the template (camera geometry); `archetype_family` + moment → aesthetic prompt; assemble the generation prompt + the entry/exit keyframe specs; persist `match_cut_template_id` + `final_frame_camera` on the chit.

**Deliverables**
- [ ] `match_cut_templates` (6 launch templates with entry/exit/`final_frame_camera`/duration/transition).
- [ ] Directive-assembly logic (role→geometry, family→aesthetic) wired into P2 generation.
- [ ] `match_cut_template_id` + `final_frame_camera` persisted per chit (the seam contract Arena reads).

**DO NOT** let the number of exit geometries sprawl (Unity must support each resume-camera). Don't leave `final_frame_camera` unset — it's what makes the seam work.

---

## PHASE 4 — One-active-card rule + card-wager game mode

**Goal:** the "your card, your moment, your handle" constraint + the risk-your-card game type.

- [NEW] **One active self-minted chit per user.** Mark the user's minted chit `self_minted`. A user may hold at most one at a time. **Swap flow:** the client requests a swap → Platforms returns a **warning** (the old card + its media will be permanently deleted) → on confirm, delete the old chit + its `battle-media` assets, then mint the new one. (Template starter cards and cards won via wager are separate and unaffected.)
- [NEW] **Card-wager game mode.** A match type `wager_match`: at match start both players **stake a chit into escrow**; on resolution, the **winner receives the loser's staked chit** (ownership transfer in `chit_ownership`), the loser's copy is removed. **The chit keeps its `original_minter_handle`** (attribution ≠ ownership). This is a distinct game type, not a normal-match mechanic; the stake is explicit and confirmed client-side.

**Deliverables**
- [ ] One `self_minted` chit per user enforced; swap = warn → delete old (chit + media) → mint new.
- [ ] `wager_match` type: chit escrow at start; ownership transfer to winner on resolution; attribution retained; safe/atomic transfer.

**DO NOT** delete the old card before the new mint is confirmed. Don't transfer a wagered chit except on a resolved `wager_match`. Don't strip original-minter attribution on transfer.

---

## PHASE 5 — Avatar loadout + crosswalk + monetized flag + bet RPC

**Goal:** the small integration items Arena depends on.

- [NEW] **Avatar loadout:** read/write `profiles.avatar_loadout` (JSON, e.g. `{"Gender":"Male","SkinId":"skin_male_casual"}`). Platforms does **not** build a 3D editor; it just persists what Arena's Dressing Room writes. (Optional, low priority: a static 2D thumbnail per skin id for the web dashboard — skip for launch.)
- [NEW] **Account crosswalk:** both apps authenticate against the **same Supabase project**; ensure a user is the **same `auth.users`/`profiles` identity** in both (same OAuth provider / magic-link; support a mobile deep-link/OAuth handoff so linking is near-invisible). Verify the round-trip: a loadout saved in Arena is readable on web and vice-versa.
- [BUILT→ALIGN] **Monetized flag:** set `is_monetized` on the match row per G-MON (both players KYC'd); Arena reads it to gate the bet UI.
- [BUILT→ALIGN] **Bet RPC name:** expose **`battle_place_spectator_bet_usd`** (the RPC Arena's `SpectatorMarketService` calls), USD-denominated, KYC-gated.

**Deliverables**
- [ ] `profiles.avatar_loadout` read/write; round-trip verified with Arena.
- [ ] Same-Supabase-identity crosswalk confirmed; mobile handoff path documented.
- [ ] `is_monetized` set per G-MON; `battle_place_spectator_bet_usd` exposed and KYC-gated.

**DO NOT** build a web 3D avatar editor. Don't create a real-money market / allow USD bets unless `is_monetized` (both players KYC'd).

---

## Cross-repo contract (mirror into RECONCILIATION)

| Platforms provides | Arena consumes |
|---|---|
| `battle_chits` + `match_cut_template_id`, `final_frame_camera`, `card_art_url`, `mp4_cutscene_url`, `original_minter_handle`, `source_platform` | full-card view (handle at top) + Match Cut seam (align 3D cam to `final_frame_camera`) |
| MP4s hosted in `battle-media` (CDN) | Addressables → `VideoPlayer` |
| `is_monetized` on the match | gate the spectator bet UI |
| `battle_place_spectator_bet_usd` RPC | `SpectatorMarketService` |
| One `self_minted` chit / swap-delete semantics | swap warning UI |
| `wager_match` type + ownership transfer | wager mode UI + resolution reveal |
| `profiles.avatar_loadout` | Dressing Room read/write |

Minting is web-only (off the mobile store fee). One open product call: 🚧 **G-MON**.
