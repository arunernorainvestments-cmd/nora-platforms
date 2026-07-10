# NORA Platforms — App Inventory (frontend ↔ backend coverage audit)
**Compiled: 2026-07-08 (post-marketplace-M3). This is a WORK QUEUE document, not a spec.**
**Nothing here is scheduled yet — pick items into PLAN.md when this work begins (post-M3, per founder).**

How this was compiled: desk audit of `flutter_app/lib/features/*` + `lib/core/router/app_router.dart`
against the deployed backend (migrations 001–156, edge functions, RLS models), cross-checked with
CLAUDE.md/PLAN.md/ARCHIVE.md status. **Not browser-verified** — before acting on any row, open the
surface and confirm (several "wired" rows have only ever been analyze/PostgREST-verified).

**Verdict legend:**
- ✅ **WIRED** — FE + BE built and connected; only config/creds/polish may remain.
- 🔌 **NEEDS-WIRING** — FE exists but talks to nothing / the wrong thing, or BE exists with no FE.
- ✏️ **NEEDS-EDIT** — wired but the surface needs UX/content/behavior changes before launch.
- 🗑️ **RETIRE** — dead or superseded FE code to delete (or archive) — most is P7-adjacent.
- 💤 **DORMANT** — deliberately kept but disabled/parked (do not delete, do not extend).

---

## 1. ✅ WIRED — built front end + back end

| Surface (routes) | Feature dir | Backend | Notes / residual gaps |
|---|---|---|---|
| Auth (`/login` `/signup` `/forgot-password`) + beta gate (`/pending-approval`) | `auth/` | Supabase Auth + `handle_new_user` + `is_approved` | — |
| Home (`/home`, `/dashboard`) + community cards | `home/` | spotlight, markets, ubi realtime (mig 098) | `spotlightCreatorsProvider` is known dead code (ARCHIVE A1 gap 3) — sweep with §4 |
| Prediction Markets (`/markets`, `/markets/:id`, `/mybets`) | `markets/` | markets/bets/token rails, resolve-markets | token lane only (HR33) — correct |
| Hot Topic (`/hot-topic`) + news (`/news`, `/news/:celebId`) | `hot_topic/`, `explore/` | celebs, weekly scoring, hot-topic-* fns | `celebs.image_url` NULL ×25 (PLAN polish); `celebrity_profile_screen.dart` lives under `explore/` but imports `hot_topic/` — move (ARCHIVE gap 4) |
| Wallet (`/wallet`) + Stripe checkout | `wallet/` | token_balances/transactions, create-checkout-session, stripe-webhook | chit_purchase/chit_sale labels added in M3 |
| Profile (`/profile`, `/u/:username`) | `profile/` | profiles, public_platform_connections, stat sheets, badges | avatar-from-platform polish open (PLAN) |
| Challenges + badges (`/challenges`) | `challenges/` | evaluate-challenges, user_badges/streaks | §6 economy will re-budget emissions (founder gate) |
| Likeness Cards marketplace (`/marketplace`, card/offering detail) | `marketplace/` | likeness_* tables + 4 likeness-* fns + legacy chit fns | Chits tab rides the LEGACY powerup lane (`user_battle_chits`) — see 💤 row §5 |
| Weekly polls (`/polls`, `/poll/:id`, embed) | `polls/` | weekly_polls + poll-vote (anti-abuse — never simplify) | goes 💤 DORMANT at v3 P7 — keep wired until then |
| Emergency Fund (`/emergency-fund` + contribute/request/my-requests/vote) | `emergency_fund/` | ubi_* + 6 ubi-* fns (sim mode) | live flip = shared Treasury rail decision |
| Licensing (`/licenses`, detail, buy, `/my-licenses`, `/partners`, `/license/:id`) | `licensing/` | lkn_* (migs 107–113) + 8 lkn-* fns | gateway route + lkn-generate-contract + key rotation open (PLAN) |
| KYC (`/verify-identity`) | `kyc/` | kyc-create-session (sim + Stripe Identity live path) | live needs KYC_MODE=live |
| Mint wizard (`/mint`) | `mint/` | moment-ingest → clip-attach → classify → cinematic-mint → finalize (migs 135–152) | E2E in SIM; §2–§4 real renders = PLAN Track A; not browser-verified since effects landed |
| Collection (`/collection`) | `collection/` | chit_ownership + moment_chits + (M3) listings merge | — |
| **Chit Market (`/market`)** — NEW M3 | `market/` | marketplace_* (migs 153–156) | token lane; USD founder-gated; not browser-verified yet |
| Battle hub + live CCG spectate (`/battle`, `/battle/spectate/:id`) | `battle/` (hub+spectate) | ccg_matches/players/cards/events (P3 engine) | display-only ✓; vibe display worth checking |
| Onboarding tour, launch countdown (`/`), waitlist (`/waitlist`, `/join`, `/w/:token`) | `onboarding/ launch/ waitlist/` | waitlist table, referral | launch rocket MP4 still owed by founder |
| Promotions banner/ticker (in shell) | `promotions/` | active_boosts, promotion_banners, apply-promotion | — |
| Search (`/search`) | `search/` | profiles/discovery queries | verify HR15 test-account filter (Slice 2 sweep) |
| Settings/support/FAQ/plan (`/plan` `/faq` `/support`) | `settings/`, `home/plan_screen` | static + config | — |

