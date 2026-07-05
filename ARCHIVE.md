# NORA Platforms — ARCHIVE.md
# Where we've been + full engineering reference. Last updated: 2026-07-01.
#
# CLAUDE.md is canonical. If this file disagrees with CLAUDE.md, CLAUDE.md wins.
# PLAN.md holds future (not-yet-built) work.
#
# ---------------------------------------------------------------------------
# 2026-07-01 — v3 PIVOT: "Moments" card-battler (supersedes the v2.x 1v1 fighter)
# ---------------------------------------------------------------------------
# The game pivoted from the 1v1 archetype-fighter to a collectible card-battler built on
# minted "moment chits" (spec: NORA_PLATFORMS_BUILD_SPEC_v3.md; phased tracker:
# NORA_PLATFORMS_v3_IMPLEMENTATION_PLAN.md, P0–P7). CLAUDE.md §"The game (v3)" is canonical.
# Deprecated by the pivot (RETAINED here, archived-not-dropped; v3 Phase 7 executes the archival):
#   • 1v1 turn-based Battle resolver + 6-player sprite Battle — engineering in §A3 below.
#   • D&D six-stat characters + per-archetype move-sets (`battle_abilities`) — §A3 (type chart/speed),
#     migrations 060–069/091.
#   • License-per-character battle eligibility (`check_battle_eligibility`, `battle_enqueue` card/license
#     gating, mig 082/083/101) — v3 eligibility is "own moment chits + a legal deck." (RECONCILIATION R2 retired.)
#   • Legacy powerup "Battle Chits" (`battle_chit_definitions`/`user_battle_chits`, mig 086/103/106) — dormant;
#     integrity spec in §A4. NOTE: the v3 "moment chit" asset is a DIFFERENT table (`moment_chits`, P1) — do not conflate.
#   • Legacy in-memory Arena (Back/Trigger, ArenaScore) + legacy `battle_spectator_bets` path (mig 062) — §A1/§A4;
#     kept until the mobile bet cutover ships (RECONCILIATION R3).
#   • Parody-celebrity avatars — celebrities now return as licensed premium chits (v3 P1).
#   • Weekly polls / stat multipliers → DORMANT (v3 P7); stat sheets survive but are cosmetic in the CCG.
# What survives & strengthens: prediction markets, the Vibe Meter (now also a gameplay unlock), the `lkn_*`
# licensing infra (now premium chit packs), the two-currency model, and the payout split (creator slice now
# routes to the moment-owners of chits played). Retired SQL stays in supabase/migrations/ + referenced §A3/§A4/§B.
#
# This file merges the former docs/: scoring-and-db-spec, infra, battle-spec,
# battle-chits-and-arena-integrity, ARENA-TESTING, redesign-ground-truth, ARCHIVE,
# campaigns-framework, lkn-deploy-runbook, stage_template_guide, pre-launch — plus the
# distilled redesign design docs (doc1–doc6). The full SQL for everything below 080
# lives in supabase/migrations/.

# ---------------------------------------------------------------------------
# 2026-07-02→05 — Cinematic engine + minting v2 + effect library (SHIPPED)
# ---------------------------------------------------------------------------
# The web-side minting pipeline is now END-TO-END and cards carry real, balanced effects.
# Governing specs: NORA_PLATFORMS_MINTING_MATCHCUT_SPEC.md + NORA_PLATFORMS_CINEMATIC_ENGINE_SPEC.md
# + Minting_Workflow.md (device-clip pivot, wins on conflict) + NORA_CHIT_EFFECT_DESIGN_FRAMEWORK.md
# + NORA_CHIT_EFFECT_LIBRARY_WAVE1.md + NORA_INTERACTION_LAYER_SPEC.md. Migration ledger 138–152.
#
# Cinematic engine v1 (migs 138–145, COMPLETE build-wise; generation middle superseded by Minting v2):
#   • C0 (138) registries: match_cut_templates (6 role-keyed), anchor_plates + prompt_templates (versioned),
#     cinematic cols on moment_chits/moments, battle-media bucket, _shared/segmind.ts (sim-first).
#   • C1 (139) 6 motion prompts + plate slots. C2 (140 + cinematic-mint fn) generation pipeline:
#     classify→template select→illustration→Seedance cutscene (plate bookends, seeded)→post-gen moderation
#     →cinematic_complete_mint (chit inactive until preview→finalize).
#   • M-P1 (141 + moment-ingest) OAuth-owned-post ingest (TikTok/IG/YT allowlist) + pre-gen vision moderation
#     (MODERATION_MODE sim|live, minor-safety absolute, fail-closed, moderation_escalations service-only).
#   • M-P4 (142–144 + swap flow) one active self-minted chit + swap-retire-in-tx; ccg_wager_escrow +
#     ccg_create_wager_match + settle-on-finish (attribution survives). 143/144 fixed latent P3/P1 bugs.
#   • M-P5 (145) profiles.avatar_loadout, ccg_matches.is_monetized (G-MON) + spectator read,
#     battle_place_spectator_bet_usd wrapper. C3 = RECONCILIATION §7 mirror kept current.
#
# Minting v2 §1 + agnostic plates (migs 146/147, commits 820a394/d4a0618): /mint "Create Your BattleChit"
#   (post verify → device-clip upload → ffmpeg.wasm trim 1–15s → mint-staging → moment-clip-attach
#   re-moderation + dHash similarity gate); BattleChit CTAs; /battle companion hub + live ccg spectating
#   (/battle/spectate/:id); two agnostic anchor plates wired (all 6 plate rows repointed + signed_off).
#   Cloud Run ffmpeg stitch worker (workers/stitch, service nora-stitch, us-east1) live for §4.
#
# Mint pipeline completion (2026-07-04→05, migs 148–150, PRs #5–#8): moment-classify fn (family/name/
#   subject/chit_type) → cinematic-mint (sim) → web Preview → chit_record/finalize_preview → /collection.
#   CardFace widget (core/widgets/card_face.dart) + rules_text/flavor_text/card_serial via write-time trigger
#   (mig 148, composed deterministically, reprints on ascension); {VIDEO_DESC} node (mig 149, moment-clip-attach
#   describes clip post-moderation → cinematic_generations.video_desc, feeds V2V core slot only, HR39);
#   mint Cancel/discard (mig 150 chit_discard_pending + mint-cancel fn — frees the self_mint_slot) + honest
#   sim-mode media placeholders (cinematic-mint returns mode/media_placeholder).
#
# Effect library Wave 1 (migs 151/152, PR #9): 7 additive effect_templates cols (cycle_key, grants_keywords,
#   complexity, min_tier_band, stat_lean, family_signature, magnitude_scales) + moments.selected_effect_*;
#   derive_chit_stats honors stat_lean (ATK/HP bias) + magnitude_scales (count effects tier-flat). 20 new
#   single-clause templates (10 families × 3, authored by cycle vs the §1 identity matrix; timing spread
#   16/10/3/1). moment-classify now SELECTS an effect from the family's authored candidates (sim hash / live
#   LLM allowlist) + persists on the moment; cinematic-mint reads it from the moment (never client — HR34).
#   compose_chit_rules then prints matching rules. Guardrail: AI selects an authored option; power = tier.
#
# Live config at hand-off: MINT_INGEST_MODE=live · MOMENT_CLASSIFY_MODE=sim · CINEMATIC_MODE=sim (unset) ·
#   MODERATION_MODE=sim (unset) · MINT_CLIP_MODE=sim · SEGMIND_API_KEY set · TikTok SANDBOX creds · IG none.
#   G-MON not yet confirmed. NEXT tracks live in PLAN.md ("Where we're going next").
#
# ===========================================================================
# TABLE OF CONTENTS
# ===========================================================================
# PART A — ACTIVE ENGINEERING REFERENCE (current operational truth)
#   A1. Scoring & Database Spec (all three games + celebrity + token economy + spotlight)
#   A2. Infrastructure — edge functions, pg_cron, routing
#   A3. Battle spec — turn flow, animation pipeline, asset naming, type chart, speed
#   A4. Battle Chits & Arena integrity spec
#   A5. Arena testing guide (dev tooling, diagnostics, known issues)
#   A6. Licensing Marketplace deploy runbook
#   A7. Battle stage background design guide
#   A8. Pre-launch reset sequence
# PART B — HISTORY & SUPERSEDED
#   B1. Redesign ground-truth — migration ledger for Docs 1–6 (what actually shipped)
#   B2. Dropped schema elements & design history
#   B3. Completed phase details (pre-redesign phases 1–8)
#   B4. Deprecated Campaigns royalty framework (full reference + on-chain/Reg CF vision)
#   B5. Redesign design-doc highlights (formulas/decisions not captured above)

