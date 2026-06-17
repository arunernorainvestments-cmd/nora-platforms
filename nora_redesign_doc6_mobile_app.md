# NORA Redesign — Doc 6: Arena/Battle Mobile App Architecture
# For Claude Code — Read ENTIRELY before touching any file in either repository.
# This document governs TWO repositories:
#   Repo A: arunernorainvestments-cmd/nora-platforms (existing web app)
#   Repo B: arunernorainvestments-cmd/nora-arena (NEW mobile app — create this repo)
# Companion docs: doc1–5

---

## CLAUDE CODE SELF-AUDIT PROTOCOL

Before implementing any section of this document:

1. READ these files in the existing web repo (Repo A):
   - CLAUDE.md — canonical rules; anything that still applies carries over
   - docs/battle-spec.md — this is what you are migrating OUT of the web app
   - docs/scoring-and-db-spec.md — the database stays shared; only UI moves
   - docs/infra.md — edge functions stay in Supabase; only Flutter UI moves
   - lib/router.dart — identify all /battle and /arena routes for removal
   - Current migration list (supabase/migrations/) — do NOT add new migrations
     to the web repo as part of this work; all existing tables remain

2. CROSS-REFERENCE before removing anything from Repo A:
   - Confirm the feature exists and is working in Repo A before migrating it
   - Confirm the Supabase table/edge function it depends on is NOT being deleted
     (tables and edge functions stay in Supabase — only Flutter code moves)
   - If a provider, model, or utility is used by BOTH battle/arena screens AND
     non-battle screens in Repo A, do NOT remove it from Repo A; copy it to Repo B

3. ADJUSTMENT PRINCIPLE:
   - This spec describes architecture and intent. Implementation details may need
     adjustment based on what you find in the actual codebase.
   - Add // MIGRATED TO nora-arena: [reason] comments wherever code is removed
   - Add // KEPT IN nora-platforms: [reason] wherever code is intentionally not moved
   - When in doubt: keep it in Repo A AND add it to Repo B; duplicates are safer
     than gaps during migration

4. DATA LAYER RULE (critical):
   - NO database tables, NO Supabase edge functions, and NO pg_cron jobs move
     to Repo B. All backend stays in Supabase under the existing project.
   - Repo B communicates with Supabase via the same anon/service keys.
   - Repo B communicates with Repo A's licensing system via the N.O.R.A. REST API.
   - The mobile app is a new FRONTEND ONLY. The backend is shared.

---

## Strategic Purpose of This Split

The Arena/Battle mobile app exists for two reasons:

1. **Visual quality**: A dedicated mobile app removes the constraints of Flutter web
   rendering. The game can use native GPU rendering, proper sprite engines, and
   frame-rate-optimized animations that the web target cannot match.

2. **Integration testbed**: It is the first live demonstration of the N.O.R.A. licensing
   API working cross-platform. A user buys a character license on N.O.R.A. Platforms
   (web), the Arena/Battle app queries the verification API, and unlocks that character.
   This proves the licensing infrastructure works before pitching it to Spotify, YouTube,
   or AI platforms.

The prediction market (Arena) is visible in the mobile app as a spectator layer —
the same data source as the web app. Bettors who prefer to watch and bet on mobile
get that experience without any backend duplication.

---

## Repository Architecture Decision

**Create a new repository: `arunernorainvestments-cmd/nora-arena`**

