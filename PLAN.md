# NORA Platforms — PLAN.md
# Where we're going. Last updated: 2026-06-27.
# Rules for HOW to build any of this live in CLAUDE.md ("Building future work safely").
# Full specs / schemas / history for anything referenced here live in ARCHIVE.md.

---

## Status snapshot (where we are, 2026-06-27)

- **Live & built:** Markets, Arena (Battle-spectator market surface + walled-off legacy 1v1),
  Battle (Phases A–C + matchmaking), Hot Topic, Likeness Cards + stat sheets + card/chit
  marketplaces + weekly polls, celebrity integration, match-revenue distribution, KYC flow,
  Emergency Fund (sim mode), Licensing Marketplace (backend + Flutter screens merged).
- **Migration ledger:** remote DB at 115. 080–106 = redesign Docs 1–4 + integrity/chit/KYC.
  107–113 = Licensing. 114 = `profiles.fcm_token_mobile`. 115 = `mobile_iap_receipts`
  (on an UNMERGED branch — see Mobile below).
- **`flutter analyze`:** clean as of the last redesign session.
- Anything below is NOT built (or only partially). Each item lists its blocking work.

---

## Next task (chosen): Battle bot-fill for solo testing

Matchmaking (1v1/2v2/3v3) is shipped, but a real match needs N human queuers
(1v1=2, 2v2=4, 3v3=6). Add bot-fill so a solo player can exercise a full match loop
without N browser sessions.
- Add a server-side path that tops up a partially-filled queue with bot participants
  (reuse the seeded test accounts / `is_test_account` creators; Hard Rule 15 keeps them
  out of rankings/discovery).
- Bots must field eligible characters and submit turns (mirror `dev-bot-backer` /
  `auto-select for non-submitters` patterns already in `process_battle_turn`).
- Gate behind `ALLOW_DEV_TOOLS` and remove in the pre-launch cleanup.

---

## Battle Phase D
- Map affinity multiplier: wire `battle_maps.affinity_archetypes` → 1.15× `map_multiplier`
  (currently a 1.0 stub in `process_battle_turn` and `battle_events.map_multiplier`).
- Balance tuning: type chart + speed stats are data-driven — rebalance via SQL UPDATE only.
- Wire `battle_match_telemetry.status_effects_applied` (computed locally but never written).
- Confirm SpriteMaster JSON matches Flame `SpriteAnimationData` schema before the art pipeline runs.

## Battle Chits — remaining (framework built, see ARCHIVE §Battle Chits)
- [ ] `aura` on charisma/influence — those stats aren't in the damage formula yet; multiplier is
      future-proofing only. Wire when stat coverage expands.
- [ ] Live combat screen — `battle_match_screen.dart` is still a `test-match` placeholder.
      ChitSheet inventory + target pickers are wired but only call the RPC in a real match.
- [ ] Acquisition flows — challenge/pack/gift are scaffold-only; only `match_rng` drop is live.
- [ ] Bench/target UX — wire `wild_card`/`disruption` pickers into the live combat menu.
- (Done already: `counter` + `type_override` hooks, true `damage_shield` absorb, identity_hash population.)

## Licensing Marketplace (Doc 5) — remaining
- [ ] **Gateway routing**: point `GET api.noraplatforms.com/v1/verify` at the deployed `lkn-verify`
      (Cloudflare route or Vercel rewrite → `…functions.supabase.co/lkn-verify`). This unblocks the
      mobile License Sync test. See the deploy runbook in ARCHIVE.
- [ ] **`lkn-generate-contract`**: needs the attorney-seeded `lkn_contract_clauses` table (not yet
      created). Do NOT fabricate legal language (Hard Rule 30). Deferred until clause library exists.
- [ ] **Signing-key rotation**: the current `NORA_SIGNING_PRIVATE_KEY` works but is known-compromised
      (generated in a Codespace). Regenerate on a local secure machine, update the secret + the public
      `.well-known/nora-public-key.pem`, before live launch.
- [ ] Featured/paid listing placement (post-launch).

