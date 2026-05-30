import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'audio_interface.dart';

class BattleGame extends FlameGame {
  SpriteAnimationComponent? _playerCharacter;
  SpriteAnimationComponent? _opponentCharacter;
  final Map<String, SpriteAnimation> _playerAnims = {};

  Vector2? _originalPlayerPos;
  Vector2? _originalOpponentPos;

  double _shakeTimer = 0.0;
  double _shakeIntensity = 0.0;

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final stageRect = await _stageImageRect();

    // Load stationary animations
    for (final state in ['idle', 'basic_attack', 'heavy_attack', 'charging', 'battle_chit']) {
      _playerAnims[state] = await _loadAnimation('musician', 'back', state);
    }

    // Centering coordinates tuned for purple neon circle platform (bottom-left)
    // Enlarged from 250x250 to 300x300 for foreground depth perspective
    _originalPlayerPos = Vector2(
      stageRect.left + stageRect.width * 0.28,
      stageRect.top + stageRect.height * 0.79,
    );

    _playerCharacter = SpriteAnimationComponent(
      animation: _playerAnims['idle'],
      size: Vector2(300, 300),
      position: _originalPlayerPos!.clone(),
      anchor: Anchor.bottomCenter,
    );
    add(_playerCharacter!);

    // Opponent stands centered on the cyan platform (middle-right)
    _originalOpponentPos = Vector2(
      stageRect.left + stageRect.width * 0.775,
      stageRect.top + stageRect.height * 0.67,
    );

    _opponentCharacter = SpriteAnimationComponent(
      animation: await _loadAnimation('musician', 'front', 'idle'),
      size: Vector2(230, 230),
      position: _originalOpponentPos!.clone(),
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

  @override
  void update(double dt) {
    super.update(dt);

    // Apply screen shake vibration
    if (_shakeTimer > 0) {
      _shakeTimer -= dt;
      if (_shakeTimer <= 0) {
        _playerCharacter?.position = _originalPlayerPos!.clone();
        _opponentCharacter?.position = _originalOpponentPos!.clone();
      } else {
        final offset = Vector2(
          (math.sin(_shakeTimer * 60) * _shakeIntensity),
          (math.cos(_shakeTimer * 60) * _shakeIntensity),
        );
        _playerCharacter?.position = _originalPlayerPos! + offset;
        _opponentCharacter?.position = _originalOpponentPos! + offset;
      }
    }
  }

  // Trigger abilities with specific high-fidelity special effects
  void triggerAbility(int slot) {
    if (slot == 1) {
      // 1. Rhythm Hit
      _playOnce('basic_attack');
      // Spawn sine wave laser travelling to opponent
      Future.delayed(const Duration(milliseconds: 300), () {
        final start = _playerCharacter!.position - Vector2(0, 120);
        final end = _opponentCharacter!.position - Vector2(0, 100);
        add(SineWaveEffect(start, end, const Color(0xFF00FFCC)));
        
        // Trigger impact on target
        Future.delayed(const Duration(milliseconds: 400), () {
          triggerHitEffect(true);
        });
      });
    } else if (slot == 2) {
      // 2. Drop the Beat
      _playOnce('basic_attack');
      Future.delayed(const Duration(milliseconds: 200), () {
        // Multi-ripple effect + Screen shake
        final start = _playerCharacter!.position - Vector2(0, 120);
        add(RippleEffect(start, const Color(0xFFFF00AA)));
        _shake(0.6, 12);
        
        Future.delayed(const Duration(milliseconds: 300), () {
          triggerHitEffect(true);
        });
      });
    } else if (slot == 3) {
      // 3. Crowd Hype
      _playOnce('charging');
      // cheering rave fans crowd animate (passing game size for safety)
      add(CrowdHypeEffect(size));
    } else if (slot == 4) {
      // 4. Bass Drop
      _playOnce('heavy_attack');
      Future.delayed(const Duration(milliseconds: 400), () {
        // Giant bass soundwave ripples + intense Screen shake
        final start = _playerCharacter!.position - Vector2(0, 120);
        add(RippleEffect(start, const Color(0xFF00FFFF), isDoubleSize: true));
        _shake(0.8, 20);
        
        Future.delayed(const Duration(milliseconds: 300), () {
          triggerHitEffect(true);
        });
      });
    } else {
      // 5. Encore / Ultimate
      _playOnce('battle_chit');
      Future.delayed(const Duration(milliseconds: 400), () {
        triggerHitEffect(true);
      });
    }
  }

  void triggerChit() => _playOnce('battle_chit');

  void _playOnce(String state) {
    final anim = _playerAnims[state];
    if (anim == null || _playerCharacter == null) return;
    _playerCharacter!.animation = anim;
    _playerCharacter!.animationTicker?.reset();
    _playerCharacter!.animationTicker?.onComplete = () {
      _playerCharacter!.animation = _playerAnims['idle'];
    };
  }

  void _shake(double duration, double intensity) {
    _shakeTimer = duration;
    _shakeIntensity = intensity;
  }

  // Trigger hit visual/audio effects on character taking damage
  void triggerHitEffect(bool targetIsOpponent) {
    final target = targetIsOpponent ? _opponentCharacter : _playerCharacter;
    if (target == null) return;

    // 1. Flash character (blip)
    double elapsed = 0.0;
    Timer.periodic(const Duration(milliseconds: 50), (t) {
      elapsed += 0.05;
      target.opacity = target.opacity == 1.0 ? 0.2 : 1.0;
      if (elapsed >= 0.3) {
        t.cancel();
        target.opacity = 1.0;
      }
    });

    // 2. Play Web Audio synth whack sound effect (pokemon whack thud)
    _playSynthWhack();

    // 3. Spawn Neon Starburst Hit Marker at target center
    final targetCenter = target.position - Vector2(0, target.size.y / 2);
    add(HitMarkerEffect(targetCenter));
  }

  void _playSynthWhack() {
    playSynthWhack();
  }
}

// ── Sine Wave effect component for Rhythm Hit ────────────────────────────────
class SineWaveEffect extends PositionComponent {
  final Vector2 start;
  final Vector2 end;
  final Color color;
  double elapsed = 0.0;
  final double duration = 0.4;

