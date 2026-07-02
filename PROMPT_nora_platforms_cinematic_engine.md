# Claude Code Kickoff Prompt — NORA Platforms: Cinematic Engine

You are implementing `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md` in the `nora-platforms` repo. It **supersedes** `NORA_PLATFORMS_ANCHOR_PLATE_GENERATION.md` (delete/archive that file if present) and **extends** `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md`, whose consent, allowlist, and moderation phases remain governing. Read those + `CLAUDE.md`, `ARCHIVE.md`, `PLAN.md`, `RECONCILIATION.md` first, and verify the v3 CCG tables exist before extending.

## The engine in one paragraph
Every battlechit cutscene is generated to **open on a fixed start-plate and close on a fixed end-plate** (one plate pair per Match Cut template, ~12 total, authored once). A house-owned **motion prompt template** per template drives the unique middle from the user's post. Unity brackets the MP4 with a matching local anchor, so the seam works on any stage. Nothing generates at runtime — the MP4 is pre-generated, stored in `battle-media`, and preloaded at match load.

## Tool determination (final — do not relitigate)
**Model: Seedance 2.0. Access layer: Segmind** (hosts Seedance 2.0 Fast with `first_frame_url`/`last_frame_url` + `seed`, and the image models — one vendor for illustration → plates → video). Fast tier for drafts, standard for finals. Fallback provider: BytePlus ModelArk. Higgsfield is dropped. **Moderation is ours regardless of provider** — the mandatory pre-gen and post-gen layers from the Minting spec apply unchanged; provider filtering is a bonus, never a substitute.

## Non-negotiable guardrails
- Plates and prompt templates are **per template, never per card**; both **versioned** (`match_cut_anchor_plates`, `match_cut_prompt_templates`).
- The prompt template's **STYLE (style-lock) and CONSTRAINTS blocks are fixed** — never user-influenced, never omitted. Only the three slots vary: `{SUBJECT_DESC}`, `{FAMILY_ACTION}`, `{TIER_INTENSITY}`.
- **Clean bookends do not vouch for the middle** — post-generation moderation on the finished MP4 is mandatory (minor-safety bar absolute). Rejected output → adjust `{SUBJECT_DESC}` only, fixed `seed`, re-run.
- Plates authored at **16:9** (Seedance's aspect follows the reference frames). Record `generation_seed`, `anchor_plate_version`, `prompt_template_version` on every chit. `final_frame_camera` stays deprecated.
- Store MP4s in **`battle-media`**; never hotlink the provider URL. The user must **preview the card in a practice battle** before the chit finalizes.
- All Minting-spec rules stand: OAuth-owned posts only, TikTok/IG/YT allowlist, users never set tier/stats.

## Execute
Phases C0→C3, one atomic PR each with the spec's checklist as the description. Migrations via `supabase db push`; `flutter analyze` clean before/after. C1 (authoring the 12 plates + 6 prompts) requires visual sign-off against the Arena anchor poses before C2 begins. Mirror the cross-repo contract into `RECONCILIATION.md`. Build the pipeline **encapsulated** (plates + prompt + source in → one bracketed MP4 out).

Start with **C0**. Report after each phase: what changed, checklist status, `flutter analyze` result, and (for C2) one end-to-end mint proof.