# ===========================================================================
# PART A — ACTIVE ENGINEERING REFERENCE
# ===========================================================================

## A1. Scoring & Database Spec
# (former docs/scoring-and-db-spec.md — last content update 2026-05-23)

### Score Hierarchy (quick reference)

| Score | Table.Column | Written By | Consumer |
|---|---|---|---|
| Display Score | `platform_metrics.display_score` | `sync-platform-metrics` only | Markets resolution, Top Movers |
| Heat Score | `platform_metrics.heat_score` | `sync-platform-metrics` (boost sum) + Monday rollover reset | Arena HeatInfluence, UI heat badge |
| Momentum Score | `platform_metrics.momentum_score` | Arena tick on match resolution | Arena MomentumCarry, Monday decay |
| Arena Rating | `platform_metrics.arena_rating` | Arena tick on Round 2 resolution | Round 2 matchmaker pairing |
| ArenaScore | `arena_state.score_p1/p2` | `process_arena_tick()` tick loop | Live match display only — never persisted |
| Arena Weekly Points | `arena_weekly_points.points` | Arena tick on match resolution | Round 3 bracket seeding |
| Buzz Score | `celeb_weekly_scores.points` | `hot-topic-fetch-and-score` | Hot Topic leaderboard, bet resolution |
| Composite Display Score | `score_history.composite_score` | `sync-platform-metrics` (sum of all `platform_metrics.display_score` for user) | Markets snapshot, Top Movers delta |

`resolution_score` was dropped in migration 019. `display_score` is the single resolution metric for Markets.

### Game 1 — Markets

**Display Score per platform:**
- YouTube / Twitch: `followers×1 + live_viewers×10 + 24h_growth×5`
- X (Twitter): `followers×1 + live_viewers×10 + post_views×0.1 + post_reposts×3 + post_likes×1`
- Spotify: `followers×1 + savedTracks×3 + savedAlbums×3`

**Composite Display Score** = `SUM(display_score)` across all `platform_metrics` rows for a user.

**Resolution logic:** `current > opening` → `above` (yes wins); `current < opening` → `below` (no wins);
`current == opening` OR missing metrics → `refund`; no bets on winning side → `refund`; no bets at all → `voided`.

**Pool split (applied to the losing pool):** 90% → winning bettors (proportional); 5% → Market Maker
(`markets.opened_by`); 5% → platform (burned).

**Database tables:**
```
platform_connections (user_id, platform, access_token, platform_user_id)
       ↓ written by sync-platform-metrics
platform_metrics (user_id, platform, display_score, heat_score, momentum_score, arena_rating,
                  follower_count, live_viewer_count, previous_follower_count, fetched_at)
       ↓ summed into
score_history (user_id, composite_score, recorded_at)
markets (id, creator_id, opened_by, title, status, opening_resolution_score ← snapshot at INSERT,
         opening_heat_score, yes_pool, no_pool, end_at, resolution_result, resolved_at,
         platform_fee_collected, market_maker_fee_collected)
bets (id, user_id, market_id, position [yes|no], amount, status, settled_at)
token_balances (user_id, available_tokens, lifetime_spent)
token_transactions (user_id, type, amount, reference_id, description)
```

**Data flow:** OAuth connect → oauth-callback → sync-platform-metrics (user-scoped) upserts
platform_metrics + score_history. Opening market → trigger `snapshot_scores_on_market_open()` reads
SUM(display_score) → `opening_resolution_score` (stores composite bigint despite the name). pg_cron
syncs metrics every 5 min; resolve-markets every 15 min compares current SUM(display_score) to opening,
distributes, notifies, fires evaluate-challenges for bet_won/bet_lost.

**Passive effects hook:** resolve-markets reads `user_passive_effects.token_earn_rate` and applies a
bonus on top of payout (view populated by badge/challenge system, migrations 017–018).

### Game 2 — Arena (legacy in-memory game; see A4 for the redesigned market surface)

ArenaScore is ephemeral — lives only in `arena_state` during the match (Hard Rule 18).

**Each tick:**
```
score_p1 += (flow_rate_p1 × trigger_flow_mult_p1 × passive_flow_mult_p1 × opp_eff_p1)
           + (heat_influence_p1 × trigger_heat_mult_p1 × passive_heat_mult_p1) - suppression_p1
score_p1 = MAX(0, score_p1)
```
- `flow_rate` = cumulative Back value with diminishing returns: `Σ (value_i × 0.9^i)` per tick per side
- `heat_influence = heat_score × 0.5` (reads live `platform_metrics.heat_score`)
- Trigger stacking: `Base × (1 + ln(1 + N))`, Base = geometric mean of N trigger values
- Passive multiplication: product of passive modifier values
- OpponentEfficiency: multiplicative product of `opponent_efficiency` effects, floored at 0.40 (60% cap)
- Conditioning passive (Athlete): `+0.005 per 10s elapsed`, capped `+0.15`, re-injected each tick

**Ability effects** stored in `arena_state.active_effects` (JSONB): {effect_id, ability_id, target_player,
modifier [flow_rate_multiplier|heat_influence_multiplier|opponent_efficiency|suppression_level|momentum_window],
value, is_passive, expires_at (null for passives)}.

**Persistent columns:** `momentum_score` (winner +round_weight, loser ×0.95; Monday: spotlight winners→0,
others ×0.5), `arena_rating` (Elo K=32, Round 2 only), `arena_weekly_points` (R1 +1, R2 +2, R3 +5; wiped Monday).

**Tables:** arena_matches, arena_state, arena_events (back|trigger), arena_abilities, arena_weekly_points,
arena_spotlight_assignments (week_start PK, slot_1..5_user_id), arena_rollover_log, arena_round3_brackets,
arena_round3_results.

**Data flow:** pg_cron(5min) arena_matchmake → pairs eligible MM creators by category → arena_matches
(pre_match, +30s) + arena_state(zeros). RPC arena_back deducts tokens, inserts back event (processed=false),
updates total_pool. RPC arena_trigger deducts tokens, appends effect, inserts trigger event (processed=true).
process_arena_tick (target 3s): flip pre_match→live; per live match read heat_score, expire trigger effects,
inject Conditioning, compute stacking/passive mults, accumulate BaseFlow, compute scores, broadcast via
Realtime, mark backs processed; resolve past-5-min matches (winner, 90% pool→backers, 5%→creator, 5% burn).
arena_monday_rollover (Mon 00:00 UTC): top-5 R3 finalists → spotlight assignments; reset finalists heat=0
momentum=0; decay others momentum ×0.5; delete prior weekly points; log.

### Game 3 — Battle

`process_battle_turn(match_id)` runs every 3s via pg_cron; resolves one turn if all submissions in OR deadline passed.

**Per-turn sequence:** expire status effects (`expires_at_turn < current_turn`) → require both teams →
force_skip handling → auto-select for non-submitters (highest-damage affordable) → +5 AP regen →
Phase 1 voluntary swaps (speed order) → Phase 2 attacks in effective speed order
(`effective_speed = base_speed + speed_priority×1000`, ties RANDOM()).

**Damage:** `damage = base_damage × type_multiplier × map_multiplier` where type_multiplier from
`battle_type_chart` (default 1.0), map_multiplier=1.0 stub until Phase D. Redesign adds stat mods (see B5):
`× power_mod × wit_mod × (1 − resilience_reduction)`.

**Momentum:** +10/attack, +25 if type_multiplier≥1.5, cap 100, resets to 0 on ultimate (slot 5).
Ultimate requires momentum=100 AND ap≥ap_cost.

**Status effects:** speed_debuff, force_skip, save_state, double_damage, type_reversed, forced_ability, encore
(plus chit-mapped types — see A4).

**Tables:** battle_matches, battle_participants (slot 1=active, 2-3=bench; snap_* stat columns from redesign),
battle_turn_submissions (NOT in Realtime), battle_events (Realtime — drives animations via animation_key),
battle_participant_status_effects (Realtime), battle_abilities, battle_type_chart, battle_maps,
battle_spectator_bets (legacy), battle_animation_keys, battle_match_telemetry.

**Data flow:** RPCs battle_create_lobby / battle_join_lobby(code) / battle_start_match (random map) /
battle_forfeit (immediate resolve, no bet settlement). pg_cron(3s) process_all_battle_turns; (60s)
battle_check_presence (stale last_seen_at → is_automated=TRUE); (10min) cleanup_abandoned_battle_matches
(lobby→abandoned 30min, active→abandoned 2h); (30s) call_battle_tick_warmer (keep-alive, migration 071).

**Spectator pool split (legacy):** 90% → winning bettors (equal split), 10% → platform.

### Celebrity / Hot Topic Infrastructure

