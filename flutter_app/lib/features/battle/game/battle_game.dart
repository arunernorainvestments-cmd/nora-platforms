import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';

class BattleGame extends FlameGame {
  // Holds the active character so triggerAbility can control its animation.
  // Phase C: becomes a Map<String, SpriteAnimationComponent> keyed by team slot.
  SpriteAnimationComponent? _activeCharacter;

  @override
  Color backgroundColor() => const Color(0x00000000); // transparent — stage image is a Flutter widget behind GameWidget

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _activeCharacter = await _buildCharacter(
      'musician',
      'attack',
      position: () => Vector2(size.x * 0.455, size.y * 0.68),
    );
    add(_activeCharacter!);
  }

  Future<SpriteAnimationComponent> _buildCharacter(
    String archetype,
    String state, {
    required Vector2 Function() position,
  }) async {
    final imageBytes = await rootBundle.load(
      'assets/battle/sprites/${archetype}_$state.png',
    );
    final codec = await ui.instantiateImageCodec(imageBytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final jsonStr = await rootBundle.loadString(
      'assets/battle/sprites/${archetype}_$state.json',
    );
    final meta = json.decode(jsonStr) as Map<String, dynamic>;

    final animation = SpriteAnimation.fromFrameData(
      image,
      SpriteAnimationData.sequenced(
        amount: meta['frameCount'] as int,
        stepTime: 1.0 / (meta['fps'] as num).toDouble(),
        textureSize: Vector2(
          (meta['frameWidth'] as num).toDouble(),
          (meta['frameHeight'] as num).toDouble(),
        ),
        amountPerRow: 8,
      ),
    );

    return SpriteAnimationComponent(
      animation: animation,
      size: Vector2(200, 200),
      position: position(),
      anchor: Anchor.bottomCenter,
    );
  }

  // Resets the active character's animation to frame 0 so the button press
  // is visually obvious. Phase C: will swap idle → ability clip and revert
  // after animation_duration_ms from battle_abilities.
  void triggerAbility(int slot) {
    _activeCharacter?.animationTicker?.reset();
  }
}
