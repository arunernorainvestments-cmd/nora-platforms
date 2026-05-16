import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';

class BattleGame extends FlameGame {
  SpriteAnimationComponent? _playerCharacter;
  SpriteAnimationComponent? _opponentCharacter;
  final Map<String, SpriteAnimation> _playerAnims = {};

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final stageRect = await _stageImageRect();

    for (final state in ['idle', 'basic_attack', 'heavy_attack', 'charging', 'battle_chit']) {
      _playerAnims[state] = await _loadAnimation('musician', 'back', state);
    }

    _playerCharacter = SpriteAnimationComponent(
      animation: _playerAnims['idle'],
      size: Vector2(250, 250),
      position: Vector2(
        stageRect.left + stageRect.width * 0.265,
        stageRect.top + stageRect.height * 0.71,
      ),
      anchor: Anchor.bottomCenter,
    );
    add(_playerCharacter!);

    _opponentCharacter = SpriteAnimationComponent(
      animation: await _loadAnimation('musician', 'front', 'idle'),
      size: Vector2(250, 250),
      position: Vector2(
        stageRect.left + stageRect.width * 0.735,
        stageRect.top + stageRect.height * 0.71,
      ),
      anchor: Anchor.bottomCenter,
    );
    add(_opponentCharacter!);
  }

  Future<Rect> _stageImageRect() async {
    final bytes = await rootBundle.load('assets/battle/backgrounds/stage_01.png');
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final aspect = img.width / img.height;
    img.dispose();
    return _containRect(aspect);
  }

  Rect _containRect(double imageAspect) {
    final screenAspect = size.x / size.y;
    if (screenAspect > imageAspect) {
      final w = size.y * imageAspect;
      return Rect.fromLTWH((size.x - w) / 2, 0, w, size.y);
    } else {
      final h = size.x / imageAspect;
      return Rect.fromLTWH(0, (size.y - h) / 2, size.x, h);
    }
  }

  Future<SpriteAnimation> _loadAnimation(
    String archetype,
    String perspective,
    String state,
  ) async {
    final key = '${archetype}_${perspective}_$state';
    final imageBytes = await rootBundle.load('assets/battle/sprites/$key.png');
    final codec = await ui.instantiateImageCodec(imageBytes.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final jsonStr = await rootBundle.loadString('assets/battle/sprites/$key.json');
    final meta = json.decode(jsonStr) as Map<String, dynamic>;

    final anim = SpriteAnimation.fromFrameData(
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
    anim.loop = state == 'idle';
    return anim;
  }

  // Slots 1–2 → basic_attack, 3–5 → heavy_attack.
  // Phase C: replace with battle_abilities.animation_key from DB.
  void triggerAbility(int slot) {
    _playOnce(slot <= 2 ? 'basic_attack' : 'heavy_attack');
  }

  void triggerChit() => _playOnce('battle_chit');

  void _playOnce(String state) {
    final anim = _playerAnims[state];
    if (anim == null || _playerCharacter == null) return;
    _playerCharacter!.animation = anim;
    _playerCharacter!.animationTicker?.onComplete = () {
      _playerCharacter!.animation = _playerAnims['idle'];
    };
  }
}
