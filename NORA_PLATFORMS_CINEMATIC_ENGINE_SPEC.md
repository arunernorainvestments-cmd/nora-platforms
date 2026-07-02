# NORA Platforms — Cinematic Engine Spec (Battlechit Generation)
**For Claude Code. This CONSOLIDATES AND SUPERSEDES `NORA_PLATFORMS_ANCHOR_PLATE_GENERATION.md`. It extends `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md` (whose consent/moderation/ownership phases remain governing) and the v3 build spec. Read those + CLAUDE.md, ARCHIVE.md, PLAN.md, RECONCILIATION.md first.**

> The engine: every battlechit cutscene is **forced to open on a fixed start-plate and close on a fixed end-plate** (per Match Cut template); only the **middle is unique**, driven by the user's post through a house-owned **motion prompt template**. Unity brackets the finished MP4 with a matching local-space anchor, so the seam works on any stage. Nothing is generated at runtime — chits are pre-generated MP4s loaded from `battle-media` during match load.

---

## 1. TOOL DETERMINATION (final)

**Model: Seedance 2.0 (ByteDance). Access layer: Segmind. Higgsfield: dropped. Fallback: BytePlus ModelArk (official Seedance API).**

| Requirement | Seedance 2.0 delivers |
|---|---|
| Deterministic bookends | First/last-frame conditioning is a first-class mode: `first_frame_url` + `last_frame_url` (last requires first); the model must start on A and land on B, synthesizing real motion between — not a crossfade. |
| On-model middle | Documented **style-lock** behavior (visual style doesn't drift during generation) — directly mitigates our biggest risk. |
| Re-runs after moderation rejection | **`seed`** parameter → reproducible iteration; change only the prompt slot that failed. |
| Our template durations | 4–15s clips (our templates run 2–7s; use 4–6s typical). 480p/720p on Fast; 1080p on standard. **Aspect ratio follows the reference frames** → plates must be authored at the target aspect (16:9). |
| Prompt control | Documented grammar **Subject > Action > Environment > Camera > Style > Constraints** — maps 1:1 onto our motion prompt template (§4). Multi-shot `Shot 1:/Shot 2:` syntax available if a template needs beats. |
| Stylized content | Seedance is strict on realistic-human references but happy with stylized/cartoon ones — and we stylize the user's moment **before** video generation, so we're on its happy path by design. |

**Why Segmind as the layer:** it hosts Seedance 2.0 Fast with the explicit first/last-frame + seed params **and** the image models — one vendor/API key for the whole chain (illustration → plates → video). Use **Fast** for drafts/dev (≈2x speed, lower cost), **standard** for final renders. Moderation is **ours** regardless of provider (mandatory pre-gen + post-gen layers per the Minting spec); any provider-side nsfw filtering is a bonus, never a substitute.

---

## 2. The two house-owned components (the engine)

1. **Anchor plates (bookends):** a fixed **start-plate + end-plate per Match Cut template** (~6 templates → ~12 plates), authored **once** in the game's cel-shaded style at 16:9, matching the exact framing Unity's anchor camera holds. Registry: `match_cut_anchor_plates` (template_id, start_plate_url, end_plate_url, aspect, version).
2. **Motion prompt templates (the middle):** one house-owned prompt per template (§4) that drives what happens between the plates. Registry: `match_cut_prompt_templates` (template_id, prompt_body, version, tuned_against_plate_version).

Pinning both ends is what **frees the middle**: the bookends are identical and pre-known (seam guaranteed), the middle is infinitely variable (no two cards alike). At runtime the "cinematic" is a cached MP4 playing between two frames Unity already brackets — that's the "how did a mobile game animate all this?" effect.

**Guardrail:** identical bookends do **not** vouch for the middle. Style-lock + motion constraints live in the prompt template; **post-generation moderation on the finished MP4 is mandatory** (same minor-safety/nsfw/violence bar as pre-gen).

---

## 3. The pipeline (end to end)

1. **Source (governed by the Minting spec — unchanged):** OAuth-owned post only; TikTok/IG/YT allowlist; ingest via official API/oEmbed; **mandatory pre-gen moderation** (minor-safety absolute).
2. **Classify + tier:** archetype family + tier from engagement (cost-banded ladder). Select the **Match Cut template** from the chit's role.
3. **Illustration:** image model (via Segmind; a strong stylized model — Seedream/Nano-Banana-class) reads the post thumbnail + the built-in battlechit illustration script → card art in house style. This stylized still also serves as the **subject reference** for the video step.
4. **Cutscene (Seedance 2.0 via Segmind):** `first_frame_url` = template start-plate, `last_frame_url` = template end-plate, subject reference = the stylized illustration, prompt = the template's motion prompt with slots filled (§4), fixed `seed` recorded. Draft on Fast → final on standard.
5. **Post-gen moderation** on the MP4 (reject → adjust slot/seed → re-run).
6. **Preview:** the user inspects the card + plays the cutscene in a **practice/preview battle** before the chit finalizes.
7. **Store + write:** MP4 → **`battle-media`** (never hotlink the provider URL); write `battle_chits` (+ `match_cut_template_id`, `anchor_plate_version`, `prompt_template_version`, `generation_seed`) + `chit_ownership`. Arena loads it via Addressables at match load.

---

## 4. MOTION PROMPT TEMPLATES — how the middle works

Every template is the same fixed grammar with three fill-slots. The grammar mirrors Seedance's documented structure so the model parses it natively:

```
[SUBJECT]     {SUBJECT_DESC} — from the stylized illustration (reference image), 1–2 lines
[ACTION]      {FAMILY_ACTION} performed with {TIER_INTENSITY} — the template's role verb
[ENVIRONMENT] the neutral stylized arena backdrop of the plates; stage lighting dimmed
[CAMERA]      fixed per template (matches the anchor rig's camera pose); no cuts unless the template defines beats
[STYLE]       cel-shaded anime, bold ink outlines, house palette (#6C63FF/#03DAC6 accents), flat shadows   ← STYLE LOCK, never omitted
[CONSTRAINTS] open exactly on the first frame; resolve exactly to the last frame; smooth motion; stable framing; no text, no logos, no real-world photographic look
```

**The three slots (everything else is fixed):**
- **`{SUBJECT_DESC}`** — what the classifier extracted from the post ("a formation of fighter jets", "a dancer mid-spin"), always described as its **stylized** version.
- **`{FAMILY_ACTION}`** — the archetype family's verb phrase for this template's role (athlete/`projectile_strike` → "streaks toward the target and strikes"; musician/`radial_burst` → "unleashes a shockwave of sound rings outward").
- **`{TIER_INTENSITY}`** — VFX scale by tier (F: "modest, quick" → S: "screen-filling, overwhelming spectacle"). Higher-tier cards *look* rarer at zero extra cost.

**Worked example — `projectile_strike`, source: military-jets post, tier A:**
> Subject: a squadron of cel-shaded fighter jets (see reference image) in bold ink-outline anime style. Action: the jets roar in from behind the summoner's shoulder and launch a volley of missiles that streak toward the opponent and strike with a massive, screen-shaking explosion. Environment: the neutral stylized arena backdrop, stage lights dimmed to a vignette. Camera: locked over-the-shoulder toward the opponent, slow push-in, no cuts. Style: cel-shaded anime, bold ink outlines, flat shadows, house palette accents. Constraints: open exactly on the first frame; the explosion whites out and resolves exactly to the last frame; smooth motion; no text or logos; no photographic realism.

**Worked example — `aura_surge`, source: dance-clip post, tier D:**
> Subject: a cel-shaded dancer (see reference image). Action: performs their signature spin, trailing modest ribbons of teal light that wrap the ally in a brief glow. Environment/Camera/Style/Constraints: [fixed blocks as above; resolve to the `aura_surge` end-plate].

**Authoring rules:** one prompt template per Match Cut template (~6 at launch); the STYLE and CONSTRAINTS blocks are **never** user-influenced or omitted; templates are versioned and tuned against a specific plate version; a rejected generation re-runs by adjusting only `{SUBJECT_DESC}` phrasing (fixed seed), not the fixed blocks.

---

## PHASES

**C0 — Registries + tool wiring:** `match_cut_anchor_plates` + `match_cut_prompt_templates` (both versioned); Segmind client (image + Seedance 2.0 Fast/standard) with seed capture; config for draft-vs-final tier. *Deliver:* registries, client, one round-trip smoke test. **DO NOT** hardcode provider URLs into chits.

**C1 — Author the plates + prompts:** generate the ~12 plates (16:9, house style, matching Unity's anchor poses) and write the 6 motion prompt templates per §4. *Deliver:* all plates + prompts versioned; visual sign-off against the Arena anchor poses. **DO NOT** author per-card plates/prompts; don't omit the style-lock.

**C2 — Generation pipeline:** wire §3 steps 2–7 (classify→template select→illustration→Seedance cutscene→post-gen moderation→preview→store+write). Persist `anchor_plate_version`, `prompt_template_version`, `generation_seed` on the chit; `final_frame_camera` remains **deprecated**. *Deliver:* end-to-end mint of one real post → playable chit; moderation reject/re-run path proven; preview-battle hook. **DO NOT** treat clean bookends as proof the middle is safe; don't finalize a chit the user hasn't previewed; don't skip storing to `battle-media`.

**C3 — Contract:** RECONCILIATION updated (chit fields above; plate/prompt registries; Unity owns camera pose via its anchor). *Deliver:* contract mirrored.

---

## Cross-repo contract

| Platforms provides | Arena consumes |
|---|---|
| `match_cut_template_id` + `anchor_plate_version` on the chit | selects the local `MatchCutAnchor`; validates plate version |
| cutscene MP4 (opens on start-plate, closes on end-plate) in `battle-media` | Addressables → `VideoPlayer`, mounted on the anchor |
| `match_cut_anchor_plates` (versioned) | anchor camera poses are authored to match these |
| `match_cut_prompt_templates`, `generation_seed` | n/a (generation-side only) |

Encapsulate the whole thing as a clean internal service (plates + prompt + source in → one bracketed MP4 out) — a future standalone "cinematic generator" product then costs nothing extra today. Focus: working in Unity first.