25 public celebs, independent of platform_metrics. Weekly lifecycle: Mon 11:00 UTC
`initialize_hot_topic_week()` seeds all at 1000; 11:00 + 22:00 UTC daily `hot-topic-fetch-and-score`;
Sat 00:00 UTC `hot-topic-resolve-week`.

**Per scoring run:** fetch 24h news (Currents API, name+aliases, ≤10 stories) → pass all 25 + stories to
Claude (claude-sonnet-4-6) one batch → tier+delta each: `Good 4 (+10)…Good 1 (+1)…Neutral (0)…Bad 1 (−1)…
Bad 4 (−10)` → volume multiplier (if story_volume>5 AND tier in Good4/Good3/Bad4/Bad3 → ×1.5 or ×1.2) →
`hot_topic_score_celeb()` (first run 1000+delta, then points += delta) → resolve pending simple bets →
recompute ranks.

**Bet types:** `simple` (up/down per scoring window; delta>0 up wins, <0 down wins, =0 all lose; 90% equal
to winners, 10% platform); `weekly` (person_of_week|top_riser|big_boo|top_5; resolves Sat 00:00 UTC).

**Tables:** celebs (25 rows, migration 057; image_url NULL — pre-launch gap; no FK to profiles),
celeb_weekly_scores (UNIQUE week_id+celeb_id), celeb_score_history (powers /news + sparkline),
weekly_bets (UNIQUE one simple per user+celeb+window+direction; one weekly per user+week+type).

**Flutter screens:** /hot-topic (hotTopicLeaderboardProvider), /home breaking-news (breakingNewsPreviewProvider),
/news (newsfeedProvider, 50 recent), /news/:celebId (celebProfileProvider), weekly bet (currentUserWeeklyBetProvider).

### Cross-Game Token Economy

`token_balances` = source of truth; `token_transactions` = immutable ledger. Valid types:
signup_bonus, bet_placed, bet_won, bet_lost, refund, promoted, referral_bonus, purchase, purchased,
challenge_reward, passive_bonus, arena_back, arena_trigger, arena_win — plus redesign types (migration 087):
card_purchase, card_sale, match_active_reward, match_creator_reward, match_passive_reward, chit_earn,
chit_purchase, chit_sale, poll_boost_applied. `increment_token_balance(user_id, amount)` is the single
write path; called from SECURITY DEFINER functions only (a BIGINT overload exists, migration 104).

### Spotlight Architecture

Home Dual Spotlight from `compute-spotlight` (dualSpotlightProvider). **Arena Champions (5):** source
`arena_spotlight_assignments` for current week_start, locked Monday by arena_monday_rollover — redesign
sources this from cumulative Battle wins this week (not the old Round-3 bracket). **Top Movers (5):**
trailing 7-day composite Display Score growth from score_history; filters is_market_maker/pending_opt_out/
is_test_account. Legacy `spotlight_scores` table no longer updated; `spotlightCreatorsProvider` is dead code.

### Known gaps (engineering audit)
1. `celebs.image_url` all NULL — falls back to initials; seed before launch.
2. Duplicate `070_` migration prefix — both applied; leave as-is, flag for post-launch audit.
3. `spotlightCreatorsProvider` dead code (stale spotlight_scores) — safe to remove.
4. `celebrity_profile_screen.dart` under features/explore/ but imports features/hot_topic/ — move.
5. Hot Topic simple-bet payout is equal-split, not proportional — consider mirroring Markets.
6. `battle_match_telemetry.status_effects_applied` computed locally but never written — wire in Phase D.
7. Map affinity multiplier is a 1.0 stub until Phase D.
8. arena/battle tick-warmer cron needs `ALTER DATABASE postgres SET app.service_role_key TO '<key>'`.

---

## A2. Infrastructure — Edge Functions, pg_cron, Routing
# (former docs/infra.md)

### Edge Functions (all deployed --no-verify-jwt unless noted)
**Markets & Core:** oauth-initiate | oauth-callback | disconnect-platform | sync-platform-metrics (single fn,
never split — also calls calculate_stat_sheets at the end) | resolve-markets | apply-promotion |
evaluate-challenges | compute-spotlight ({champions, top_movers}) | create-checkout-session | stripe-webhook
(also handles identity.verification_session.verified → identity_hash).
**Arena:** arena-matchmaker | arena-monday-rollover | arena-tick-warmer (30s) | arena-dev-force-match |
arena-dev-simulator | arena-dev-reset (ALLOW_DEV_TOOLS gated).
**Hot Topic:** hot-topic-fetch-and-score | hot-topic-reset-week | hot-topic-resolve-week | hot-topic-place-bet.
**Battle:** battle-tick-warmer (30s). process_battle_turn() is PL/pgSQL via pg_cron — not an edge function.
**Likeness & marketplace:** likeness-create-offering | likeness-purchase-card | likeness-list-card |
likeness-buy-listed-card | celebrity-integration-seed (admin, x-admin-key) | chit-marketplace-list |
chit-marketplace-buy.
**Polls:** poll-vote (public; do NOT simplify its anti-abuse — IP/device rate limits).
**KYC:** kyc-create-session (sim: kyc_simulate_approve; live: Stripe Identity, KYC_MODE=live).
**Emergency Fund (ubi_):** ubi-contribute (public) | ubi-submit-request | ubi-upload-document |
ubi-ai-evaluate (service role) | ubi-assemble-voting-panel (service role) | ubi-disburse (service role).
(ubi-cast-vote is an RPC, not an edge fn.)
**Licensing (lkn-):** lkn-verify (API-key auth) | lkn-register-api-key | lkn-partner-apply |
lkn-register-licensor | lkn-create-listing | lkn-submit-template | lkn-purchase-license |
lkn-revoke-license | lkn-generate-contract (NOT yet built — needs clause library).
**Mobile (nora-arena-api-):** profile | spotlight (proxies compute-spotlight) | market | token-balance.
Plus mobile_iap_confirm (on unmerged branch).

### pg_cron Jobs
main-character-check (hourly) | arena-matchmaker (5min) | process_arena_tick (3s) | arena-tick-warmer (30s) |
arena-monday-rollover (Mon 00:00 UTC) | hot-topic-morning (11:00 UTC) | hot-topic-evening (22:00 UTC) |
hot-topic-weekly-reset (Mon 11:00 UTC) | hot-topic-resolve (Sat 00:00 UTC) | battle-turn-processor (3s) |
battle-cleanup (10min) | battle-presence-check (60s) | battle-tick-warmer (30s) | create-weekly-poll
(Mon 00:05 UTC) | close-weekly-poll (Sun 23:59 UTC) | lkn-api-daily-reset (00:00 UTC) | ubi-vote-deadline-check
(30min) | ubi-inactive-voter-check (hourly) | sync-platform-metrics (null-named, jobid 9, 5min).
NOTE: tick-warmers need `ALTER DATABASE postgres SET app.service_role_key TO '<key>'`.

### Routing
/ LaunchScreen (countdown + waitlist) · /w/:token referral · /home (Shell) · /markets · /markets/:id ·
/mybets · /profile · /wallet · /dashboard · /challenges (auth) · /news · /news/:celebId · /hot-topic ·
/arena · /arena/:matchId (auth) · /battle · /battle/:matchId · /battle/matchmaking (auth) · /u/:username
(public) · /marketplace · /marketplace/card/:cardId · /marketplace/offering/:offeringId · /poll/:pollId ·
/poll/:pollId/embed (public) · /emergency-fund (+ /contribute, /request, /my-requests, /vote/:id) ·
/licenses · /licenses/:listingId (+ /buy/:tierId) · /my-licenses · /create-listing · /partners ·
/license/:licenseId (public) · /verify-identity (auth) · /pending-approval.

---

## A3. Battle Spec — Engineering
# (former docs/battle-spec.md — Phases A+B complete, C in progress, D queued)

### Turn Flow
1. Lobby created (battle_create_lobby) — 6-char code shared out of band
2. Others join (battle_join_lobby) — up to 3 per team (format 1v1/2v2/3v3)
3. Host starts (battle_start_match) — random map; snapshots stats; auto-opens market
4. 30s submission window — all submit simultaneously
5. process_battle_turn() every 3s via pg_cron
6. Resolution: voluntary swaps first, then attacks in speed order
7. Status effects applied/expired each turn
8. KO → forced swap to next bench character
9. All fainted = match resolved, spectator bets/market settled
10. Forfeit any time via battle_forfeit

### Animation Architecture (Phase C)
- **Characters** — Flame sprite sheets. Pipeline: Grok Imagine (stills) → Viggle AI (video, green/black) →
  SpriteMaster (sheet PNG + JSON) → assets/battle/sprites/. States: idle, attack, defend, hit, ko, victory.
