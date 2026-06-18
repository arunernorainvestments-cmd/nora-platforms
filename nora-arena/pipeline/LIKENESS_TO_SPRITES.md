# Pipeline: Licensed Likeness → Animated Character

How an agent turns a **licensed portrait** into an **animated battle character**
using AI image generation (Gemini "Nano Banana" via Antigravity, or an image-gen
MCP). This is the feature that takes us beyond static, hand-made sprite sheets:
each character is generated from the real person the user licensed, with a
consistent face across all battle states.

Inputs come from the import flow (`core/services/license_sync_service.dart`):
`portraitUrl`, `displayName`, `archetype`, `stats`, and the **verify response**
(license status + permitted purposes + restrictions).

---

## Step 0 — Compliance gate (run BEFORE generating anything)
Generating a game character from someone's likeness is only allowed inside the
license they sold. From the `lkn-verify` response for this license:
- Require `license_status == "active"` **and** `use_category_permitted == true`
  for `entertainment_game`.
- Read `restrictions`:
  - if `adult_content_allowed == false` → keep prompts strictly all-ages.
  - if `political_content_allowed == false` → no political imagery/props.
  - respect `restricted_topics[]`.
  - if `ai_generated_must_be_labeled == true` → stamp an "AI" marker on the
    character card and store `ai_labeled: true` in the sheet manifest.
- If the gate fails, **do not generate** — fall back to a neutral archetype rig.

This keeps the whole licensing thesis intact: the game only ever uses a likeness
the way the licensor agreed to.

---

## Step 1 — Style lock
Generate all states in ONE consistent art style so a roster looks cohesive.
Use this fixed style preamble for every generation:

```
STYLE: high-quality 2D game character, clean cel-shaded, bold rim light,
vibrant, mobile-game splash quality, full body, centered, transparent background,
consistent character identity, no text, no watermark.
PALETTE: dark UI context — bg #0A0A0F, accents #6C63FF / #03DAC6.
```

## Step 2 — Identity seed (character consistency)
Seed the model with the licensed `portraitUrl` and instruct it to **preserve the
person's identity** (face, hair, signature look) across every state. With Gemini's
image model, pass the portrait as a reference image on each call and reference the
prior frame to lock consistency. Produce a neutral **base render** first; reuse it
as the reference for all six states.

Map the creator's `archetype` (from stats — see `unlocked_character.dart`) to a
costume/silhouette cue, e.g. `bruiser`→heavy, `striker`→agile, `icon`→glamorous.

## Step 3 — Generate the 6 battle states
For each state, generate a short frame run from the base render, same identity:

| State   | Frames | stepTime | loop  | Prompt cue |
|---------|:------:|:--------:|:-----:|------------|
| idle    | 6      | 0.12     | true  | gentle breathing/sway, weight shift |
| attack  | 8      | 0.06     | false | wind-up → strike → recover |
| defend  | 4      | 0.10     | true  | guard stance, brace |
| hit     | 3      | 0.08     | false | recoil, flinch |
| ko      | 5      | 0.10     | false | stagger → fall |
| victory | 6      | 0.12     | true  | celebratory loop |

Per-state prompt template:
```
{STYLE preamble}
Same character as the reference (preserve identity exactly).
Action: {state cue}. Generate {frames} sequential frames as an evenly-spaced
horizontal strip, identical framing/scale/lighting between frames.
```

## Step 4 — Pack the sheet
Compose all states into a single grid PNG: **one state per row**, **512×512 per
cell**, left-to-right frames. Filename: `{licensor_nora_id}__{license_id}.png`.
(Claude writes the packing script; Antigravity/Gemini produces the frames.)

## Step 5 — Emit the companion manifest
Next to the PNG, write `{...}.json` that the Flame loader reads:

```json
{
  "image": "bb32515d__LKN-2026-A4X9B2CQ.png",
  "frame_width": 512,
  "frame_height": 512,
  "ai_labeled": false,
  "license_id": "LKN-2026-A4X9B2CQ",
  "states": {
    "idle":    { "row": 0, "frames": 6, "step_time": 0.12, "loop": true  },
    "attack":  { "row": 1, "frames": 8, "step_time": 0.06, "loop": false },
    "defend":  { "row": 2, "frames": 4, "step_time": 0.10, "loop": true  },
    "hit":     { "row": 3, "frames": 3, "step_time": 0.08, "loop": false },
    "ko":      { "row": 4, "frames": 5, "step_time": 0.10, "loop": false },
    "victory": { "row": 5, "frames": 6, "step_time": 0.12, "loop": true  }
  }
}
```

The loader (Claude, Phase 4) builds a Flame `SpriteAnimationData.sequenced` per
state from this manifest and feeds `CharacterRig.applyState(...)` off
`battle_events`. **Stat-driven modifiers (scale/aura/SFX) are applied at render
time in code, NOT baked into the art** — so one generated sheet stays reusable.

## Step 6 — Cache
Generation is the slow/expensive step. Cache by `licensor_nora_id` so a creator is
generated once and reused for every match and every buyer.
- POC: device cache (path_provider).
- Production: a public `arena-character-cache` Supabase Storage bucket keyed by
  licensor — **noted nora-platforms follow-up; do not assume it exists.**

---

## Beyond frame-based (optional upgrades, same tools)
- **Smoother motion:** run an image-to-video / interpolation model (available via
  a fal.ai/Replicate MCP) on the generated frames, then sample back to sprites.
- **Backgrounds:** generate 3 parallax layers (far/mid/near) per `battle_map`.
- **Ability FX:** Claude authors Lottie JSON directly — no image model needed.