  SineWaveEffect(this.start, this.end, this.color);

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);

    final progress = (elapsed / duration).clamp(0.0, 1.0);
    final paint = ui.Paint()
      ..color = color.withOpacity((1.0 - progress) * 0.8)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5);

    final path = ui.Path();
    final direction = end - start;
    final length = direction.length;
    final angle = math.atan2(direction.y, direction.x);

    canvas.save();
    canvas.translate(start.x, start.y);
    canvas.rotate(angle);

    final currentLength = length * progress;
    path.moveTo(0, 0);

    for (double x = 0; x <= currentLength; x += 5) {
      final y = math.sin((x / 30) - (elapsed * 30)) * 15;
      path.lineTo(x, y);
    }

    canvas.drawPath(path, paint);
    
    // Core white beam
    paint.color = const ui.Color(0xFFFFFFFF).withOpacity(1.0 - progress);
    paint.strokeWidth = 2;
    paint.maskFilter = null;
    canvas.drawPath(path, paint);

    canvas.restore();
  }

  @override
  void update(double dt) {
    super.update(dt);
    elapsed += dt;
    if (elapsed >= duration) {
      removeFromParent();
    }
  }
}

// ── Rippling soundwave visual effect ──────────────────────────────────────────
class RippleEffect extends PositionComponent {
  final Vector2 center;
  final Color color;
  final bool isDoubleSize;
  double elapsed = 0.0;
  final double duration = 0.5;

  RippleEffect(this.center, this.color, {this.isDoubleSize = false});

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    final progress = elapsed / duration;
    final maxRadius = isDoubleSize ? 350.0 : 180.0;
    final currentRadius = maxRadius * progress;
    
    final paint = ui.Paint()
      ..color = color.withOpacity((1.0 - progress) * 0.6)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = isDoubleSize ? 6 : 3
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4);

    canvas.drawCircle(center.toOffset(), currentRadius, paint);
    
    // Inner pulsing ring
    if (progress > 0.3) {
      paint.color = color.withOpacity((1.0 - progress) * 0.3);
      canvas.drawCircle(center.toOffset(), currentRadius * 0.6, paint);
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    elapsed += dt;
    if (elapsed >= duration) {
      removeFromParent();
    }
  }
}

// ── Starburst Hit Marker visual effect ────────────────────────────────────────
class HitMarkerEffect extends PositionComponent {
  final Vector2 center;
  double elapsed = 0.0;
  final double duration = 0.25;

  HitMarkerEffect(this.center);

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    final progress = elapsed / duration;
    
