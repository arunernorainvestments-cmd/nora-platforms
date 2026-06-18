# N.O.R.A. Arena — Build Workflow

The master plan for building this app with AI agents (Antigravity + Claude Code).
Work top to bottom. Each phase has a **goal**, **who generates what**, **steps**,
and **done-when** acceptance criteria. Do not start a phase until the previous
phase's "done-when" is met. Backend is shared and frozen — **no migrations or edge
functions in this repo** (CLAUDE.md rule 2/3).

> Constraint baked into this workflow: **every asset is AI-generated** (Claude for
> code + Lottie; Antigravity/Gemini for images). See `ARCHITECTURE.md` Addendum A
> and `pipeline/LIKENESS_TO_SPRITES.md`.

---

## Phase 0 — Repo bootstrap
**Goal:** a running, analyzable app shell.
**Generates:** Claude Code / Antigravity (Dart, config).
**Steps**
1. Extract this `nora-arena/` folder to its own repo
   (`arunernorainvestments-cmd/nora-arena`).
2. `flutter create --platforms=ios,android --org com.noraplatforms .`
   (keeps `lib/`, `pubspec.yaml`, `assets/`; generates `android/` + `ios/`).
3. `cp .env.example .env` and fill `SUPABASE_ANON_KEY`, `NORA_API_KEY`. Until the
   `api.noraplatforms.com` gateway is live, set
   `NORA_API_BASE=https://cceisywxwhgljdpisjrl.functions.supabase.co` (the config
   auto-resolves `/lkn-verify`).
4. `flutter pub get && flutter analyze` (must be clean).
**Done when:** app launches to `/characters` and `flutter analyze` is clean.

---

## Phase 1 — Auth (shared session)
**Goal:** user logs in with their nora-platforms account; session works app-wide.
**Generates:** Claude Code (Dart).
**Steps**
1. Add `features/auth/` — email/password sign-in via `supabase_flutter`
   (same project → same account). Note on screen: "Use the same account as
   N.O.R.A. Platforms."
2. Gate `/characters` and `/license-sync` behind an authed redirect in `router.dart`.
**Done when:** a web-app account signs in here and `SupabaseService.currentUserId`
is non-null across screens.

---

## Phase 2 — License import (scaffolded — finish it)
**Goal:** licenses bought on the web appear as characters here.
**Generates:** Claude Code (Dart). Already scaffolded — verify + harden.
**Steps**
1. Confirm `LicenseSyncService.importLicensedCharacters` returns the user's
   `entertainment_game` licenses (verify is source of truth) enriched from
   `lkn_public_registry` + `creator_stat_sheets`.
2. Add local cache (24h TTL) of the last good unlock list so a network blip doesn't
   empty character-select (doc6 risk table; CLAUDE.md rule 8).
3. Re-verify a single license at battle entry (`NoraApiService.verifyForBattle`).
**Done when:** a license purchased on web shows in character-select after Sync;
expired/revoked licenses do **not** appear; offline shows cached unlocks.

---

## Phase 3 — AI character asset pipeline ★ (the differentiator)
**Goal:** each licensed creator becomes an **animated** character generated from
their licensed portrait — no human art.
**Generates:** **Antigravity → Gemini image (Nano Banana)** for sprites; Claude for
the packing + loader code.
**Steps** (full detail in `pipeline/LIKENESS_TO_SPRITES.md`)
1. **Compliance gate first:** only generate if the verify response says
   `use_category_permitted == true`; honor `restrictions` (e.g. no adult/political
   if restricted) and set an "AI" label when `ai_generated_must_be_labeled`.
2. Seed Gemini with the licensed portrait; generate the 6 battle states
   (idle/attack/defend/hit/ko/victory) **keeping the same face** (model's
   character-consistency). Pack into a grid sprite sheet (512×512 cells).
3. Emit the companion JSON (`pipeline/LIKENESS_TO_SPRITES.md` §Sheet Format).
4. Claude writes the loader that builds a Flame `SpriteAnimationData.sequenced`
   per state and swaps the `CharacterRig` stub for the real animation.
5. Cache generated sheets per `licensor_nora_id` (device cache for the POC; a
   shared `arena-character-cache` Storage bucket is a noted nora-platforms
   follow-up — do not assume it exists yet).
