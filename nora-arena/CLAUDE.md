# NORA Arena — CLAUDE.md

## Parent App
This app shares a Supabase backend with **nora-platforms**.
- Web repo: arunernorainvestments-cmd/nora-platforms
- Supabase ref: cceisywxwhgljdpisjrl (SAME project, same anon key)
- N.O.R.A. licensing API: https://api.noraplatforms.com/v1
- Governing spec: nora_redesign_doc6_mobile_app.md (in nora-platforms)

## Hard Rules (nora-platforms rules carry over, plus these)
1. Plain Riverpod only — no codegen, no `@riverpod`, no build_runner. Ever.
2. NO database schema changes in this repo. All migrations live in nora-platforms.
3. NO new Supabase edge functions in this repo. All edge functions live in nora-platforms.
4. License verification ALWAYS goes through the N.O.R.A. API (`lkn-verify`) — it is
   the source of truth for whether a character may be used. Never unlock a
   character from registry/stat data alone. Re-verify before battle start.
5. Shared models must match nora-platforms exactly — carry a `// SHARED MODEL` comment.
6. Never hardcode API keys (Supabase anon, N.O.R.A. API key). Load from env/secure store.
7. Frame rate target: 60fps on mid-range devices. Profile before shipping; drop
   Lottie/particle complexity before dropping frames.
8. Handle API/HTTP failures gracefully — log and degrade (cached unlocks), never
   crash the character-select flow (mirrors nora-platforms Hard Rule 8).
9. `flutter analyze` zero issues before every commit.

## Tech Stack (see ARCHITECTURE.md for the why)
Flutter mobile (iOS + Android) · Flame (engine) · Rive (character rigs) ·
Lottie (effects) · Impeller rendering · flutter_riverpod (no codegen) · GoRouter ·
Firebase Cloud Messaging (push) · RevenueCat (IAP).

## Theme (identical to web)
bg #0A0A0F | surface #1A1A2E | primary #6C63FF | secondary #03DAC6 |
success #00C896 | danger #FF4757

## Asset Naming (same as nora-platforms docs/battle-spec.md / doc3)
- assets/battle/rive/[archetype].riv          — character rig (state machine)
- assets/battle/sprites/[archetype]_[state].png + .json   — sprite fallback
- assets/battle/lottie/[archetype]_ability_[slot].json
- assets/battle/lottie/system_[event].json