## 2. 🔌 NEEDS-WIRING — backend BUILT, **no frontend surface at all** (the reverse gap)

These are shipped, prod-applied systems with **zero Dart callers** (grep-verified 2026-07-08).
The game pivot means some belong to Unity (nora-arena), not web — noted per row.

| Backend (built) | What's missing | Owner surface |
|---|---|---|
| **Deck builder** — `decks`/`deck_chits`, `deck_set_chits`, `deck_validate` (mig 118) | No deck-builder UI anywhere. Without it no real (non-test) CCG match can be entered by a user. | Unity primarily; a minimal web deck-builder would unblock web testing + P7's deck-entry e2e |
| **Barter** — `chit_barter_create_offer/accept/cancel` (mig 119) | No trade UI (offer/accept handshake, KYC popup on licensed crossover) | Web (companion) or Unity — decide |
| **Premium chit packs** — `chit_packs`/`chit_pack_grant` on lkn rail (mig 120) | No pack storefront; purchase wiring was deferred to P5 anyway | Web licensing surface, post-G-MON |
| **Tier ascension** — `chit_ascension_refresh` (mig 136, ≤1/7d) | ✅ **Web SHIPPED 2026-07-10** — mig 157 (client lockdown + detail-returning refresh) + `chit-ascension` edge fn (live engagement re-read) + `/collection` check-for-tier-ups w/ celebration | Unity mirror remains |
| **Wager matches** — `ccg_create_wager_match` + escrow/settle (mig 142) | No wager UI (stake pick, resolution reveal) | Unity (per spec §7 contract) |
| **USD spectator bets** — `ccg_place_bet` + `battle_place_spectator_bet_usd` wrapper (migs 133/145) | Web spectate screen shows matches but has no bet sheet on the USD path | Unity is canonical (R3); web bet sheet optional |
| **`profiles.avatar_loadout`** (mig 145) | No web Dressing Room (by design — Unity owns it) | Unity ✓ (leave web alone) |
| **Fusion** — `fusion_rules` + resolver (migs 124/128) | Server-resolved; no client feedback surface | Unity (cutscene contract) |
| **Vibe meter** — `match_vibe` + tick (migs 130/131) | Confirm spectate screen actually renders vibe; no reaction-send UI (`ccg_record_vibe_signal`) | Web spectate (light) + Unity |

## 3. ✏️ NEEDS-EDIT — wired but needs work before launch

