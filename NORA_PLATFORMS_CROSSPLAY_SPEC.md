# NORA Crossplay Spec — web ↔ NORA Arena (mobile)

> **Status: LIVE (backend + web) as of 2026-07-12.** Migrations 159–160 applied; the
> full loop is proven E2E on prod by `tools/battle/smoke_crossplay.ts` (queue pair →
> RLS hand privacy → real `ccg_submit_turn` → forfeit → settle). The web client ships
> the whole player journey; the Unity client wires into the SAME contract below.
> Cross-repo: this doc governs both repos; the mobile repo consumes it read-only
> (its Hard Rules 2/3 — no schema/edge-fn changes there).

## 1. Principle

One backend, one game, any screen. A match is **created once in `ccg_matches`** and
played by two seats that may be on different platforms — web (Flutter, this repo) or
NORA Arena (Unity, `arunernorainvestments-cmd/nora-arena`). The server resolves
everything (`ccg_submit_turn`, mig 129); every client is **display-only** and renders
the same ordered `ccg_events` stream. Crossplay therefore needs no netcode — only
this shared contract.

## 2. The shared contract (all in this repo's Supabase project)

### 2.1 Matchmaking queue (mig 159)

| RPC (authenticated) | Returns |
|---|---|
| `ccg_queue_join(p_deck_id, p_platform)` | `{status: matched, match_id, seat:2}` · `{status: queued, queue_size}` · `{status: in_match, match_id}` · `{status: deck_illegal, errors[]}` |
| `ccg_queue_poll()` | heartbeat + `{status: matched, match_id, seat:1}` · `{status: queued, position, queue_size, queued_for_seconds}` · `{status: in_match}` · `{status: idle}` |
| `ccg_queue_leave()` | `{status: left}` · `{status: matched, match_id}` (opponent locked the pair first — go play) |
| `ccg_forfeit_match(p_match_id)` | `{status: finished, winner_seat}` — concede; wager/market settle triggers fire normally |

Mechanics every client must respect:
- `p_platform` ∈ `web | arena` — **telemetry only, never affects pairing**. One pool.
- Pairing is first-come-first-served on `enqueued_at`; the earlier-queued player is
  **seat 1** (and takes the turn-1 draw), the joiner is seat 2.
- The deck is **revalidated live** at join (`deck_validate`) — `is_legal` may be stale.
- **Heartbeat**: entries with no `ccg_queue_poll()` for **90 s** are swept. Poll every
  ~5 s while searching.
- **Match-found signal**, fast path: subscribe (Realtime) to your own `ccg_queue` row
  (RLS returns only yours) — the UPDATE carries `matched_match_id`. Fallback: poll.
  After acting on it, call `ccg_queue_poll()` once — it deletes the consumed row.
- A user already seated in a live match can't queue; they get `in_match` + the id
  (drive a "resume" UI from this).

### 2.2 Playing (mig 129, unchanged)

`ccg_submit_turn(p_match_id, p_actions)` — the WHOLE turn as one ordered JSONB list:
`[{type: summon, card_id, position?, target_card_id?} | {type: cast, card_id,
target_card_id?} | {type: activate, card_id, target_card_id?} | {type: attack,
attacker_card_id, target_card_id?} | {type: end}]`. Clients **stage locally, submit
once**; any illegal action rejects (and rolls back) the entire turn — nothing applies,
re-stage and resubmit. Server enforces seat/turn/aura/field-cap/taunt/vibe/sickness.

### 2.3 Reading state (RLS visibility matrix — migs 126 + 147)

| Table | Participant | Spectator (any authenticated) |
|---|---|---|
| `ccg_matches` | ✓ | ✓ (live list = `status='active' AND is_test=false`) |
| `ccg_match_players` | ✓ | ✓ (life/aura per seat) |
| `ccg_events` | ✓ | ✓ (ordered by `turn_number, sequence_in_turn`) |
| `ccg_match_cards` | own hand/deck + all field/graveyard | **field/graveyard only** — hands/decks never |
| `ccg_queue` | own row only | — |

Realtime publication carries `ccg_matches`, `ccg_match_players`, `ccg_match_cards`,
`ccg_events`, `match_vibe`, `ccg_queue` — subscribe with `match_id=eq.<id>` filters.

> ⚠️ **The v3 event table is `ccg_events`, NOT `battle_events`.** `battle_events`
> belongs to the retired 1v1 fighter (walled off, HR 26–28). The Unity
> `BattleSubscriberService` currently subscribes to `battle_events` and must be
> repointed (§5). Column shape is compatible (`turn_number`, `sequence_in_turn`,
> `event_type`, `payload`, plus `life_p1_after/life_p2_after` reconciliation).

### 2.4 Locked engine internals (mig 159)

`ccg_create_match`, `ccg_emit_event`, `ccg_instantiate_card`, draw/damage/kill/
check-win/fusion/settle/usd helpers are **no longer client-callable** (they were, by
default-EXECUTE — a forged-event / arbitrary-match hole). The ONLY client verbs are:
queue RPCs, `ccg_submit_turn`, `ccg_forfeit_match`, `ccg_place_bet`,
`ccg_record_vibe_signal`, `ccg_get_match_vibe`, `ccg_match_is_monetized`, deck RPCs.

## 3. Match lifecycle