**Done when:** importing a license yields a character that plays an idle loop and
an attack animation in a test scene at 60fps, with the licensed likeness recognizable.

---

## Phase 4 — Battle game (Flame)
**Goal:** the real 2v2/3v3 battle renders, server-authoritative.
**Generates:** Claude (Flame loop, shaders, juice); Claude (Lottie FX); Antigravity
(parallax backgrounds).
**Steps**
1. `ArenaBattleGame`: load `battle_maps` background as a 3-layer ParallaxComponent.
2. Place `CharacterRig`s (Phase 3 animations) at team slots; apply stat-driven
   modifiers (Power→scale, Charisma→aura, Influence→crowd SFX).
3. Subscribe to **`battle_events` Realtime**; drive each rig's state. App is
   **display-only** — all logic is server-side (`process_battle_turn`).
4. Ability/chit activation → **Lottie** overlay (Claude-authored JSON) + screen
   shake + hit-pause. KO → shake + particle burst.
5. HUD (health/AP/momentum) as Flutter overlays via `game.overlays`.
**Done when:** a live battle plays from `battle_events` at 60fps on a mid device;
abilities + KO read as cinematic; no client-side game logic.

---

## Phase 5 — Arena spectator (prediction market)
**Goal:** non-participants watch + bet.
**Generates:** Claude (Dart).
**Steps**
1. Read the linked market via `nora-arena-api-market?battle_match_id=` (already
   deployed) and `arena_state` Realtime for the score.
2. Bottom sheet over the battle: pools (team_1/team_2), token balance
   (`nora-arena-api-token-balance`), place bet via the existing **`arena_back`** RPC.
**Done when:** a spectator watches a live battle read-only and places a bet that
appears in the pool; resolution notifies.

---

## Phase 6 — Platform, polish, launch
**Goal:** push, IAP, store readiness, web hand-off.
**Generates:** Claude (Dart + the one needed nora-platforms edge fn).
**Steps**
1. **FCM:** Firebase project; `firebase_messaging`; store token in
   `profiles.fcm_token_mobile` (migration 114 — already live).
2. **IAP:** RevenueCat products — token packs `tokens_starter|popular|pro|elite`
   (100/500/1200/2500 tokens) and chit packs `chit_pack_common` (5 common) /
   `chit_pack_rare` (1 rare + 2 common). On purchase, POST the user's Supabase
   session JWT to the **nora-platforms** edge function `mobile_iap_confirm`:
     `POST https://cceisywxwhgljdpisjrl.functions.supabase.co/mobile_iap_confirm`
     body `{ "product_id": "...", "purchase_token": "..." }`
     → `{ status: "credited"|"already_processed", tokens_credited, chits_credited }`
   ✅ **BACKEND ALREADY BUILT + DEPLOYED** (nora-platforms migration 115
   `mobile_iap_receipts` + the fn, 2026-06-18). Idempotent: `purchase_token` is the
   PK of `mobile_iap_receipts`, so a replay echoes the original grant and never
   double-credits; credits the SAME `token_transactions` ledger as web purchases.
   Defaults to **sim mode** (credits on trust, pre-launch); to validate against
   RevenueCat first, set nora-platforms secrets `MOBILE_IAP_MODE=live` +
   `REVENUECAT_API_KEY`. The backend half is DONE — only the Dart side remains here
   (RevenueCat SDK + calling the fn). NO backend work belongs in this repo.
3. **Web hand-off (do last, only after Phase 4 is solid):** in nora-platforms add
   `ArenaRedirectScreen`/`BattleRedirectScreen` and remove the web `/arena`
   `/battle` screens (doc6 §What to REMOVE).
4. CI: GitHub Actions — `flutter analyze`+`test` on PR; on `v*` tag build
   `.ipa`/`.aab` → TestFlight + Play Internal.
**Done when:** push works, a sandbox IAP credits tokens, store builds upload.

---

## Tooling setup (do before Phase 3)
- Wire an **image-generation MCP** so an agent can generate sprites in-loop:
  copy `tooling/image-gen.mcp.json.example` → `.mcp.json`, fill the API key. Within
  Antigravity, Gemini image gen is built in — the MCP mainly lets Claude Code
  generate too. See `tooling/image-gen.mcp.json.example` for provider options.
- Keep all asset prompts/specs in `pipeline/` so generations are reproducible.