Yes, this must be a separate repository. Reasons:
- Different build targets (mobile .ipa/.apk vs web .html)
- Different deployment pipeline (App Store / Google Play vs Vercel)
- Different release cadence (app store reviews add latency; game updates can't wait on web deploys)
- Different dependency sets (game engine packages vs web-optimized packages)
- Shared backend (same Supabase project, same API keys — just different client)

The two repos share:
- Supabase project (same URL, same anon key, same service role key)
- N.O.R.A. Platforms REST API (licensing verification, profile data, spotlight)
- Data models (the Dart classes can be copy-synced or extracted into a shared package)

---

## Tech Stack Recommendation

### V1: Flutter Mobile (recommended for launch)

**Rationale**: The existing codebase is Flutter. The team already knows Dart.
Flame (the Flutter game engine) handles 2D Pokemon-style games well when paired
with proper sprite assets and a dedicated art pipeline. Flutter compiles to native
iOS and Android. The visual ceiling is high enough for a compelling V1 — the
bottleneck has been web rendering constraints, not Flutter's capability.

V1 tech:
- **Flutter** (Dart) — iOS + Android from one codebase
- **Flame engine** — sprite sheets, animations, game loop
- **Lottie** — ability and effect animations
- **Rive** — character idle animations (superior to Lottie for looping; add this in Repo B)
- **Firebase Cloud Messaging** — push notifications (battle invites, vote results)
- **RevenueCat** — in-app purchases (Battle Chits, token packs) handling both App Store and Play Store

### V2: Unity (post-launch, when game revenue justifies it)

Unity is the right tool if the battle game needs 3D environments, real-time lighting,
cinematic camera work, or physics-based combat animations. If the app gains traction
and the team wants to invest in a premium V2, the data layer (Supabase REST/Realtime)
is engine-agnostic — the backend stays identical.

**For now: build V1 in Flutter. Design the data communication layer to be
engine-agnostic so V2 migration is a frontend swap, not a backend rebuild.**

---

## What to REMOVE from Repo A (nora-platforms web app)

The following should be removed from the Flutter web app after the mobile app
is confirmed working. Do NOT remove them prematurely.

### Flutter Screens to Remove
- `lib/features/battle/screens/battle_lobby_screen.dart`
- `lib/features/battle/screens/battle_match_screen.dart`
- `lib/features/arena/screens/arena_lobby_screen.dart`
- `lib/features/arena/screens/arena_match_screen.dart`

### Routes to Remove from lib/router.dart
- `/battle`
- `/battle/:matchId`
- `/arena`
- `/arena/:matchId`

### Providers to Remove (ONLY if not used by any remaining web screen)
- All providers under `lib/features/battle/providers/`
- All providers under `lib/features/arena/providers/` EXCEPT:
  - Any provider that feeds the Home screen Spotlight
  - Any provider used by the Markets feature

### What to ADD to web app in place of removed screens

Replace `/arena` with a redirect or a lightweight "Available on mobile" page:
```dart
GoRoute(path: '/arena',
  builder: (_, __) => const ArenaRedirectScreen()),  // "Play in the NORA Arena app"
GoRoute(path: '/battle',
  builder: (_, __) => const BattleRedirectScreen()), // "Battle on mobile"
```

These redirect screens should:
- Display the app store badges (App Store / Google Play)
- Show a QR code linking to the app download
- Link the user's existing account ("Your account works in both apps")

---

## What to KEEP in Repo A

### Supabase Backend (everything stays)
- All battle_* tables and their data
- All arena_* tables
- All edge functions (battle-tick-warmer, process_battle_turn, arena-tick, etc.)
- All pg_cron jobs related to battle and arena
- The stat sheet tables (creator_stat_sheets) — used by both apps
- The likeness card tables — used by both apps
- Battle Chit tables — used by both apps

### Flutter Code to Keep in Repo A
- `lib/models/` — all data models (copy to Repo B as well; keep in sync)
- Any provider that feeds non-battle web screens (Spotlight, Markets, etc.)
- The wallet/token balance screens
- The profile screens (public profile still shows stats on web)
- All marketplace screens (new from doc5)
- The Emergency Fund screens
- The Spotlight display on HomeScreen (reads arena_spotlight_assignments)

### API Endpoints to Expose for Repo B

Add a new section to `supabase/functions/` for mobile-specific API endpoints.
These are thin wrappers that aggregate data Repo B needs:

```
nora-arena-api-profile      — returns user profile + stat sheet + license holdings
nora-arena-api-spotlight    — returns current Arena Champions + poll leaders
nora-arena-api-market       — returns Arena prediction market for a battle match
nora-arena-api-token-balance — returns current token balance for betting
```

These are not new data sources — they're convenience endpoints that avoid
Repo B needing multiple Supabase queries for a single screen load.

---

## Repo B — New Repository Setup

### Initial Repository Structure

```
nora-arena/
├── android/
├── ios/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── config/
│   │   ├── supabase_config.dart     -- same keys as web app
│   │   ├── nora_api_config.dart     -- api.noraplatforms.com config
│   │   └── theme.dart               -- same color theme as web app
│   ├── core/
│   │   ├── models/                  -- copied/synced from nora-platforms
│   │   ├── providers/               -- shared state management
│   │   └── services/
│   │       ├── supabase_service.dart
│   │       ├── nora_api_service.dart  -- calls licensing API
│   │       └── license_sync_service.dart
│   ├── features/
│   │   ├── auth/                    -- login (reuses Supabase auth, same session)
│   │   ├── license_sync/            -- license verification + character unlock
│   │   ├── character_select/        -- pick characters from owned licenses
│   │   ├── lobby/                   -- battle lobby (format, invite, team setup)
│   │   ├── battle/                  -- the game itself (Flame engine)
│   │   ├── arena/                   -- spectator prediction market view
│   │   └── profile/                 -- lightweight profile (links to web for full)
├── assets/
│   ├── battle/
│   │   ├── sprites/                 -- same naming convention as doc3 battle-spec
│   │   └── lottie/
│   └── ui/
├── pubspec.yaml
└── README.md
```

### pubspec.yaml Key Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  supabase_flutter: ^2.0.0           # same as web app
  riverpod: ^2.0.0                   # same as web app (NO codegen — CLAUDE.md rule)
  flame: ^1.18.0                     # game engine
  flame_riverpod: ^5.0.0             # Flame + Riverpod integration
  lottie: ^3.0.0                     # effect animations
  rive: ^0.13.0                      # character idle animations (new in mobile)
  firebase_core: ^3.0.0              # for FCM push notifications
  firebase_messaging: ^15.0.0        # push notifications
  purchases_flutter: ^7.0.0          # RevenueCat for IAP
  go_router: ^14.0.0                 # same routing library
  http: ^1.0.0                       # for N.O.R.A. API calls
  crypto: ^3.0.0                     # for license verification signature checking
  qr_flutter: ^4.0.0                 # QR codes for license sharing
```

---

## License Sync Feature (Critical Integration Test)

This is the feature that proves the licensing API works cross-platform.

### Flow

```
User on web app → buys Sabrina Carpenter license → gets license_id: LKN-2026-XXXX
     ↓
User opens Arena app → taps "Sync Licenses"
     ↓
Arena app calls: api.noraplatforms.com/v1/verify
  with licensee_nora_id = user.id, use_category = 'entertainment_game'
     ↓
N.O.R.A. returns: list of active game-use licenses for this user
     ↓
Arena app unlocks characters matching the licensed creators
     ↓
User sees Sabrina Carpenter available in character select
```

### LicenseSyncService

File: `lib/core/services/license_sync_service.dart`

```dart
class LicenseSyncService {
  final String _apiBase = 'https://api.noraplatforms.com/v1';
  final String _apiKey;  // stored in app config, not hardcoded

  Future<List<UnlockedCharacter>> syncLicensesForUser(String noraUserId) async {
    final response = await http.get(
      Uri.parse('$_apiBase/licenses/user/$noraUserId?use_category=entertainment_game'),
      headers: {'X-NORA-API-Key': _apiKey},
    );

    if (response.statusCode != 200) {
      // Hard Rule 8: log and return empty, never throw
      debugPrint('[LicenseSync] API error: ${response.statusCode}');
      return [];
    }

    final data = jsonDecode(response.body) as List;
    return data
      .where((l) => l['license_status'] == 'active' && l['use_category_permitted'] == true)
      .map((l) => UnlockedCharacter.fromLicenseJson(l))
      .toList();
  }

  // Verify a specific license (called before battle start)
  Future<bool> verifyLicenseForBattle(String licenseId) async {
    final response = await http.get(
      Uri.parse('$_apiBase/verify?license_id=$licenseId&use_category=entertainment_game'),
      headers: {'X-NORA-API-Key': _apiKey},
    );
    if (response.statusCode != 200) return false;
    final data = jsonDecode(response.body);
    return data['license_status'] == 'active' && data['use_category_permitted'] == true;
  }
}
```

### User-Facing: LicenseSyncScreen

In the Arena app, accessible from the character select screen:

```
┌────────────────────────────────────────┐
│  Your Licensed Characters              │
│                                        │
│  [Sync with N.O.R.A. Platforms]        │
│                                        │
│  ✓ Sabrina Carpenter                   │
│    License: LKN-2026-A4X9B2CQ         │
│    Valid until: Jan 1, 2027            │
│    → Use in Battle                     │
│                                        │
│  + Browse more on N.O.R.A. Platforms   │
│    [Opens web browser to /licenses]    │
└────────────────────────────────────────┘
```

The "Browse more" button opens `noraplatforms.com/licenses` in the system browser.
When the user purchases a new license on the web, they return to the app and
tap "Sync" to refresh their character list.

---

## Battle Game Architecture (Repo B)

### Flame Game Structure

The battle game is a Flame `FlameGame` that renders the 2v2 or 3v3 battle.
Unlike the web version which was embedded in Flutter widget tree constraints,
the mobile version gets the full screen.

File: `lib/features/battle/game/arena_battle_game.dart`

```dart
class ArenaBattleGame extends FlameGame with HasCollisionDetection, KeyboardEvents {
  final String matchId;
  final SupabaseClient supabase;

  // Game components
  late BattleArena arena;        // the map background (Flame SpriteComponent)
  late List<CharacterSprite> teamOneSprites;
  late List<CharacterSprite> teamTwoSprites;
  late BattleHUD hud;            // health bars, AP, momentum — Flutter overlay
  late BattleEventStream eventStream;  // subscribes to battle_events Realtime

  @override
  Future<void> onLoad() async {
    // Load the battle map from battle_maps table
    // Load sprites for all participants using asset naming from doc3:
    // assets/battle/sprites/[archetype]_[state].png
    // Load Lottie effects for abilities
    // Subscribe to battle_events Realtime channel
  }
}
```

### Visual Design Principles for Mobile

These are non-negotiable design targets. If an asset or animation cannot meet
these standards, delay the feature rather than ship a low-quality version:

1. **Characters**: Full-screen sprite sheets at 512x512px minimum.
   Idle animations at 24fps. Attack animations at 30fps. KO animations must
   feel impactful (screen shake + particle effect).

2. **Backgrounds**: Each battle map has a parallax layered background (3 layers:
   far, mid, near). Static background is unacceptable for mobile.

3. **Ability effects**: Lottie JSON animations overlaid on sprite layer.
   Each ability has a unique visual signature — no reused animations.

4. **Battle Chit activation**: Full-screen flash + distinctive sound effect +
   unique animation. Chits are rare and should feel cinematic.

5. **UI overlays**: Health bars, AP meters, momentum bar — all using Flutter
   overlays (via Flame's `overlays` system) so they remain sharp at any DPI.
   Use the app theme (#0A0A0F background, #6C63FF primary, #03DAC6 secondary).

6. **Frame rate target**: 60fps on mid-range devices. Profile with Flutter
   DevTools before shipping. Drop Lottie layer complexity before dropping frames.

### CharacterSprite Component

```dart
class CharacterSprite extends SpriteAnimationGroupComponent<CharacterState> {
  final String archetype;
  final String characterName;
  final Map<String, dynamic> stats;  // from creator_stat_sheets

  // States from doc3 battle-spec: idle, attack, defend, hit, ko, victory
  @override
  Future<void> onLoad() async {
    // Load animations from assets/battle/sprites/[archetype]_[state].png
    // Use SpriteAnimationData.fromJson with the companion .json file
    // Apply stat-based visual modifiers:
    //   high Power stat → slightly larger sprite (1.0–1.15x scale)
    //   high Charisma → golden particle aura at idle
    //   high Influence → crowd cheer sound effect on ability use
  }
}
```

---

## Arena Spectator Mode (Prediction Market in Mobile)

The Arena prediction market is NOT a separate game. It is a read/bet overlay
on an ongoing Battle. In the mobile app, it appears as a bottom sheet that slides
up while the battle plays in the background.

### Arena Spectator Bottom Sheet

When a battle is live, users who are NOT participants can:
- Watch the battle in real-time (same Flame game view, controls disabled)
- See the Arena prediction pools (from `markets` table linked via `battle_match_id`)
- Place bets using their token balance
- See the live score and time remaining

This is data already in Supabase. The mobile app just subscribes to:
- `battle_events` Realtime (for game visuals)
- `arena_state` Realtime (for score)
- `markets` table (for bet pools)

No new backend work needed for this feature.

---

## Cross-App Communication Architecture

```
nora-platforms (web)                    nora-arena (mobile)
─────────────────────                   ─────────────────────
[Licensing Marketplace]  ───API──────→  [License Sync Screen]
[User Profile]           ───API──────→  [Profile Mini-Card]
[Spotlight/Poll Data]    ───API──────→  [Discover Tab]
[Token Balance]          ──Supabase──→  [Wallet for Betting]

Shared Supabase Project (same database, different Flutter clients):
- battle_matches        ──Realtime──→  [Battle Game Screen]
- arena_state           ──Realtime──→  [Score Display]
- markets               ──Realtime──→  [Arena Bet Pools]
- creator_stat_sheets   ──REST──────→  [Character Stats]
- likeness_cards        ──REST──────→  [Character Unlock Check]
- token_balances        ──REST──────→  [Betting Balance]
```

### Auth Sharing Between Apps

Both apps use the same Supabase project. The user logs in once; their session
JWT is valid in both. On mobile, the user logs in with the same email/password.
No separate account creation needed.

In the Arena app's auth screen, add a note:
"Use the same account as N.O.R.A. Platforms. Your licenses, tokens, and profile
sync automatically."

---

## Shared Data Models (Keep in Sync)

These Dart models must be identical between Repo A and Repo B.
Consider extracting them to a shared Dart package (`nora_shared`) on pub.dev
or a private GitHub package as a future step. For now, copy them manually and
add a comment: `// SHARED MODEL — keep in sync with nora-platforms/lib/models/`

Models to copy into `lib/core/models/` in Repo B:
- `BattleMatch`
- `BattleParticipant`
- `BattleEvent`
- `ArenaState`
- `Market` (for Arena betting)
- `Bet`
- `StatSheet`
- `EligibleCharacter`
- `LikenessCard`
- `BattleChit`

---

## Push Notifications (Firebase Cloud Messaging)

Repo B requires FCM. Repo A (web) does not currently have this.

Add to Repo B:
1. Firebase project (or add to existing if one exists)
2. `firebase_messaging` Flutter package
3. FCM token stored in `profiles.fcm_token_mobile` (new column, added to web repo)

Notifications needed for Arena app:
- "A battle is starting — your character is in it" (for owners)
- "You've been invited to a battle lobby"
- "Your bet resolved — you won X tokens"
- "Your character's license was synced successfully"
- "New character available to license on N.O.R.A. Platforms"

Add to web repo as migration 114 (runs after doc5's 108–113):
```sql
ALTER TABLE profiles ADD COLUMN fcm_token_mobile TEXT;
```

---

## In-App Purchases (RevenueCat)

Battle Chits and token packs are purchasable in the mobile app via RevenueCat,
which handles both App Store and Google Play billing.

RevenueCat products to configure:
- `chit_pack_common` — 5 Common Chits
- `chit_pack_rare` — 1 Rare Chit + 2 Common Chits
- `tokens_starter` — 100 tokens ($0.99)
- `tokens_popular` — 500 tokens ($4.99)
- `tokens_pro` — 1200 tokens ($9.99)
- `tokens_elite` — 2500 tokens ($19.99)

On purchase confirmation from RevenueCat:
- Call N.O.R.A. Supabase function `mobile_iap_confirm(product_id, purchase_token)`
- This function credits tokens or chits to the user's account
- Same `token_transactions` table as web purchases

---

## Deployment Pipeline

### Repo B CI/CD
- GitHub Actions (same as standard Flutter mobile)
- On push to `main`: run `flutter analyze` + `flutter test`
- On tag `v*`: build iOS (.ipa) + Android (.aab), deploy to TestFlight + Google Play Internal

### App Store Listing Notes
- Name: "N.O.R.A. Arena"
- Subtitle: "Battle, Bet, Collect"
- Category: Games → Strategy
- Age rating: 12+ (cartoon violence, simulated gambling/prediction markets — check store guidelines)
- Must disclose in-app purchases in listing

### Linking Both Apps
- Deep link from web app: `noraplatforms.com/arena` → App Store / Play Store
- Universal link: `nora.app/arena/:matchId` opens directly in Arena app (future)
- QR code on web Spotlight section links to App Store

---

## CLAUDE.md Addendum for Repo B

Create a `CLAUDE.md` in the root of `nora-arena/`:

```markdown
# NORA Arena — CLAUDE.md

## Parent App
This app shares a Supabase backend with nora-platforms.
Web repo: arunernorainvestments-cmd/nora-platforms
Supabase ref: cceisywxwhgljdpisjrl (same project)
N.O.R.A. API: api.noraplatforms.com

## Hard Rules (same as nora-platforms plus these)
1. Plain Riverpod only — no codegen, no @riverpod (same as web app)
2. NO database schema changes in this repo. All migrations live in nora-platforms.
3. NO new Supabase edge functions in this repo. All edge functions live in nora-platforms.
4. License verification always uses api.noraplatforms.com/v1/verify — never bypass.
5. Shared models must match nora-platforms exactly — add SHARED MODEL comment.
6. Frame rate target: 60fps on mid-range devices. Profile before shipping.
7. flutter analyze zero issues before every commit.

## Tech Stack
Flutter mobile (iOS + Android). Flame engine. Riverpod state management.
Firebase Cloud Messaging. RevenueCat for IAP.
Same Supabase project as web. Same anon key.

## Theme
Same as web: bg #0A0A0F | surface #1A1A2E | primary #6C63FF | secondary #03DAC6

## Asset Naming (same as doc3 battle-spec.md)
assets/battle/sprites/[archetype]_[state].png + .json
assets/battle/lottie/[archetype]_ability_[slot].json
assets/battle/lottie/system_[event].json
```

---

## Migration Checklist (Sequential — do not skip steps)

### Phase 1 — Repo B Foundation
- [ ] Create `nora-arena` GitHub repository
- [ ] Run `flutter create --platforms ios,android nora-arena`
- [ ] Add pubspec.yaml dependencies (see above)
- [ ] Configure Supabase with same project keys as Repo A
- [ ] Copy shared models from Repo A
- [ ] Add CLAUDE.md to Repo B root
- [ ] `flutter analyze` zero issues on empty project

### Phase 2 — License Sync (the integration test)
- [ ] Implement `LicenseSyncService` calling api.noraplatforms.com/v1/verify
- [ ] Build `LicenseSyncScreen` showing unlocked characters
- [ ] Verify that a license purchased on web app appears in mobile app after sync
- [ ] Verify expired/revoked licenses do NOT appear
- [ ] `check_battle_eligibility` RPC called before battle start (from Repo A)

### Phase 3 — Character Select & Lobby
- [ ] `get_eligible_characters` RPC returns correct characters
- [ ] Character select UI shows stat sheets from `creator_stat_sheets`
- [ ] Battle lobby shows format selector (1v1, 2v2, 3v3)
- [ ] Lobby code sharing works on mobile (share sheet)
- [ ] Ownership-gated characters are locked without license

### Phase 4 — Battle Game (Flame)
- [ ] Blank Flame game renders at 60fps on target device
- [ ] CharacterSprite loads from `assets/battle/sprites/` correctly
- [ ] `battle_events` Realtime subscription drives animation state changes
- [ ] Ability activation triggers Lottie overlay animation
- [ ] Battle Chit activation plays full-screen flash animation
- [ ] KO animation + screen shake working
- [ ] HUD overlay (health, AP, momentum) renders sharply at all DPIs
- [ ] `process_battle_turn` called from Supabase edge functions (not from app)
  — app is display-only; all game logic runs server-side

### Phase 5 — Arena Spectator
- [ ] Non-participant can watch live battle in read-only mode
- [ ] Arena bet pool bottom sheet slides up from battle screen
- [ ] Token balance displayed correctly from `token_balances`
- [ ] Bet placed via existing `arena_back` RPC
- [ ] Arena resolution notification fires when battle ends

### Phase 6 — Polish & Launch Prep
- [ ] Remove Battle/Arena screens from Repo A (after Phase 4 confirmed working)
- [ ] Add redirect screens to Repo A at /arena and /battle
- [ ] `fcm_token_mobile` column added to profiles (via Repo A migration)
- [ ] Push notifications working for battle invites and bet resolution
- [ ] RevenueCat IAP working for token packs
- [ ] App Store and Google Play submissions ready
- [ ] Deep link from noraplatforms.com/arena → App Store page

---

## Known Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Flame performance on low-end devices | Profile early; reduce particle count before reducing frame rate |
| Supabase Realtime latency on mobile (cellular) | Implement optimistic UI; show last known state while reconnecting |
| App store rejection for simulated betting | Clearly label "prediction markets" as entertainment in store listing; ensure no real money gambling flow |
| License API downtime blocks character select | Cache last-known license list locally (24-hour TTL); allow cached unlocks if API unreachable |
| Shared models drifting between Repo A and B | Add lint check comparing model files; or extract to shared package in V2 |
| RevenueCat IAP conflicts with Stripe web purchases | Ensure token credit functions are idempotent (ON CONFLICT DO NOTHING) |
