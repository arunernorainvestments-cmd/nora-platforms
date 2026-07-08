# NORA Platforms

Flutter-web prediction-market + **"Moments" card-battler** platform, one wallet, plus two community
systems (Emergency Fund, Licensing Marketplace). Backend: Supabase (Postgres + RLS + Deno Edge
Functions). Pre-launch (target July 4 2026). Mobile client (Unity) lives in the separate
`nora-arena` repo and shares this backend.

## The doc contract — read the right one

Four canonical docs + a small active spec set. **If two docs disagree: CLAUDE.md wins.**

| Doc | Role | Read it when |
|---|---|---|
| **CLAUDE.md** | Canonical **rules** (40 Hard Rules), the game model, how to build safely | Before writing any code. Non-negotiable. |
| **PLAN.md** | Where we're going — active tracks, checklists, decision gates, the v3 P7 remainder | To pick up the next task. |
| **ARCHIVE.md** | Where we've been — dated build history, full schemas, formulas, infra, runbooks | When you need a schema, a formula, a runbook, or "when/why did X ship?" |
| **RECONCILIATION.md** | Cross-repo contract with the `nora-arena` (Unity) mobile app | Before touching anything mobile consumes. |

**Active specs** (the detailed *what* for in-flight work — status is tracked in PLAN.md):

| Spec | Governs | Status |
|---|---|---|
| `NORA_PLATFORMS_BUILD_SPEC_v3.md` | The v3 card-battler (canonical *what*) | P0–P6 shipped; P7 remainder in PLAN.md |
| `NORA_PLATFORMS_MARKETPLACE_SPEC.md` | Fixed-price chit marketplace M1–M4 | M1+M2 shipped; M3 next (PLAN Track C) |
| `Minting_Workflow.md` | Minting v2: device-clip upload, V2V middle, agnostic plates — **wins on conflict** with the two below | §1 shipped; §2–§4 = PLAN Track A |
| `NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md` | Consent/moderation stack, match-cut templates, wager mode | Governs where not superseded above |
| `NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md` | Anchor plates, §4 prompt grammar, Seedance/Segmind generation | Governs where not superseded above |
| `NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md` | Card-effect design principles (§1 identity matrix) | Governs Wave-2+ authoring |
| `NORA_INTERACTION_LAYER_SPEC.md` | Reactive effect depth (Waves 2–3) | PLAN Track B |

Retired/one-shot docs are deleted once their content is recorded in ARCHIVE.md (see its dated
"doc consolidation" entries); git history retains everything.

## First moves for a new agent

1. Read **CLAUDE.md** top to bottom.
2. Read PLAN.md "Status snapshot" + "Where we're going next" — the active tracks and what gates them.
3. For the task at hand, read its spec from the table above **in full** (Hard Rule 11).
4. Migrations apply **only** via `supabase db push` (never hand-run DDL). `flutter analyze` zero
   issues before every commit. Don't commit/push unless asked.
