# N.O.R.A. Arena — Build & Game Architecture Recommendation

Audience: the team deciding how to build the Pokémon-style battler. This is the
recommendation Claude is building toward in this scaffold.

## TL;DR verdict

**Flutter + Flame + Rive + Lottie, rendered with Impeller, written in Dart with
plain Riverpod (no codegen).** This is the highest-ceiling path *inside the
Flutter framework* and keeps 100% compatibility with the shared Supabase backend
and the `nora-platforms` data models. No engine rewrite, one team, one language.

| Layer | Tool | Why |
|---|---|---|
| Game loop / world | **Flame** | The de-facto Flutter 2D engine: component tree, camera, parallax, collisions, sprite batching. |
| Characters | **Rive** | Vector **state-machine** rigs. Battle states (idle / attack / defend / hit / ko / victory) map 1:1 to a Rive state machine. Crisp at any DPI, tiny files, 60fps, and **runtime-parameterizable from stats**. One rig per archetype is reused for every imported creator. |
| Ability / chit FX | **Lottie** | One-shot overlay effects; designer-authored, no code. |
| HUD (health/AP/momentum) | **Flutter widgets** via Flame `overlays` | Stay razor-sharp at any DPI; use the app theme. |
| Rendering | **Impeller** | Precompiled shaders → no first-run jank. Default on iOS; enable on Android. Bundle shaders in CI. |
| State | **flutter_riverpod** (+ `flame_riverpod`) | Same as web. **No codegen / no `@riverpod` / no build_runner** (CLAUDE.md). |

### Why not pure sprite sheets?
Sprite sheets are fine, but Rive wins for *this* game because (a) we can't
pre-draw a unique sheet for every real person someone licenses, and (b) Rive
inputs let us drive one rig from stats (size, aura, speed) at runtime. Keep sprite
sheets as the fallback / for simple FX where Rive is overkill.

### Why not Unity now?
doc6 V2: Unity only when you need 3D, real-time lighting, or physics. It costs the
shared-Dart-codebase advantage. **Keep the data layer engine-agnostic** (Supabase
REST/Realtime, the licensing API) so a future V2 is a *frontend swap, not a
backend rebuild.* Build V1 in Flutter.

### Language
**Dart.** It lets us share models verbatim with `nora-platforms/lib/models`, reuse
the Supabase + Riverpod patterns the team already knows, and ship iOS + Android
from one codebase. There is no UX upside to a second language for V1.

---

## The likeness → character pipeline (the critical compatibility piece)

This is the whole point of the cross-platform play: a buyer licenses a real
person's **likeness + image** on noraplatforms.com, and that person becomes a
playable fighter here. The hard constraint: **you cannot hand-author a bespoke
sprite for an arbitrary real person.** The solution is **archetype rig +
personalization overlay**:

```
Buy likeness on web  ──►  LKN-2026-XXXX (license)
        │
        ▼  user taps "Sync" in Arena
1. VERIFY ownership      → lkn-verify (signed, rate-limited, entertainment_game)
                           = authoritative "do they own a game-use license?"
2. IMPORT display assets → lkn_public_registry (public): portrait image + name +
                           category  ── and ──  creator_stat_sheets: the 6 stats
3. REPRESENT in battle   → the matching ARCHETYPE Rive rig, personalized with:
        • the imported PORTRAIT in the HUD card, VS-intro, and KO card
        • STAT-DRIVEN modifiers (Power→scale, Charisma→golden aura,
          Influence→crowd SFX) per doc6
        • name plate = their display name
```

So the licensed person is **visibly present** (their real portrait + name + their
actual platform stats drive the fighter) without an impossible per-person art
pipeline. `LicenseSyncService` in this scaffold implements steps 1–2 and produces
an `UnlockedCharacter`; the Flame layer consumes it in step 3.

**Authority split (important):** the **licensing REST API is the source of truth**
for whether a character may be used (signed response, Hard Rules 31/32). The
shared Supabase tables are used only for *display assets* (portrait, stats). Never
unlock a character on registry data alone — always gate on a verified active
license. The app re-verifies before battle start.

**V2 enhancement (noted, out of scope now):** a server-side step that stylizes the
licensed portrait into a bespoke pixel/sprite portrait via image-gen, cached per
license. Until then, portrait-on-archetype-rig is the shippable answer.

---

## Build / CI / compatibility checklist
- **Targets:** iOS + Android, AOT release builds, Impeller on.
- **CI (GitHub Actions):** `flutter analyze` + `flutter test` on PR; on `v*` tag
  build `.ipa` + `.aab` → TestFlight + Play Internal.
