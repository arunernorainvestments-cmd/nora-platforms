# Battle Mode — Engineering Spec
# Phases A + B complete. Phase C (Flutter/Flame/Lottie integration) in progress.

## Turn Flow
1. Lobby created (battle_create_lobby) — 6-char code shared out of band
2. 5 others join (battle_join_lobby) — 3 per team
3. Host starts (battle_start_match) — random map selected
4. 30s submission window — all 6 submit simultaneously
5. process_battle_turn() fires every 3s via pg_cron
6. Resolution: voluntary swaps first, then attacks in speed order
7. Status effects applied and expired each turn
8. KO triggers forced swap to next bench character
9. All fainted = match resolved, spectator bets settled
10. Forfeit available any time via battle_forfeit RPC

## Animation Architecture (Phase C)

CHARACTER ANIMATIONS — Flame engine with sprite sheets
- Pipeline: Grok Imagine (stills) → Viggle AI (video, green/black screen)
  → SpriteMaster (sprite sheet PNG + JSON) → assets/battle/sprites/
- Required states per archetype: idle, attack, defend, hit, ko, victory
- Rendered via SpriteAnimationWidget + SpriteAnimationData

ABILITY AND EFFECT ANIMATIONS — Lottie JSON
- Pipeline: Kling or Grok (MP4, green/black screen)
  → vizgpt.ai (Lottie JSON) → assets/battle/lottie/
- Rendered via lottie Flutter package, layered over sprite layer

MENU AND UI INTERACTIONS — Flutter native
- Hover/tap effects, button states, timer countdown built in Dart

## Asset Naming Convention (strictly enforced)
Claude Code constructs asset paths from archetype + state + type.
Any deviation breaks loading logic.

SPRITE SHEETS
  assets/battle/sprites/[archetype]_[state].png
  assets/battle/sprites/[archetype]_[state].json

Valid archetypes:
  athlete | musician | business | comedian | artist
  gamer | influencer | scientist | politician | actor

Valid states: idle | attack | defend | hit | ko | victory

LOTTIE EFFECT FILES
  assets/battle/lottie/[archetype]_ability_[slot].json
  assets/battle/lottie/system_[event].json
  (system events: ko, swap, victory)

SPRITE SHEET REQUIREMENTS (SpriteMaster export settings)
- Uniform grid layout — all frames identical pixel dimensions
- Export both PNG and JSON descriptor to same directory
- JSON must include: frameWidth, frameHeight, frameCount, fps
- Recommended frame size: 512x512px
- fps: 24 for idle/victory, 30 for attack/hit/ko

## Flutter Integration Pattern

Sprite sheets via Flame:
  SpriteSheet.fromImageAssetKey('assets/battle/sprites/${archetype}_${state}.png')
  SpriteAnimationData.fromJson(json from assets/battle/sprites/${archetype}_${state}.json)

Lottie effects:
  LottieBuilder.asset('assets/battle/lottie/${archetype}_ability_${slot}.json')
  Controlled via AnimationController, triggered on battle_events stream

## Animation Key Columns (DB)
  battle_events.animation_key         — triggers Lottie/Flame state per event
  battle_abilities.animation_key      — maps ability → Lottie asset key
  battle_participant_status_effects.indicator_key — visual effect badge
  battle_maps.background_key          — background asset per map

## Type Chart (10 archetypes — rebalance via SQL UPDATE only)
  athlete beats: Gamer, Artist
  musician beats: Athlete, Comedian, Politician
  business beats: Scientist, Artist, Musician
  comedian beats: Politician, Actor
  artist beats: Musician, Influencer, Gamer
  gamer beats: Business, Politician
  influencer beats: Actor, Comedian, Athlete
  scientist beats: Gamer, Artist, Musician
  politician beats: Business, Influencer
  actor beats: Politician, Athlete, Scientist

## Speed Stats (turn resolution order)
  athlete:90 | gamer:85 | influencer:75 | actor:70 | comedian:65
  musician:60 | artist:55 | scientist:50 | business:45 | politician:40

## Key Tables
  battle_matches | battle_participants | battle_turn_submissions
  battle_events | battle_participant_status_effects
  battle_spectator_bets | battle_abilities | battle_type_chart
  battle_maps | battle_animation_keys | battle_match_telemetry

See docs/scoring-and-db-spec.md for full table schemas and data flow.

## Battle Chit (framework built — migrations 086 + 103)
Collectible single-use items (Megaman NT Warrior model). Player-only powerups;
spectators with a market stake may NOT use them (see one-role invariant below).
Tables: `battle_chit_definitions`, `user_battle_chits`, `chit_marketplace_listings`,
`battle_chit_uses`. Used via `battle_use_chit(match, participant, chit_def, target?)`.
Per-chit `animation_key` drives asset production. Effect semantics, caps, and the
deferred `counter`/`type_override` hooks: see docs/battle-chits-and-arena-integrity.md.

## Market integrity (migration 102)
For a match with an open `battle_outcome` market, a verified human is either a
COMBATANT (uses chits, cannot bet) or a SPECTATOR (bets, cannot influence) — never
both, enforced at the DB layer across KYC-linked alts (`identity_hash`).

## Pending
- Confirm SpriteMaster JSON format matches Flame SpriteAnimationData schema
- Phase C: wire Flutter UI to battle_events Realtime stream
- Phase D: map affinity multiplier (1.15x), matchmaking queue, balance tuning
