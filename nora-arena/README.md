# N.O.R.A. Arena (nora-arena)

Mobile (iOS + Android) Arena/Battle app for the NORA platform. Pokémon-style
turn-based battler + Arena prediction-market spectator layer. Shares the
**same Supabase backend** as the web app (`nora-platforms`) — this is a new
**frontend only**. See `nora_redesign_doc6_mobile_app.md` in nora-platforms for
the governing spec.

> **This folder is a handoff scaffold** living temporarily inside the
> `nora-platforms` repo so the team (and Claude) can see the intended shape and
> iterate on the licensing **import** flow against the real backend. To make it a
> real app, extract it to its own repo and generate the native shells:
>
> ```bash
> # 1. Move this folder out to its own git repo: arunernorainvestments-cmd/nora-arena
> # 2. Generate android/ + ios/ shells (keeps lib/, pubspec.yaml, assets/):
> flutter create --platforms=ios,android --org com.noraplatforms .
> flutter pub get
> flutter analyze            # must be clean (CLAUDE.md rule)
> ```

## What's built in this scaffold
- **License import** (the headline cross-platform test) — `lib/core/services/license_sync_service.dart`
  + `lib/features/license_sync/`. A user who buys a likeness on noraplatforms.com
  taps "Sync", and the licensed creator appears as a playable character. This is
  wired end-to-end against the deployed licensing API + public registry.
- Config layer (`lib/core/config/`) — same Supabase keys + theme as web.
- Shared models (`lib/core/models/`) — `SHARED MODEL` copies kept in sync with
  nora-platforms.
- Game skeleton (`lib/features/battle/game/`) — the recommended Flame + Rive
  architecture (see `ARCHITECTURE.md`), stubbed for the art pipeline.

## What is NOT here yet (next phases — doc6 checklist)
- Full Flame battle loop + Rive rigs + Lottie effects (art pipeline dependent)
- Firebase Cloud Messaging wiring (needs a Firebase project)
- RevenueCat IAP — Dart/SDK side only (needs RevenueCat config); the backend
  `mobile_iap_confirm` edge function + migration 115 are already DEPLOYED in
  nora-platforms (see BUILD_WORKFLOW.md Phase 6)
- The native `android/` and `ios/` folders (run `flutter create`, above)

## Read first (especially AI build agents — Antigravity, Claude Code)
- `AGENTS.md` — orientation + agent division of labor. **Start here.**
- `BUILD_WORKFLOW.md` — phase-by-phase build plan (your task list).
- `ARCHITECTURE.md` — engine/language decision + **Addendum A** (AI-only assets,
  the C/C++ question, the likeness→character differentiator).
- `pipeline/LIKENESS_TO_SPRITES.md` — turn a licensed portrait into an animated
  character (prompts, sheet format, compliance gate).
- `tooling/image-gen.mcp.json.example` — image-generation MCP config to enable
  in-loop asset generation.
- `CLAUDE.md` — hard rules for this repo (binding for every agent).