- **Auth:** same Supabase project; the user's web session JWT is valid here.
- **Betting:** reuse the existing `arena_back` RPC + `markets`/`arena_state`
  Realtime — no new backend.
- **IAP:** RevenueCat → `mobile_iap_confirm` edge function (must be idempotent,
  `ON CONFLICT DO NOTHING`, same `token_transactions` table as web).
- **Models:** every copied model carries a `// SHARED MODEL` comment; keep in sync
  with nora-platforms (or extract a `nora_shared` package in V2).

---

# Addendum A — AI-only assets & the C/C++ question

**Hard constraint:** every asset and every line of code on this project is produced
by AI agents — **Claude** (code, Lottie, shaders) and **Google Antigravity / Gemini
image** (characters, sprites, backgrounds). There is no human art team. This
constraint *decides* the engine debate.

## Why not C/C++ (or Unity) for the game

"Build it in C/C++" really means a native engine (Unreal/Cocos2d-x/custom) or
Unity (C#). For *this* product it's the wrong trade:

1. **The genre doesn't need it.** A turn-based 2D battler's "wow" comes from good
   art + skeletal/frame animation + game-juice (screen shake, hit-pause,
   particles) — all reachable at 60fps in Flame + Impeller.
2. **No first-class Supabase SDK in C++.** The game is driven by Supabase Realtime
   (`battle_events`) + shared Auth. Flutter gets `supabase_flutter` free; raw C++
   means hand-rolling websockets/JWT/RLS — i.e. rebuilding the exact "action
   translation" layer that must be rock-solid.
3. **It throws away Dart reuse** (models, import flow, wallet, markets).
4. **AI code-gen reliability.** Claude and Antigravity are both excellent at
   Dart/Flutter; pushing them to a custom C++ engine *lowers* output quality and
   slows the loop — the opposite of the goal.
5. **Asset formats.** AI produces **PNG sprites, Lottie JSON, GLSL shaders** best —
   all natively consumed by Flame. A native engine wouldn't make AI-generated 2D
   art look better.

So: **stay Flutter + Flame.** The only legitimate escape hatch is graphics-ceiling,
handled below — and even then the answer is *embed Unity for the battle scene*, not
rewrite in C++.

## Revision to the engine table: Rive → AI-friendly formats

Under AI-only assets, prefer formats agents can author:
- **Characters:** AI-generated **sprite sheets** (Gemini character-consistency from
  the licensed portrait — see `pipeline/LIKENESS_TO_SPRITES.md`). Replaces the
  earlier Rive-first plan, because `.riv` is binary and not AI-authorable.
- **Effects / UI:** **Lottie** (JSON) — Claude writes/edits it directly.
- **Polish:** GLSL shaders + procedural juice — Claude writes it.

## The differentiator: per-creator characters from licensed likeness

Gemini's image model ("Nano Banana") is best-in-class at **character consistency**.
Feed it the licensed portrait and it generates the *same person* across battle
states (idle/attack/hit/ko…). That means when a user licenses a real person, we
**auto-generate an animated game character of that person** — no artist. This is
strictly better UX than static, generic sprite sheets, and it ties the licensing
thesis directly to gameplay. Full recipe + compliance gate in
`pipeline/LIKENESS_TO_SPRITES.md`.

## If the 2D ceiling ever isn't enough (Path B, deferred)

Keep menus/licensing/import/wallet/markets in Flutter, render **only the battle
scene** in **Unity embedded as a library (UaaL)**. Flutter ↔ engine talk over a
thin protocol — this is literally "the game renders outside Flutter, actions get
translated":

```
Flutter → engine:  { battle_state, roster[], event:"attack", actor, target, damage }
engine → Flutter:  { player_action:"use_move", move_id } | { animation_complete }
```

The scaffold's display-only, server-authoritative design makes this a clean swap:
only the renderer changes; import/verify/wallet/markets code is untouched. Prefer
Unity (C#) over raw C++ here for the realtime/asset ecosystem and hiring. **Do not
pre-build this** — only adopt it if a Flame+sprite prototype visibly misses the
quality bar.

## Decision rule
1. Prototype the battle scene in Flame with AI-generated sprites + Lottie + juice.
2. Meets the bar → ship all-Flutter.
3. Visibly short → embed Unity (UaaL) for the battle only.
4. Pure C/C++ only if the game later goes real-time/3D or targets consoles.