    final paint = ui.Paint()
      ..color = const ui.Color(0xFFFFCC00).withOpacity(1.0 - progress)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 4
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);

    final size = 45.0 * progress;
    
    // Draw starburst crosses
    canvas.drawLine(
      Offset(center.x - size, center.y),
      Offset(center.x + size, center.y),
      paint,
    );
    canvas.drawLine(
      Offset(center.x, center.y - size),
      Offset(center.x, center.y + size),
      paint,
    );
    
    paint.color = const ui.Color(0xFFFFFFFF).withOpacity(1.0 - progress);
    paint.strokeWidth = 2;
    canvas.drawLine(
      Offset(center.x - size * 0.7, center.y - size * 0.7),
      Offset(center.x + size * 0.7, center.y + size * 0.7),
      paint,
    );
    canvas.drawLine(
      Offset(center.x - size * 0.7, center.y + size * 0.7),
      Offset(center.x + size * 0.7, center.y - size * 0.7),
      paint,
    );
  }

  @override
  void update(double dt) {
    super.update(dt);
    elapsed += dt;
    if (elapsed >= duration) {
      removeFromParent();
    }
  }
}

// ── Rave fans Crowd Hype cheering effect ──────────────────────────────────────
class CrowdHypeEffect extends PositionComponent {
  final Vector2 screenSize;
  double elapsed = 0.0;
  final double duration = 2.0;

  CrowdHypeEffect(this.screenSize);

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    
    final sizeX = screenSize.x;
    final sizeY = screenSize.y;

    // Slide in from left/right and meet in the center
    // Slide in for 0.5s, stay and bounce for 1.0s, slide out for 0.5s
    double slideOffset = 0.0;
    if (elapsed < 0.5) {
      slideOffset = (1.0 - (elapsed / 0.5)) * (sizeX * 0.4);
    } else if (elapsed > 1.5) {
      slideOffset = ((elapsed - 1.5) / 0.5) * (sizeX * 0.4);
    }

    final bounce = math.sin(elapsed * 25) * 8;
    
    // Draw cheering rave fan silhouettes with glowing sticks
    final paint = ui.Paint()
      ..color = const ui.Color(0xDD0C0C14)
      ..style = ui.PaintingStyle.fill;

    // Draw left crowd
    final leftPath = ui.Path();
    final startL = -slideOffset;
    leftPath.moveTo(startL, sizeY);
    leftPath.lineTo(startL + sizeX * 0.45, sizeY);
    leftPath.quadraticBezierTo(startL + sizeX * 0.35, sizeY - 90 + bounce, startL + sizeX * 0.25, sizeY - 70 + bounce);
    leftPath.cubicTo(startL + sizeX * 0.2, sizeY - 110 + bounce, startL + sizeX * 0.1, sizeY - 80 + bounce, startL, sizeY - 60);
    leftPath.close();
    canvas.drawPath(leftPath, paint);

    // Draw right crowd
    final rightPath = ui.Path();
    final startR = sizeX + slideOffset;
    rightPath.moveTo(startR, sizeY);
    rightPath.lineTo(startR - sizeX * 0.45, sizeY);
    rightPath.quadraticBezierTo(startR - sizeX * 0.35, sizeY - 90 - bounce, startR - sizeX * 0.25, sizeY - 70 - bounce);
    rightPath.cubicTo(startR - sizeX * 0.2, sizeY - 110 - bounce, startR - sizeX * 0.1, sizeY - 80 - bounce, startR, sizeY - 60);
    rightPath.close();
    canvas.drawPath(rightPath, paint);

    // Glowsticks paint
    final stickPaint = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);

    // Waving cyan and magenta glowsticks
    final stickL1 = Offset(startL + sizeX * 0.2, sizeY - 120 + bounce);
    final stickL2 = Offset(startL + sizeX * 0.1, sizeY - 95 + bounce);
    final stickR1 = Offset(startR - sizeX * 0.2, sizeY - 120 - bounce);
    final stickR2 = Offset(startR - sizeX * 0.1, sizeY - 95 - bounce);

    stickPaint.color = const ui.Color(0xFF00FFFF);
    canvas.drawLine(stickL1, Offset(stickL1.dx + 10, stickL1.dy - 30), stickPaint);
    canvas.drawLine(stickR1, Offset(stickR1.dx - 10, stickR1.dy - 30), stickPaint);

    stickPaint.color = const ui.Color(0xFFFF00AA);
    canvas.drawLine(stickL2, Offset(stickL2.dx - 15, stickL2.dy - 25), stickPaint);
    canvas.drawLine(stickR2, Offset(stickR2.dx + 15, stickR2.dy - 25), stickPaint);
  }

  @override
  void update(double dt) {
    super.update(dt);
    elapsed += dt;
    if (elapsed >= duration) {
      removeFromParent();
    }
  }
}