| Surface | What needs editing | Why |
|---|---|---|
| Battle spectate (`/battle/spectate/:id`) | Verify event replay covers the full Wave-1 effect vocabulary (migs 151/152 added kinds after the screen shipped); render vibe if absent | effect events may render as unknown/no-op rows |
| Mint wizard step 4 (Review) | Surface the server-selected effect + rules preview (PLAN Track B "Wave-1 polish") | user currently confirms a card without seeing its effect |
| Collection | ✅ Ascension entry point shipped 2026-07-10; "in a deck" indicators when deck builder exists | inventory currently read-only beyond M3 sell/delist |
| Hot Topic / explore | Move `celebrity_profile_screen.dart` into `hot_topic/`; seed `celebs.image_url` | ARCHIVE known gaps 1+4 |
| Home | Remove dead `spotlightCreatorsProvider` (stale `spotlight_scores`) | ARCHIVE known gap 3 |
| Wallet | Hot Topic simple-bet payout display parity (equal-split vs proportional — ARCHIVE gap 5) if product wants it changed | consistency |
| All discovery/ranking providers | **Slice 2 sweep**: verify `is_market_maker`/`is_test_account`/`pending_opt_out` filters everywhere (HR15/22) | test accounts must never leak |
| Everything sim-flagged | Flip-readiness pass when creds land (TikTok prod, IG, Segmind, MODERATION_MODE) — copy that says "coming soon"/sim placeholders needs live-state variants | PLAN Track A flips |

## 4. 🗑️ RETIRE — frontend that should be deleted or archived

> Rule of thumb: client code can be DELETED (it's in git); **schemas** are archived-not-dropped (P7).
> Items marked ⏸ are gated on the nora-arena mobile cutover (RECONCILIATION R3) — do not remove early.

| FE code | State | Action |
|---|---|---|
| `features/campaigns/` (12 files, ~4k lines) | Routes already redirect `/campaigns*` → `/plan`; screens unreachable; backend archived (mig 089) | DELETE the feature dir + its router imports. Zero user impact. |
| `features/discover/` (2 files) + `features/notifications/` (1 file) | **Zero importers, not routed** — dead code | DELETE |
| `features/arena/` screens (`/arena`, `/arena/:matchId` — legacy Back/Trigger Arena) | Legacy in-memory Arena; superseded by v3; walled off by integrity triggers | ⏸ RETIRE with P7 dev-tooling removal (arena bot/test-match crons feed it today). Remove routes + dir together. |
| `features/battle/` legacy screens: `battle_lobby_screen` (`/battle/legacy`), `battle_match_screen` (`/battle/:matchId`, placeholder/test-match), `battle_matchmaking_screen` (`/battle/matchmaking`) | Drive the RETIRED 1v1 `battle_*` engine (create/join/enqueue) | ⏸ RETIRE at P7 7.2 (legacy engine archival). Keep hub + spectate (current). |
| Likeness "Chits" tab in `/marketplace` + `chit-marketplace-{buy,list}` edge fns | Legacy powerup lane (HR27), dormant asset class | 💤 keep dormant per Hard Rule 27 — do NOT extend; hide the tab at launch if powerups stay dormant |
| `features/polls/` (+ home Poll-Leaders strip) | Live now; v3 P7 puts weekly polls/multipliers DORMANT | 💤 at P7: hide entry points, keep code + schema |
| Launch countdown special-casing on `/` | Correct until launch day | post-launch: `/` becomes home; sweep then |

## 5. 💤 DORMANT / PARKED (do not delete, do not extend)

- Legacy powerup Battle Chits (`battle_chit_definitions`/`user_battle_chits` + marketplace Chits tab) — HR27.
- Weekly polls / stat multipliers — dormant at P7; stat sheets stay (cosmetic in CCG).
- USD marketplace lane — built (M2), founder-gated (`marketplace_usd_lane`).
- G-CARDVAL card-value accrual — parked pending counsel (PLAN).
- Legacy `battle_spectator_bets` path — frozen until mobile R3 cutover.

## 6. Sequencing suggestion (when this queue opens)

1. **Zero-risk deletions**: `campaigns/`, `discover/`, `notifications/`, dead providers (§4 rows 1–2, §3 home row). One PR, analyze-clean.
2. **Web deck-builder (minimal)** — unblocks P7's deck-entry e2e and makes the CCG testable end-to-end from the web (§2 row 1).
3. **Spectate vocabulary + vibe render check** (§3 row 1) — cheap, protects launch demos.
4. **Ascension button + mint Review effect preview** (§2/§3) — the two user-facing loops already paid for server-side.
5. Everything ⏸ waits for its gate (P7 archival / mobile cutover / founder flips).

---
*Update this file as rows close; move completed rows into ARCHIVE.md's dated entries rather than deleting them here silently.*
