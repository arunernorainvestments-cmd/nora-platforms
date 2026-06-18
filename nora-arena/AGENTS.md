# AGENTS.md — Orientation for AI build agents (Antigravity, Claude Code, etc.)

You are building **N.O.R.A. Arena**, the mobile Arena/Battle app for the NORA
platform. All code AND all visual assets on this project are produced by AI
agents — there is no human art team. Read this file first, then the docs below.

## Read in this order
1. `CLAUDE.md` — hard rules (they are binding for every agent, not just Claude).
2. `BUILD_WORKFLOW.md` — the phase-by-phase plan. **This is your task list.**
3. `ARCHITECTURE.md` — engine choices + the AI-only asset decision (Addendum A).
4. `pipeline/LIKENESS_TO_SPRITES.md` — how to turn a licensed portrait into an
   animated character (the core differentiator).
5. The governing spec: `../nora_redesign_doc6_mobile_app.md` (doc6).

## What this app is
A Pokémon-style, turn-based 2D battler + an Arena prediction-market spectator
layer. It shares the **nora-platforms Supabase backend** (same project, same anon
key). This repo is **frontend only** — never add DB migrations or edge functions
here (they live in nora-platforms).

## Agent division of labor (important under the AI-only-assets constraint)
| Work | Best agent | Output format |
|---|---|---|
| Dart / Flame wiring, render code, shaders, sprite-sheet packing | Claude Code / Antigravity | `.dart`, GLSL |
| Ability + UI effect animations | Claude (authors JSON directly) | **Lottie `.json`** |
| Character models + battle-state sprites (likeness consistency) | **Antigravity → Gemini image ("Nano Banana")** | PNG sprite sheets |
| Backgrounds / parallax layers | Antigravity → Gemini image | PNG |

## Non-negotiables (full list in CLAUDE.md)
- Plain Riverpod. **No codegen / @riverpod / build_runner. Ever.**
- The licensing API (`lkn-verify`) is the **source of truth** for character
  ownership. Never unlock a character from display/stat data alone.
- AI-generated likeness assets must stay **within the license's permitted purposes
  and restrictions** (from the verify response). Honor `ai_generated_must_be_labeled`.
- `flutter analyze` clean before every commit. 60fps target.