- **Ability/effect** — Lottie JSON. Pipeline: Kling/Grok (MP4, green/black) → vizgpt.ai (Lottie JSON) →
  assets/battle/lottie/. Layered over sprite layer.
- **Menu/UI** — Flutter native.

### Asset Naming (strictly enforced — paths constructed from archetype+state+type)
- Sprites: `assets/battle/sprites/[archetype]_[state].png` + `.json`
- Lottie: `assets/battle/lottie/[archetype]_ability_[slot].json`, `assets/battle/lottie/system_[event].json`
  (system events: ko, swap, victory)
- Archetypes: athlete | musician | business | comedian | artist | gamer | influencer | scientist |
  politician | actor (Arena/celeb also use: healthcare, performer, educator, religion)
- States: idle | attack | defend | hit | ko | victory
- SpriteMaster export: uniform grid, PNG + JSON descriptor (frameWidth, frameHeight, frameCount, fps),
  512×512px recommended, fps 24 idle/victory, 30 attack/hit/ko.

### Flutter integration
- Sprites: `SpriteSheet.fromImageAssetKey('assets/battle/sprites/${archetype}_${state}.png')` +
  `SpriteAnimationData.fromJson(...)`.
- Lottie: `LottieBuilder.asset('assets/battle/lottie/${archetype}_ability_${slot}.json')` via
  AnimationController, triggered on battle_events stream.
- Animation key columns: battle_events.animation_key, battle_abilities.animation_key,
  battle_participant_status_effects.indicator_key, battle_maps.background_key.

### Type Chart (10 archetypes — rebalance via SQL UPDATE only)
athlete > Gamer, Artist · musician > Athlete, Comedian, Politician · business > Scientist, Artist, Musician ·
comedian > Politician, Actor · artist > Musician, Influencer, Gamer · gamer > Business, Politician ·
influencer > Actor, Comedian, Athlete · scientist > Gamer, Artist, Musician · politician > Business, Influencer ·
actor > Politician, Athlete, Scientist.

### Speed Stats (turn resolution order)
athlete:90 | gamer:85 | influencer:75 | actor:70 | comedian:65 | musician:60 | artist:55 | scientist:50 |
business:45 | politician:40. (Redesign: effective speed scales with snap_agility — see B5.)

### Pending
- Confirm SpriteMaster JSON matches Flame SpriteAnimationData schema.
- Phase C: wire Flutter UI to battle_events Realtime.
- Phase D: map affinity multiplier (1.15×), balance tuning. (Matchmaking queue already shipped.)

---

## A4. Battle Chits & Arena Integrity — Spec
# (former docs/battle-chits-and-arena-integrity.md — framework migrations 102–106 applied)

### The two "Arenas" (continuity)
- **Legacy Arena** (migrations 029–056, arena_match_screen.dart): creator-vs-creator live 5-min 1v1.
  Audience does arena_back (wager → arena_win) and arena_trigger (spend → fire archetype ability into
  arena_state.active_effects → changes live score). Powerups still living here: arena_abilities catalog
  (per-archetype passive/core/signature/ultimate) + arena_trigger v3 specials (Debate lockout, replay_value,
  reset_baseline, convert_flow, miracle, monopoly_ceiling, revival).
- **Redesigned Arena** (migrations 091/100/101, arena_screen.dart _LiveBattlesSection): spectator +
  prediction-market surface over Battle matches. Spectators Watch + Back a team → bets row → market with
  resolution_type='battle_outcome'. Combatants are the 6 Battle players; they influence via Battle Chits.
- Both coexist on /arena. Legacy audience-influence is walled off by §integrity (incompatible with a market).

### Core invariant — one role per match (Hard Rule 26)
For any match with an open battle_outcome market, a verified human is exactly one of: **Combatant**
(may use chits, may NOT bet) or **Spectator** (may bet, may NOT use chits). Symmetric, enforced at the DB:
1. **Bet path** (bets BEFORE INSERT, migration 102): rejects a battle-market bet from a combatant or any
   KYC-linked alt. Runs ahead of the 004 AFTER pool/token triggers → rejected bet never moves tokens.
2. **Chit path** (battle_use_chit, migration 103): participant-gated; also rejects use if caller/alt holds an
   active bet on the linked market (defense in depth).
3. **Legacy Arena** (arena_events BEFORE INSERT, migration 102): a backer can't trigger and vice versa.

### Catalog bridge (Hard Rule 27)
battle_chit_definitions (086) is the SUCCESSOR to arena_abilities. arena_abilities/arena_trigger are
legacy-only — do not extend. Mapping: Defense→damage_shield, Sprint/Clutch→momentum_surge, stat ramp→
stat_boost/aura, Counter Stance→counter, Type Breaker→type_override, Disruptor→disruption, Game Winner→
legendary/mythic per_match_use_limit=1. Chits are owned collectibles consumed from inventory, players-only,
duration in turns; influence and wager are separated by the invariant.

### KYC backstop (Hard Rule 28)
- `identity_hash` (migration 102): one-way SHA-256 of verified normalized first|last|dob; partial UNIQUE
  index over approved rows → one verified human → one staking identity. Populated by stripe-webhook on
  identity.verification_session.verified; a second account with the same identity hits the index → rejected.
  Sim mode leaves it NULL.
- `identity_linked_users(uuid)` returns alts of the same approved identity; §2 guards call it.
- Real alt-resistance = unique index + dual KYC gates: in live mode both betting and being a combatant
  require approved KYC, so one human's single approved account is either combatant or bettor.
- `platform_integrity_settings` (singleton): `enforce_one_role_per_match` default TRUE (always-on integrity);
  `require_kyc_for_staking` / `require_kyc_for_combatant` default FALSE, flip TRUE at live launch.
- Also: `date_of_birth` → 18+/21+ gate; `verified_address_country` → jurisdiction geo-restriction (wire at live).

### Chit framework (battle_chit_definitions, 086 + 103)
Fields: effect_type (stat_boost, damage_shield, momentum_surge, counter, type_override, speed_burst, aura,
disruption, wild_card), effect_value, effect_target (self/opponent/all), effect_duration_turns, stat_target,
rarity (common→mythic), animation_key (e.g. chit_bronze_shield — drives asset production), requires_target
(disruption/wild_card), per_match_use_limit (1 for legendary/mythic).
Acquisition: challenge_reward (common+), match_rng on win (rare+, LIVE), marketplace_purchase (uncommon+),
gift/event (epic+).
Usage `battle_use_chit(match, participant, chit_def, target?)`: caller owns participant; integrity guard;
1 chit/participant/turn; per-chit per-match cap; decrement inventory; record battle_chit_uses; emit chit_used.
Effect resolution — immediate: momentum_surge (momentum+=value), stat_boost (snap_*+=, whole-match),
aura (snap_*×value, whole-match), disruption (delete one random opponent effect), wild_card (immediate bench
swap). Duration/mapped + combat hooks (migration 106): damage_shield true absorb (up to value, carry remainder,
consume when depleted), speed_burst (positive speed_debuff = faster), counter (reflect dealt damage to attacker
+ attacker faint/forced-swap), type_override (floor type mult at 1.0).

### Build checklist — remaining (see PLAN.md)
Done: counter+type_override hooks, damage_shield absorb, identity_hash population, client KYC flow.
Remaining: aura on charisma/influence (stats not yet in damage formula), live combat screen (battle_match_screen
is still a test-match placeholder), acquisition flows (challenge/pack/gift scaffold-only), bench/target UX wiring.

---

## A5. Arena Testing Guide
# (former docs/ARENA-TESTING.md — dev tooling; remove before launch)

### What runs automatically (dev)
| Job | Schedule | What |
| dev-test-match-maintainer | 2 min | creates a test match if none active (no-ops otherwise) |
| arena-tick | 1 min | arena_tick_fast_loop() PROCEDURE — 6 ticks @10s with COMMIT between; flips pre_match→live, advances, resolves at 5min |
| dev-bot-backer | 1 min | 2–4 random backs (5–25 tokens, 55/45 p1 bias) on every live test match; tops up test balances |
| arena-matchmaker | 5 min | real matchmaking; weekends (Fri 19:00–Sun 23:59 UTC) Round 3 logic returns empty if no bracket |

### Pre-session checklist (Supabase SQL editor)
- Cron active: `SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;`
- Cron health: `SELECT jobid,status,start_time,return_message FROM cron.job_run_details ORDER BY start_time DESC LIMIT 15;`
  (arena-tick jobid 19 → CALL/succeeded; dev-bot-backer jobid 18 → 1 row/succeeded)