## Arena/Battle Mobile App (Doc 6) — separate repo `arunernorainvestments-cmd/nora-arena`
Backend prep in THIS repo is done (migration 114 + four `nora-arena-api-*` wrappers + `mobile_iap_confirm`).
NOTE (2026-06-27): nora-arena now exists as its own GitHub repo and has **pivoted Flutter+Flame → Unity (C#)
+ Meshy 3D** (Phases 0–2 done, Phase 3 char pipeline in progress; backend unchanged). The stale `nora-arena/`
scaffold that used to live in this repo has been **removed** — the standalone repo is the single source of
truth. Cross-repo contract + open platform-side decisions: **RECONCILIATION.md** (mirrored as R1–R3 below).
Remaining is mostly in the mobile repo + external config:
- [ ] **Merge the `doc6-mobile-iap-confirm` branch** (commit ee5a782: `mobile_iap_confirm` fn +
      migration 115 `mobile_iap_receipts` idempotency ledger) — built + smoke-tested, not yet merged.
- [ ] Gateway routing for `api.noraplatforms.com/v1/verify` (shared blocker with Licensing above).
- [ ] In nora-arena: full Flame battle loop, character select from synced licenses, Arena spectator sheet.
- [ ] FCM push (battle invites, bet resolution) using `profiles.fcm_token_mobile`.
- [ ] RevenueCat IAP config (token packs / chit packs) → `mobile_iap_confirm`.
- [ ] Native iOS/Android shells, App Store / Play submissions, deep links from web.
- [ ] After mobile Battle/Arena is confirmed working: remove `/battle` + `/arena` game screens from this
      web repo and replace with "play on mobile" redirect screens (do NOT remove prematurely).

## nora-arena reconciliation — platform-side decisions (R1–R3)
Backend changes/decisions THIS repo owns, surfaced by the nora-arena review. Full detail + the consumed-
contract list are in **RECONCILIATION.md**; tracked here as actionable work. Don't let the standalone mobile
repo drift from these.
- [ ] **R1 — Archetype vocabulary (easy win).** Battle set is canonical; `profiles.category_1` /
      `get_eligible_characters` self-branch leak the non-battle set (healthcare/performer/educator/religion),
      yielding participants with no `battle_type_chart` row or abilities. Fix the `get_eligible_characters`
      self-branch to emit a battle archetype, **expose the resolved battle archetype in `lkn_public_registry`**
      (mobile import only sees `listing_category` today), and publish the official `category_1 → archetype`
      map so the client can delete its stopgap alias table.
- [ ] **R2 — License → battle eligibility (headline integration).** `check_battle_eligibility` (083) and
      `battle_enqueue` (101) gate on **likeness cards**, never on `lkn_agreements` licenses. So a user who
      bought a *license* (the mobile thesis) unlocks the character via `lkn-verify` but is **rejected at battle
      entry**. Decide + implement: (a) extend eligibility to accept an active `entertainment_game` license
      (join `lkn_agreements`); or (b) auto-issue a battle entitlement on license purchase; or (c) explicitly
      scope mobile to card-based fielding. Must land before the combatant/matchmaking flow ships on mobile.
- [ ] **R3 — Canonical spectator-bet path.** Mobile bets via the **legacy** `battle_place_spectator_bet` →
      `battle_spectator_bets`/`spectator_pool` (mig 062); the web redesign bets via `bets` rows on
      `battle_outcome` `markets` (mig 100, settled by `distribute_match_revenue`). Same match → two different
      pools, and the legacy path is flagged "cleanup candidate" (ARCHIVE §A1). Decide which is canonical for
      both clients. **Until decided, do NOT delete the legacy migration-062 `battle_spectator_bets` table /
      `battle_place_spectator_bet` RPC — mobile depends on it.**

## Slice 2 — test-account filter sweep
Systematic grep of `is_market_maker` / `is_test_account` across all Arena + Markets providers to
guarantee no test accounts leak into ranking/discovery (Hard Rule 15). Tracked separately (Rule 22).

## Pre-launch polish (before July 4 2026)
- [ ] Celebrity profile pictures — `celebs.image_url` is NULL for all 25 (UI falls back to initials).
- [ ] Onboarding walkthrough (4–5 slide PageView).
- [ ] Profile avatars from connected platform data.
- [ ] Arena Visual Pass 2/3.
- [ ] Marketing campaign + launch-day animation.
- [ ] Run the **pre-launch reset sequence** + remove all dev tooling (full steps in ARCHIVE).

## Known gaps & open suggestions (from the scoring/DB audit — full list in ARCHIVE)
- Hot Topic + Battle spectator payouts are equal-split; consider proportional (mirror Markets) for fairness.
- `spotlightCreatorsProvider` queries the stale `spotlight_scores` table — dead code, safe to remove.
- Duplicate migration `070_` prefix — leave as-is (already applied); note for a post-launch schema audit.
- `celebrity_profile_screen.dart` lives under `features/explore/` but imports `features/hot_topic/` —
  move for consistency.
- Legacy `battle_spectator_bets` / `spectator_pool` (migration 062) unused by the redesign — cleanup candidate.

---

## Long-horizon vision (post-launch, not scoped)
- **On-chain / NORA coin**: append-only ledgers (`likeness_card_transfers`, `lkn_agreements`, and the
  archived `campaigns_archived_ledger`) are designed to migrate to on-chain settlement. Integer-cents,
  no floats, every ownership change a new row. Full migration path + the original Campaigns royalty/
  Reg CF framework are preserved in ARCHIVE (superseded by Likeness Cards, but the crypto-settlement
  design intent carries forward to the cards/licensing ledgers).
- **Revenue data partnerships** (Spotify for Artists, YouTube Analytics, DistroKid/TuneCore) — the
  layered verification roadmap from the Campaigns framework (ARCHIVE) still informs licensing revenue-share.
- **Battle V2 (Unity)** — only if game revenue justifies it; the Supabase data layer is engine-agnostic so
  it would be a frontend swap, not a backend rebuild.