```
ccg_queue_join ──pair──▶ ccg_create_match (decks snapshot, hands dealt, turn 1 begins)
      │                        │
      ▼                        ▼ per turn: active seat → ccg_submit_turn(actions)
 realtime/poll            ccg_events stream (both clients replay identically)
                               │
              Life ≤ 0 ─▶ finished (winner_seat)   ccg_forfeit_match ─▶ finished
                               │
                     AFTER UPDATE triggers: wager transfer (142), market settle (134)
```

Deck rules (mig 118): exactly 20 cards, ≤2 copies per chit, all owned + active.
Clients create `decks` rows directly (RLS-own) and write lists ONLY through
`deck_set_chits` (validates + stamps legality).

## 4. Web implementation (this repo — SHIPPED)

- `/battle` hub: **Find a match** CTA · resume-match banner (`myActiveCcgMatchProvider`)
  · mint/collection/market shortcuts · live-match spectate list (realtime).
- `/battle/find`: deck picker (legality badges) + **Quick-build** (best-20 auto-deck via
  `deck_set_chits`) + empty-collection guidance → searching state (radar pulse, elapsed,
  queue size, cancel) → match found → play. Realtime + 5 s poll.
- `/battle/play/:matchId`: participant client — seat bars (life/aura), opponent/own
  field, own hand (RLS), action staging (summon/cast/attack/face-attack) with soft
  aura/field hints, whole-turn submit, forfeit, match-over overlay. Non-participants
  are redirected to spectate.
- `/battle/spectate/:matchId`: board + seats + vibe + ordered event feed (was already
  live, mig 147).
- Client code: `features/battle/providers/matchmaking_providers.dart` (service +
  providers), `find_match_screen.dart`, `battle_play_screen.dart`.

## 5. Unity implementation (nora-arena — TO WIRE, Phase 3)

The mobile repo changes NOTHING in the backend; it wires UI to the contract:

1. **`MatchmakingService.cs` (added under `Core/Services` — scaffold in place):**
   `JoinQueueAsync(deckId)` / `PollAsync()` / `LeaveAsync()` / `ForfeitAsync(matchId)`
   via supabase-csharp `Rpc(...)` with `p_platform: "arena"`.
2. **`MatchmakingUI.cs`**: replace `MockMatchmakingRoutine` with the service — join on
   mode select (deck from the Phase-2 deck-builder), poll every 5 s, cancel button →
   `LeaveAsync` (handle the late `matched` return!), matched → load the battle scene
   with `match_id`.
3. **`BattleSubscriberService.cs`**: repoint `battle_events` → **`ccg_events`** (same
   ordering keys). Model: add `payload`, `life_p1_after`, `life_p2_after`.
4. **Turn submission**: stage actions in the battle UI, submit once via
   `ccg_submit_turn` (shape in §2.2). Never compute outcomes on-device (their HR 9).
5. **Spectate**: same read matrix as web (§2.3) — the existing spectator scene should
   stream `ccg_matches`/`ccg_match_players`/`ccg_events` + field-zone `ccg_match_cards`.
6. **Wager matches** stay a separate entry (`ccg_create_wager_match` is service-only;
   surface TBD — see §7).

## 6. Cleanup executed with this spec (2026-07-12)

- **Web legacy 1v1 fighter client REMOVED**: `/battle/legacy` lobby (dev-only
  `battle_start_match_dev`), `/battle/matchmaking` (likeness-card queue, migs 098–101),
  `/battle/:matchId` Flame client, dead **"Animation test" buttons** (target route
  `/battle/test-match` never existed), Arena page's legacy Live-Battles section (its
  Watch button pointed at the removed screen), `flame` dependency. Legacy **backend**
  stays archived-not-dropped per CLAUDE.md (HR 26–28, RECONCILIATION R3); the /markets
  page's battle-market bet section is untouched.
- `battle_models.dart`/`battle_providers.dart` trimmed to the still-live likeness
  stat-sheet read (public profiles).
- **Engine bugs fixed en route**: mig 160 (`ccg_create_match` deck path never worked —
  int4→int2 resolution, sibling of mig 143's bug); mig 159 grants lockdown (§2.4).

## 7. Known gaps (queued, not blockers)

- **Turn timers / dead-match sweep**: an AFK opponent stalls a match forever. Wire a
  pg_cron abandon sweep (`status='abandoned'` refunds wagers by existing trigger) +
  client-side turn clock. Design decision: how long, and does a timeout forfeit or pass?
- **Skill/ELO pairing + formats**: queue is FIFO; the marketplace's tier bands could
  seed a rating later. Wager-mode queueing (chit stake, mig 142) needs its own consent UX.
- **Bots for empty queues** (pre-launch liquidity): pair with a house bot after N
  seconds — the dev-tooling bots are being removed pre-launch, so this needs a
  production-safe design.
- **Vibe surface on web play/spectate** exists (meter); hype-signal input
  (`ccg_record_vibe_signal`) has no web UI yet.
- **Monetized matches**: `battle_outcome` USD markets stay gated on G-MON + both-KYC
  (HR 35); the queue creates non-monetized matches only.
- **Mobile deep link**: `noraplatforms.com/battle/play/:id` should eventually deep-link
  into the Arena app when installed (RECONCILIATION item).