- Match states: `SELECT state, COUNT(*) FROM arena_matches GROUP BY state;`
- Force a fresh match: `SELECT dev_maintain_test_match(); SELECT process_arena_tick();`
- Abilities present: `SELECT COUNT(*) FROM arena_abilities;` → 50 (10 archetypes × 5; 4 triggerable each)
- Your balance: `SELECT available_tokens, lifetime_earned FROM token_balances WHERE user_id = auth.uid();`

### Diagnostic queries
- Current live match: join arena_matches (state IN pre_match,live) to profiles p1/p2.
- Current score: arena_state for the latest live match (score_p1/p2, flow_rate, total_pool).
- Bots backing: COUNT/SUM arena_events event_type='back' for the live match.
- Tick loop: cron.job_run_details jobid 19 (CALL/succeeded; running >2min = stuck).

### Known issues & fixes
- "No abilities available" → abilityConfigProvider cached empty pre-auth; hard refresh (Ctrl/Cmd+Shift+R).
  RLS now allows public read. Verify `SELECT COUNT(*) FROM arena_abilities;` = 50.
- "Match has ended" on bet → match resolved in the ~1s between UI render and RPC; handled gracefully, wait ≤2min.
- Bet timeout (57014) → fixed: arena_tick_fast_loop is now a PROCEDURE (COMMIT per tick) not a FUNCTION.
  Verify routine_type = PROCEDURE.
- Refresh at /arena/:matchId → /home → fixed: routerProvider uses ref.listen + refreshListenable (router not recreated).
- "Find a Match" empty on weekends → arena_matchmake in Round 3 mode; run dev_maintain_test_match()+process_arena_tick().
- Scores frozen → arena-tick stuck, OR no backing (BaseFlow ≈ 0), OR silent process_arena_tick() error.
- Test match not auto-created → maintainer only fires when no test match active; ≤2min gap after resolve.

### Test accounts (migration 051): 20 creators, 2 per archetype
athlete/musician/healthcare/performer/gamer/influencer/educator/politician/religion/business,
usernames `test_<archetype>_<role>_1`, UUIDs `10000000-…-000001` through `…000020`. Top up:
`UPDATE token_balances SET available_tokens=1000 WHERE user_id=(SELECT id FROM profiles WHERE username='…');`

### Pre-launch cleanup
`SELECT cron.unschedule('dev-test-match-maintainer'); SELECT cron.unschedule('dev-bot-backer');
DROP FUNCTION IF EXISTS public.dev_maintain_test_match(); DROP FUNCTION IF EXISTS public.dev_arena_back(uuid,uuid,uuid,int);
DROP PROCEDURE IF EXISTS public.arena_tick_fast_loop();` — restore arena-tick to call process_arena_tick()
directly. Then truncate Arena tables + run the full reset (A8).

---

## A6. Licensing Marketplace Deploy Runbook
# (former docs/lkn-deploy-runbook.md — migrations 107–113 + 8 fns now applied/deployed)

Do these in order after the branch is merged to main. Backend is DEPLOYED; what remains is gateway routing,
lkn-generate-contract, and signing-key rotation (PLAN.md).

1. **Migrations**: `supabase db push` applies 107 then 108–113 in order. Verify
   `select version from supabase_migrations.schema_migrations order by version desc limit 8;` (expect 113 top)
   and `select tablename from pg_tables where schemaname='public' and tablename like 'lkn_%';` (lkn_agreement_events,
   lkn_agreements, lkn_api_call_log, lkn_api_keys, lkn_license_templates, lkn_license_tiers,
   lkn_licensor_verifications, lkn_listings, lkn_partners, lkn_public_registry). NEVER hand-run DDL via the
   Management API query endpoint — it skips schema_migrations and breaks the next push.
2. **Private Storage bucket `lkn-partner-docs`**: `insert into storage.buckets (id,name,public) values
   ('lkn-partner-docs','lkn-partner-docs',false) on conflict do nothing;` No client policies — service role only.
3. **Signing keypair (ECDSA P-256)**: run `./scripts/lkn-signing-key-setup.sh` in YOUR OWN secure environment
   (not CI/sandbox). Writes the public key to flutter_app/web/.well-known/nora-public-key.pem, prints the command
   to set NORA_SIGNING_PRIVATE_KEY (PKCS8 PEM) as an edge-function secret. Commit the public key. lkn-verify
   degrades to signature:null until the secret is set. (Current key is known-compromised — rotate; see PLAN.md.)
4. **Deploy edge functions**: public (`--no-verify-jwt`) lkn-verify, lkn-register-api-key, lkn-partner-apply;
   JWT-gated lkn-register-licensor, lkn-create-listing, lkn-submit-template, lkn-purchase-license, lkn-revoke-license.
   Optional env `LKN_PAYMENTS` (default sim).
