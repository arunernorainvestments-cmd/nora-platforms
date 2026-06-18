import 'package:flame/components.dart';
import 'package:flame/game.dart';

import '../../../core/models/unlocked_character.dart';
import 'components/character_rig.dart';

/// The Flame battle world. App is DISPLAY-ONLY: all game logic runs server-side
/// (process_battle_turn edge function); this game renders state from the
/// `battle_events` Realtime stream. See ARCHITECTURE.md for the layer choices.
///
/// Recommended composition:
///   • parallax map background (3 layers) — Flame ParallaxComponent
///   • character rigs — Rive state machines (CharacterRig), one per fighter
///   • ability / chit FX — Lottie overlays triggered on battle_events
///   • HUD (health / AP / momentum) — Flutter widgets via game.overlays
class ArenaBattleGame extends FlameGame {
  ArenaBattleGame({required this.matchId, required this.roster});

  final String matchId;

  /// Imported fighters (from LicenseSyncService) placed into the match.
  final List<UnlockedCharacter> roster;

  @override
  Future<void> onLoad() async {
    // TODO(battle phase):
    //   1. Load battle_maps row for this match → ParallaxComponent (3 layers).
    //   2. For each roster entry, add a CharacterRig at its team slot.
    //   3. Subscribe to `battle_events` Realtime; drive rig state machines.
    //   4. Subscribe to `arena_state` Realtime for the spectator score overlay.
    //   5. Register HUD + Arena bet-sheet overlays.
    await _spawnRoster();
  }

  Future<void> _spawnRoster() async {
    for (var i = 0; i < roster.length; i++) {
      final rig = CharacterRig(character: roster[i])
        ..position = Vector2(120.0 + i * 160, size.y * 0.6);
      await add(rig);
    }
  }
}
