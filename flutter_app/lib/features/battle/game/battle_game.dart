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

    // Compute where BoxFit.contain places the stage image on this screen so
    // character positions are expressed as fractions of the stage image's
    // rendered bounds — not the full canvas. This keeps placement correct on
    // both desktop (letterbox on sides) and mobile (letterbox top/bottom).
    final stageRect = await _stageImageRect();

    _activeCharacter = await _buildCharacter(
      'musician',
      'attack',
      // (0.265, 0.71) = left platform center within the stage image.
      // Adjust these two fractions to fine-tune placement on all screens.
      position: () => Vector2(
        stageRect.left + stageRect.width * 0.265,
        stageRect.top + stageRect.height * 0.71,
      ),
    );
    add(_activeCharacter!);
  }

  // Loads the stage background image just to read its native dimensions, then
  // replicates Flutter's BoxFit.contain math to return the rendered rect.
  Future<Rect> _stageImageRect() async {
    final bytes = await rootBundle.load(
      'assets/battle/backgrounds/stage_01.png',
    );
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final aspect = img.width / img.height;
    img.dispose();
    return _containRect(aspect);
  }

  // Mirrors BoxFit.contain: fits the image inside the canvas, centred,
  // preserving aspect ratio.
  Rect _containRect(double imageAspect) {
    final screenAspect = size.x / size.y;
    if (screenAspect > imageAspect) {
      // Screen is wider than image — letterbox on left and right
      final w = size.y * imageAspect;
      return Rect.fromLTWH((size.x - w) / 2, 0, w, size.y);
    } else {
      // Screen is taller than image — letterbox on top and bottom
      final h = size.x / imageAspect;
      return Rect.fromLTWH(0, (size.y - h) / 2, size.x, h);
    }
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
      size: Vector2(250, 250),
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