5. **Gateway / routing**: point `GET https://api.noraplatforms.com/v1/verify` at the deployed lkn-verify
   (Cloudflare route or Vercel rewrite → https://cceisywxwhgljdpisjrl.functions.supabase.co/lkn-verify).
   Reads license_id / licensee_nora_id / use_category from the query string. **Still outstanding** (PLAN.md).
6. **Smoke test**: register a key via POST /lkn-register-api-key; verify an unknown id returns not_found (still 200)
   via GET /lkn-verify?license_id=LKN-2026-NOPE with X-NORA-API-Key.
- **Still outstanding**: lkn-generate-contract (needs attorney-seeded lkn_contract_clauses — do not fabricate legal language).

---

## A7. Battle Stage Background Design Guide
# (former docs/stage_template_guide.md)

All stage backgrounds: 16:9, recommended 1920×1080. The image is contained to fit; character coordinates are
relative to the contained rectangle. Sprites placed with `anchor: Anchor.bottomCenter`.

| Platform | Horizontal center (% width) | Vertical base/anchor (% height) | Perspective |
| Player Podium | 24.5% | 73.0% | back-facing (away from camera), lower & slightly larger |
| Opponent Podium | 77.5% | 67.0% | front-facing (toward camera), higher & slightly smaller |

No intrusive elements (equalizers, bright lights, UI boundaries) directly behind the platform coordinates.

---

## A8. Pre-Launch Reset Sequence
# (former docs/pre-launch.md — run before July 4 2026)

1. Run 027_teardown_test_accounts.sql
2. Truncate Arena and Battle tables (test rows only)
3. Reset real user token_balances, truncate transactions and purchases
4. Truncate badges, challenges, streaks, bets, markets, score_history
5. Keep: profiles, platform_connections, waitlist, celebs, celeb_weekly_scores
6. Do NOT re-run OG/Early Adopter cutoff migration
7. Re-grant signup bonuses via increment_token_balance(user_id, 100)

OG cutoff: 2026-07-04T04:00:00Z · Early Adopter cutoff: 2026-08-03T04:00:00Z (already set — do not re-run).
Also remove all dev tooling per A5.

# ===========================================================================
# PART B — HISTORY & SUPERSEDED
# ===========================================================================

## B1. Redesign Ground-Truth — Migration Ledger
# (former docs/redesign-ground-truth.md — authoritative record of what was pushed)

### Doc 1 — New Schema (migrations 080–090, pushed 2026-06-06)
Introduced Likeness Cards (replacing Campaigns), creator stat sheets, card marketplace, Arena↔Battle link,
weekly polls, battle chits, celebrity integration, match-revenue token distribution, campaign deprecation,
KYC simplification.

| # | File | What |
| 080 | creator_stat_sheets.sql | creator_stat_sheets + creator_stat_history; calculate_stat_sheets() (6 percentile-ranked stats, 300-pt budget). Wired into sync-platform-metrics in Doc 2. |
| 081 | likeness_system.sql | likeness_offerings, likeness_cards (rarity GENERATED), likeness_card_transfers (append-only); likeness_mint_card(). |
| 082 | card_marketplace.sql | card_marketplace_listings; likeness_list_card(), likeness_buy_card(). |
| 083 | battle_format_ownership.sql | links cards to Battle eligibility (rosters/slots). |
| 084 | arena_battle_link.sql | Arena↔Battle linkage. |
| 085 | weekly_polls.sql | weekly_polls, weekly_poll_options, weekly_poll_votes (poll-vote anti-abuse preserved). |
| 086 | battle_chits.sql | battle_chit_definitions, inventory, uses (post-launch activation). |
| 087 | celebrity_integration.sql | links profiles.celeb_id → celebs; celeb stat inputs from celeb scores. |
| 088 | match_revenue_tokens.sql | match_revenue_distributions; 90/5/5 split, all logged in token_transactions. |
| 089 | campaign_deprecation.sql | renames 7 live campaign tables → campaigns_archived_*; closes open campaigns; unschedules campaign-status-tick + governance-tick. |
| 090 | kyc_simplification.sql | simplifies KYC for the cards system. |

Deviations: 081 rarity can't be DEFAULT+GENERATED (removed DEFAULT). 089 dropped 3 never-created Phase-4 table
renames. 070_rename_rive_to_animation.sql deleted (duplicate 070 prefix). 070–079 stale schema_migrations
entries repaired via db query before pushing 080–090. Stat sheets return 0 rows in dev (all 20 MMs are
is_test_account=TRUE).

Campaign table renames: campaigns→campaigns_archived, _ledger, _revenue, _distributions, _proposals, _votes,
_updates. (stake_listings/stake_sales/unclaimed never existed — Phase 4 was queued.)

### Doc 2 — Game Logic (migration 091, commit dbf1f37)
Wired stat sheets into Battle damage, market auto-creation at battle start, distribute_match_revenue,
chit usage scaffold, Spotlight from battle-wins, marketplace/poll route stubs.
| markets.resolution_type | 'display_score' (default) | 'battle_outcome'; index on battle_match_id |
| battle_participants.snap_* | 6 INTEGER columns DEFAULT 50 |
| effect_type CHECK extended | stat_boost, damage_shield, speed_burst, counter, type_override, aura, disruption |
| distribute_match_revenue() | 75% winner betters / 10% active players / 5% creators / 5% card holders / 5% platform |
| battle_use_chit() | validates ownership, decrements inventory, writes to battle_participant_status_effects (NOT arena_state) |
| battle_start_match() | format-aware (1v1/2v2/3v3), stat snapshot, speed recalc, auto-creates market |
| process_battle_turn() | stat damage mods (power ±20%, wit ±10%, resilience up to −30%), market settlement, chit RNG drop |
| arena_monday_rollover() | Spotlight from battle-wins top 5; poll multiplier reset |
sync-platform-metrics now calls calculate_stat_sheets(). resolve-markets gains resolveBattleOutcomeMarket()
24h cron safety net. Deviations: chit effects → battle_participant_status_effects (not arena_state, Hard Rule 21);
used existing battle_get_archetype_speed(); process_poll_results() stubbed (Doc 3 implements); chits write but
process_battle_turn didn't yet read them (post-launch); yes_pool=team_1, no_pool=team_2.

### Doc 3 — Marketplace & Polls (migration 092, commit e1f25eb)
092 restores real process_poll_results() (rank 1→1.150×, 2→1.100×, 3→1.060×, ≤5→1.030×, ≤10→1.010×, else 1.0;
updates creator_stat_sheets.effective_*; logs poll_boost_applied amount=0). New edge fns: poll-vote
(IP 3/poll + device 5/poll, registered weight 1.0 / anon 0.3), celebrity-integration-seed (admin),
likeness-create-offering, likeness-purchase-card, likeness-list-card, likeness-buy-listed-card,
chit-marketplace-list, chit-marketplace-buy. Flutter: crypto pkg, device_fingerprint.dart, polls feature,
marketplace feature (Characters + Chits tabs), home Poll-Leaders strip, public-profile stat-sheet card.

### Doc 4 — Emergency Fund (migrations 093–097)
ubi_* tables. Hard rules: AI never recommends; docs private forever; votes private forever; Stripe Treasury
sim-mode until app clears. (Doc 4 design numbered these 090–094; actual applied numbers were 093–097.)

### Post-Doc-4 (2026-06-07)
Home Community Cards (Marketplace card + Emergency Fund live-balance card). Migration 098
ubi_pool_balance_realtime (adds cache to realtime publication). Migration 099 fix_battle_market_timeframe
(091 inserted battle market without NOT NULL timeframe → now '24h'/'1day'). Battle-market bet UI: openMarketsProvider
filters display_score; BattleMarket model + battle_bet_sheet (team_1=yes / team_2=no). Deliberately NOT done:
chit status-effect application in process_battle_turn (post-launch); Campaigns removal (kept archived/read-only).

### Battle end-to-end matchmaking (2026-06-07)
Migration 100 battle_bet_pool_mapping (handle_bet_pool_update maps team_1→yes_pool, team_2→no_pool — battle bets
previously never pooled → markets always voided). Migration 101 battle_matchmaking (battle_start_match →
host-checked wrapper + _internal; battle_matchmaking_queue table + RLS; battle_enqueue/battle_try_matchmake/
battle_leave_queue; smoke-tested via RAISE rollback). Flutter: myBattleQueueProvider, battle_matchmaking_screen
at /battle/matchmaking, lobby "Quick Match", arena_screen _LiveBattlesSection. Still placeholder: combat screen
(test-match), no bot-fill (PLAN.md next task), legacy battle_spectator_bets unused.

### Arena/Battle integrity + chit framework (2026-06-08 → 06-09)
Migration 102 arena_battle_market_integrity (identity_hash + partial UNIQUE; platform_integrity_settings;
is_kyc_verified/identity_linked_users/is_match_combatant; enforce_bet_integrity / enforce_arena_event_integrity /
enforce_combatant_kyc). Migration 103 battle_chit_framework (animation_key/requires_target/per_match_use_limit;
battle_chit_uses ledger; battle_use_chit rewrite with integrity guard + caps + effect resolution; counter/
type_override deferred). Migrations 104 (increment_token_balance BIGINT overload) + 105 (markets_resolution_result
CHECK += team_1/team_2) — both pre-existing 091 bugs that broke EVERY battle-market settlement, masked by
process_battle_turn's EXCEPTION WHEN OTHERS. Smoke test `supabase/tests/battle_market_pipeline_smoke.sql` PASSING
9/9. Migration 106 battle_chit_combat_hooks (type_override floor 1.0; damage_shield true absorb; counter reflect +
faint/forced-swap) via pg_get_functiondef surgical edit. stripe-webhook gains identity.verification_session.verified
branch. kyc-create-session edge fn + Flutter features/kyc + /verify-identity. flutter analyze clean.
Go-live KYC: set KYC_MODE=live + STRIPE_SECRET_KEY (+ APP_URL) and require_kyc_for_staking=true.

### Doc 5 + Doc 6 (2026-06-18)
Doc 5 Licensing: migrations 107–113 applied, 8 fns live, lkn-partner-docs bucket made, smoke test passed,
Flutter screens + Hard Rules 29–32 + public signing key merged. Signing key works but known-compromised
(Codespace) — rotate later. Remaining: gateway routing, lkn-generate-contract.
Doc 6 mobile prep (Repo A): migration 114 (profiles.fcm_token_mobile) + four nora-arena-api-* fns DEPLOYED
+ verified live. Phase-6 backend mobile_iap_confirm fn + migration 115 (mobile_iap_receipts idempotency ledger)
built + smoke-tested on branch doc6-mobile-iap-confirm (commit ee5a782) — NOT yet pushed/merged. Remaining
external: gateway routing, RevenueCat config.

---

## B2. Dropped Schema Elements & Design History
# (former docs/ARCHIVE.md — historical; do not reference dropped fields)

### Repo audit (April 2026)
Two-tier category system replaced flat 14-category list (migration 024). resolution_score dropped; composite
display_score took over Market resolution (migration 019). heat_score baseline reset to 0; boost-only (019).

### Dropped / never-built
- **resolution_score** (dropped 019): platform_metrics had a normalized 0–100 metric; gone. Resolution now sums
  platform_metrics.display_score vs markets.opening_resolution_score (which stores the composite bigint snapshot).
- **power_up_cooldowns** (never built): cooldowns enforced via active_boosts (unexpired entry = active).
- **platform_metrics.spotlight_pinned_until** (never built): pinning uses active_boosts type spotlight_entry.
- **profiles.accepts_new_markets** (never built): eligibility = is_market_maker AND NOT pending_opt_out.
- **profiles.token_balance** (never built): balances live in token_balances table.

### Arena design history (superseded)
- Match durations: 1h R1 / 30m R2 rejected → uniform 5-min matches all rounds.
- Shift action removed → canonical token actions are Back and Trigger only.
- Spotlight reset (locked April 2026): the Monday after a creator holds a Spotlight slot, both heat_score AND
  momentum_score reset to 0 (earlier spec reset only heat).
- Single Spotlight → two sections: Arena Champions (5) + Top Movers (5).
- Resolved questions: carry = momentum_score column; decay linear over 1 week; reset scope = heat+momentum;
  two token actions (no Shift).

### Category migration mapping (024)
Comedian→Performer/Comedian · Doctor→Healthcare/Doctor General · Researcher→Healthcare/Researcher ·
Fitness→Influencer/Fitness · Sports→Athlete/(subcategory null, flagged for reselection).

### React Home App retirement
landing/ React app deleted. Flutter HomeScreen is the sole home page. Vercel routes all paths (except /privacy,
/terms, /tiktok-verification) to Flutter index.html via a single catch-all rewrite in vercel.json.

---

## B3. Completed Phase Details (pre-redesign phases)
# (former docs/ARCHIVE.md — full bullet detail of phases 1–8 and additions)

- **Phases 1–3.5:** auth (signup/login/forgot-password/username); token economy (100 signup, +25 referral);
  home (spotlight, creators carousel, bell); discover (Famous/Rising/Who's Live, tier + Live Now badges);
  wallet; profile (Market Maker 3-step opt-in, opt-out); platform connections (YouTube + Twitch OAuth);
  public profiles (/u/username); referral (/join?ref=); notifications; markets (Open + My Bets, pool bars,
  timeago); betting (4-step sheet); pg_cron metric sync (5min).
- **Phase 4 — Stripe token purchases:** create-checkout-session + stripe-webhook; token_purchases (007); wallet
  "Get More Tokens" (Starter $0.99 / Popular $4.99 / Pro $9.99 / Elite $19.99); /wallet?purchase=success|cancelled.
- **Phase 5 — Market resolution:** resolve-markets (payouts, voids); market detail (countdown, resolving/resolved/
  voided); bet blocking (status≠open or end≤15s); resolvedAt/resolutionResult.
- **Post-Phase-5 — public profile:** /u/:username (avatar, bio, category, Heat badge, Display Score, per-platform
  stats incl Spotify #1DB954, badges shelf, Promote/Power-Up); publicProfileProvider via public_platform_connections
  view (023); Preview/Promote on own profile.
- **Phase 6 — Promotions & Power-Ups:** active_boosts (014); apply-promotion (catalogue, cooldown via active_boosts,
  discount/multiplier, promotion_banners); heat_score = clamp(sum boost deltas, 0, 100); self-boosts
  (Quick 80T/+8/1h, Major 250T/+20/1h, Spotlight Entry 500T/4h); power-ups (Universe 800T, Galaxy 300T,
  +Popularity 400T/+12); sabotage (−Popularity 350T/−12, Black Hole 250T, Super Massive 800T); MM 20% discount;
  1.5× delta if ≥200T open bets; PromotionFlashBanner + HomeTicker (Realtime).
- **Phase 7 — Challenges & Badges:** migrations 016–018 (21 badges, 19 challenges, user_badges,
  user_challenge_progress, user_streaks, user_passive_effects view, evaluate_main_character_badge());
  evaluate-challenges (idempotent); BadgesShelf; ChallengesScreen (Daily/Weekly/Monthly); /challenges;
  daily check-in; bet_placed + bet_placed_unique_mm events; passiveEffectsProvider applied to Rising/Who's Live/Spotlight.
- **Phase 8 — New scoring (019):** display_score numeric→bigint additive; resolution_score DROPPED; heat baseline 0
  (boost-only); previous_follower_count for 24h delta; score_history (Robinhood chart); opening_resolution_score
  stores composite bigint; ScoreDashboard 1D/1W/1M/3M/YTD.
- **Post-Phase-7 platforms:** X (Twitter) OAuth + metrics (020); Spotify OAuth (saved tracks/albums via column
  reuse); public_platform_connections view (023); beta approval gate (021): is_approved, approve_beta_user(),
  /pending-approval, auto-approve pre-approved waitlist emails.
- **Pre-launch — cover screen:** LaunchScreen (countdown to July 4 2026 00:00 UTC, waitlist email + consent +
  legal footer); waitlist table (022): email UNIQUE, anon INSERT open, no anon SELECT; / shows LaunchScreen in pre-launch.

---

## B4. Deprecated Campaigns Royalty Framework
# (former docs/campaigns-framework.md — DEPRECATED migration 089, replaced by Likeness Cards.
#  Preserved in full because it is the only record of this design + the on-chain / Reg CF vision,
#  which still informs the append-only ledgers and the licensing revenue-share roadmap.)

### Vision
Creators launched funding campaigns where backers purchased a % of future royalties from a specific work.
Platform held funds in escrow, auto-disbursed royalties as revenue was verified, gave backers governance
over escrowed capital. An investment, not a donation — escrow + verified revenue enforce the contract.

### Regulatory framework (Reg CF, JOBS Act)
NORA to register as a Funding Portal; each campaign a securities offering requiring a Form C. Annual raise
limit $5M/creator. Non-accredited US investor limits (income/net-worth < $124k → lesser of $2,500 or 5%;
both ≥ $124k → 10% of lesser, capped $124k/yr across ALL Reg CF). Accredited: no per-offering limit.
International: home jurisdiction; KYC/AML for all. Secondary trading requires a registered ATS. Funding window
max 12 months (NORA default 90 days). Attorney review required before any live campaign.

### Architecture decisions
- **Escrow (MVP):** Stripe Connect (Express) + Stripe Treasury; disbursement via SECURITY DEFINER fns; no manual
  creator access — only governance-approved proposals release capital. Auditable via campaign_ownership_ledger +
  campaign_distributions.
- **On-chain migration path (build MVP with this in mind):** NORA has a proprietary coin in development. At launch
  the ledger migrates to on-chain smart contracts; each campaign's stake = a token (ERC-20-equiv). The ledger is
  append-only immutable (every change a new row) — mirrors blockchain state, makes migration straightforward.
  MVP rule: never mutate ownership; always append. USD in integer cents; percentages DECIMAL(10,6).
- **Simulation mode:** `mode` flag; sim uses sim_usd_balances ($10,000 seed), no Stripe calls, real data flows.

### Platform fee — DECIDED Option B (Blended) 2026-05-23
3% at funding close + 1.5% per distribution + 0.5% per secondary trade side (0.5% seller + 0.5% buyer).
(Rejected: Option A pure 6% success fee; Option C tiered by size.)

### Data model (tables, all `campaign_*`, monetary integer cents, % DECIMAL(10,6))
kyc_verifications (identity + AML/PEP + Reg CF investor limits + trusted contact; later simplified by 089 to drop
Reg CF columns); campaigns (offer: funding_goal, royalty_pct_offered, royalty_term_years NULL=perpetual, mode,
status draft→pending→open→funded/failed→active→closed, revenue anchors, escrow, Form C, on-chain fields,
fee snapshots); campaign_ownership_ledger (append-only; from/to_user_id NULL=mint/burn; event_type purchase|
secondary_sale|inheritance|platform_correction); sim_usd_balances + sim_usd_transactions; campaign_revenue_events
(source, period, gross/platform/net cents, evidence_type creator_upload|csv_export|api_pull|data_partnership|
oracle, verification_status); campaign_distributions (one per backer per event; royalty_pct_at_time snapshot;
UNIQUE event+backer); campaign_proposals + campaign_votes (governance — simple majority royalty-weighted, 25%
quorum, 72h window, max 20% escrow/proposal, 30-day cooldown on rejected, process_governance_tick auto-executes
sim approvals; vote weight = royalty_pct snapshot at vote time); campaign_stake_listings + campaign_stake_sales
(secondary buy-now; 0.5%+0.5% fees; on sale write two ledger rows); campaign_unclaimed_balances (trusted contact /
estate handling); campaign_updates (creator comms, notification fan-out).

### Lifecycle
draft → pending (Form C prep) → open (KYC + Reg CF limits enforced) → funded (escrow locked, deliver work) OR
failed (full refund, ledger reversed) → active (royalties flow, governance + secondary enabled) → closed (term
expired, final unclaimed sweep).

### Revenue verification roadmap (same schema, changing evidence_type)
P1 creator self-report → P2 CSV import (DistroKid/TuneCore/CD Baby) → P3 direct API pull (Spotify for Artists,
YouTube Analytics) → P4 data partnerships (target state) → P5 on-chain oracle (post coin launch, trustless).
Plug-in vision: one edge fn `campaign-pull-[platform]` per platform, all writing campaign_revenue_events.

### Share/discovery & KYC flow
/campaign/:id with Vercel-edge OG meta tags; pre-filled share intent URLs (X/FB/WhatsApp/LinkedIn/copy);
?ref=username&src=platform attribution → referral_bonus pattern. KYC at first investment (Stripe Identity +
address + trusted contact + US income/net-worth → Reg CF limit), auto-approved in sim, expires 1 year.

### Build status at deprecation
Phases 1–3 DONE in SIM (migrations 072–078): KYC, sim balances, campaigns + status tick, ownership ledger +
invest, list/detail screens; revenue events + process_campaign_distributions + earnings dashboard; proposals +
votes + governance tick + campaign_updates. Phase 4 (secondary market), Phase 5 (live mode: Stripe Connect,
real KYC, Reg CF enforcement, Form C), Phase 6 (revenue API integrations), Phase 7 (on-chain) were QUEUED when
the whole framework was superseded by Likeness Cards. **The on-chain/coin design intent now lives on in the
append-only Likeness card and licensing ledgers (see PLAN.md long-horizon).**

---

## B5. Redesign Design-Doc Highlights
# (distilled from nora_redesign_doc1–6; the full SQL is in supabase/migrations/, applied state in B1.
#  Captured here: formulas, framing rules, and decisions not fully recorded above.)

### Doc 1 — Schema & framing
- **calculate_stat_sheets()** (SECURITY DEFINER): six raw stats per market maker — Power (total follower reach),
  Charisma (platform-weighted engagement rate), Resilience (1 − churn), Agility (growth velocity 0.7 + platform
  diversity 0.3), Wit (content quality signal), Influence (avg display_score per platform). Celebs derive stats
  from celeb_weekly_scores + celeb_score_history. All percentile-ranked globally (PERCENT_RANK), then normalized
  to a **300-point budget** (50 avg/stat; zero-sum new users default 50). Effective = base × weekly_poll_multiplier.
  Snapshots to creator_stat_history. Filters is_celeb/is_test_account; only is_market_maker AND NOT pending_opt_out.
- **Likeness framing rule (mandatory in all card-facing copy/code):** collectible game assets — "Offering",
  "Card" (Battle eligibility + match-reward share), "Match rewards". NEVER "investment/return/yield/dividend/
  revenue share". Card rarity by number: #1 legendary, #2–10 rare, #11+ standard. total_pct_offered ≤ 75%.
- **check_battle_eligibility(user, creator):** eligible if user IS creator (self) OR owns an active card for that
  creator (owner). **get_eligible_characters(user)** = own profile (if MM) + all owned cards, with stat sheets.
- **RLS pattern for new tables:** public read for status=active/sold_out; writes via SECURITY DEFINER RPCs only;
  ledgers insert via RPC only; poll_votes insert via edge fn only (anti-abuse there).

### Doc 2 — Game logic formulas
- **Battle stat damage mods:** power_mod = 1 + (snap_power−50)/250 (50→1.0, 100→1.2); wit_mod = 1 + (snap_wit−50)/500
  (100→1.1); resilience_reduction = snap_resilience/500 (max 0.30). Effective speed scales with snap_agility:
  base_archetype_speed × (0.8 + snap_agility/300 × 0.4).
- **Arena (redesign) HeatInfluence** × charisma factor (0.8 + effective_charisma/300 × 0.4); momentum gain × influence factor.
- **distribute_match_revenue()** pools (match_revenue_config): winner_betters 75% (proportional + original stake
  returned), active_participants 10% (winning team, equal), creator 5% (all chars' MMs equal; celeb → managed_wallet),
  passive owners 5% (all card holders proportional to royalty_pct), platform 5% (burned). Voids/refunds if losing pool 0.
- Spotlight Arena Champions sourced from cumulative weekly Battle wins (replaces Round-3 bracket). compute-spotlight
  may also return poll_winners (top 5 most recent closed poll).

### Doc 3 — Polls & marketplace
- Poll vote weights: registered 1.0, anonymous 0.3. Anti-abuse: IP rate-limit 3/poll (silent flag, zero weight),
  device fingerprint 5/poll. SHA-256 hash IP + UA; client device fingerprint never sent raw. **Do not simplify.**
- Poll multiplier ladder (process_poll_results): rank 1→1.150, 2→1.100, 3→1.060, ≤5→1.030, ≤10→1.010, else 1.000.
  Applied Monday rollover after a reset of all multipliers to 1.000. create_weekly_poll Mon 00:05; close Sun 23:59.
- Chit seed catalog (085): Bronze/Silver Shield (damage_shield 20/40), Power Surge (stat_boost +15 power),
  Momentum Crystal (+40), Counter Stance (rare, 10% drop), Speed Burst (+30/2 turns, 8%), Charisma Aura (×1.20, 7%),
  Disruptor (epic, remove opponent effect, 3%), Type Breaker (epic, 2.5%), Wild Card (legendary swap, 0.5%),
  NORA Aura (mythic, all stats ×1.50). Acquisition gating by rarity (challenges common+, marketplace uncommon+,
  match RNG rare+, gift epic+). Marketplace fees: card secondary 5% platform / 95% seller.
- celebrity-integration-seed (admin, x-admin-key): creates managed auth users for the 25 celebs (no login),
  is_celeb=TRUE, managed_by_platform=TRUE; revenue → celebs.managed_wallet_usd_cents until the real person claims.

### Doc 4 — Emergency Fund core rules (the design contract)
Platform DOES: contribution checkout (Stripe), route requests to AI (claude-sonnet-4-6), assemble random voter
panels, tally + trigger disbursement, call Stripe to disburse. Platform does NOT: hold funds (Stripe Treasury),
make decisions (panel), recommend votes (AI doesn't either), access documents (AI-only via Anthropic API).
| Request cap | lesser of 10% of pool or $1,000 |
| Min contribution to vote | $1 lifetime |
| Panel size | $0–100 → 11 · $101–500 → 21 · $501+ → 51 |
| Threshold | simple majority of votes cast |
| Window | 72h; one 24h extension if <50% voted |
| Inactive voter | 24h → replaced (one per, no panel overlap) |
| Revote | one, fully fresh panel, zero overlap |
| Cooldown after approval | 90 days |
| Anonymous contributions | allowed | Requester KYC | required before disbursement |
| Documents | AI-only, never to voters/staff | Vote tally | hidden until close |
AI system prompt is an intake coordinator: evaluates fund scope, requests appropriate documents, writes a neutral
PII-free voter summary. Hard constraints: NEVER recommend approve/deny; NEVER include name/location/employer/
facility; out-of-scope (luxury/business/gambling) → within_fund_scope=false → request voided. Scope: medical,
housing, utilities, food, transportation (employment), funeral, disaster. Tables ubi_pool_config/balance_cache/
contributions, ubi_withdrawal_requests, ubi_request_documents, ubi_ai_evaluations, ubi_voting_panels/
panel_assignments/panel_votes, ubi_disbursements/public_disbursement_log.

### Doc 5 — Licensing toggle model & revenue
Licensor tiers: self (KYC + ≥1 linked platform), agent (Partners Portal), celeb (from celebs table).
License template (lkn_license_templates, one per tier) toggles, all defaulting to most-restrictive: Duration
(perpetual/fixed/project), Territory (worldwide/us/eu/specific), Purpose (AI generated content / voice cloning /
image gen / model training / advertising / film / tv / game / music / social / merchandise / nft / editorial
[always true] / custom), Content restrictions (profanity/adult/political/religious/violence/substance/competitor/
illegal[always] + restricted_topics[]), AI controls (must-be-labeled, max instances, no-deepfake-sexual[always],
no-misleading-context[always]), Sublicensing, Approval rights, Revenue share %, Revocation (for_cause/at_will_30d/
irrevocable), custom attorney PDF addendum. terms_snapshot on lkn_agreements is the contract in force (Hard Rule 29).
Revenue: listing free; **5% commission on license sale**; verification API free 1,000 calls/day/key then $0.001/call.
generate_license_id() → LKN-[year]-[8 unambiguous chars]. lkn-verify response is ECDSA-P256 signed; public key at
/.well-known/nora-public-key.pem.

### Doc 6 — Mobile app architecture (separate repo nora-arena)
A separate repo is required (different build targets/pipeline/cadence/deps) sharing the same Supabase project +
N.O.R.A. REST API. Tech: Flutter + Flame (game) + Lottie/Rive (effects/idle) + FCM (push) + RevenueCat (IAP).
V2 Unity only if revenue justifies (data layer is engine-agnostic). DATA LAYER RULE: no tables/edge functions/
pg_cron move — mobile is frontend-only; licensing reached only via api.noraplatforms.com/v1/verify. Headline test
= License Sync: buy a character license on web → app calls /verify?licensee_nora_id=…&use_category=entertainment_game
→ unlock matching characters. Remove web Battle/Arena screens only AFTER mobile is confirmed working; replace with
"play on mobile" redirects. RevenueCat products: chit_pack_common/rare, tokens_starter/popular/pro/elite →
mobile_iap_confirm (idempotent, same token_transactions). Risks/mitigations: Flame perf (profile early, cut
particles before frames), Realtime latency (optimistic UI), app-store gambling rejection (label "prediction
markets" as entertainment, no real-money flow), license API downtime (cache 24h TTL), model drift (lint/shared pkg),
IAP/Stripe double-credit (idempotent ON CONFLICT). Repo B has its own CLAUDE.md (no schema/edge-fn changes there).
