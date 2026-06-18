import 'package:flame/components.dart';

import '../../../../core/models/unlocked_character.dart';

/// A single fighter in the Flame world.
///
/// The LICENSED LIKENESS shows up here (ARCHITECTURE.md "likeness → character"):
///   • the body is the ARCHETYPE Rive rig (character.rigAsset), a state machine
///     with idle / attack / defend / hit / ko / victory inputs — one rig reused
///     for every imported creator.
///   • personalization from the imported license:
///       - portrait (character.portraitUrl) shown in the HUD card / VS-intro / KO
///       - stat-driven modifiers: Power → scale 1.0–1.15x, Charisma → aura,
///         Influence → crowd SFX (doc6 visual rules)
///       - name plate = character.displayName
///
/// Stubbed until the art pipeline lands. Swap [PositionComponent] for a
/// flame_rive `RiveComponent` (loaded from rigAsset) once rigs exist.
class CharacterRig extends PositionComponent {
  CharacterRig({required this.character}) : super(size: Vector2.all(128));

  final UnlockedCharacter character;

  /// Visual scale derived from Power (doc6): high Power → slightly larger sprite.
  double get statScale {
    final power = character.stats?.effectivePower ?? 50;
    return 1.0 + (power.clamp(0, 150) / 150) * 0.15;
  }

  @override
  Future<void> onLoad() async {
    scale = Vector2.all(statScale);
    // TODO(battle phase):
    //   final artboard = await loadArtboard(RiveFile.asset(character.rigAsset));
    //   final controller = StateMachineController.fromArtboard(artboard, 'Battle');
    //   add(RiveComponent(artboard: artboard, size: size));
    //   // map battle_events → controller.findInput<bool>('attack') etc.
  }

  /// Called by ArenaBattleGame when a battle_event for this fighter arrives.
  void applyState(String state) {
    // TODO(battle phase): drive the Rive state-machine input named [state].
  }
}
