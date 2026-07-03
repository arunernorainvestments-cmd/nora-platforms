import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import 'rocket_video.dart';

// Full-screen overlay played when the launch countdown hits zero:
// the rocket cutscene video if assets/video/launch_rocket.mp4 is bundled,
// otherwise a built-in animation of the NORA rocket lifting off.
// Calls [onFinished] when done (also reachable via the Skip button).
class LaunchSequenceOverlay extends StatefulWidget {
  final VoidCallback onFinished;

  const LaunchSequenceOverlay({super.key, required this.onFinished});

  @override
  State<LaunchSequenceOverlay> createState() => _LaunchSequenceOverlayState();
}

class _LaunchSequenceOverlayState extends State<LaunchSequenceOverlay> {
  bool _videoFailed = false;
  bool _finished = false;

  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_videoFailed)
            RocketVideo(
              onEnded: _finish,
              onUnavailable: () {
                if (mounted) setState(() => _videoFailed = true);
              },
            )
          else
            _FallbackRocketAnimation(onEnded: _finish),
          // "WE ARE LIVE" banner fades in over either variant.
          const _LiveBanner(),
          Positioned(
            right: 20,
            bottom: 20,
            child: SafeArea(
              child: TextButton(
                onPressed: _finish,
                child: Text(
                  'SKIP →',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBanner extends StatelessWidget {
  const _LiveBanner();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 900),
        curve: const Interval(0.55, 1, curve: Curves.easeOut),
        builder: (context, t, _) => Opacity(
          opacity: t,
          child: Align(
            alignment: const Alignment(0, -0.72),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'WE ARE LIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 6,
                    shadows: [
                      Shadow(
                        color: AppTheme.primary.withValues(alpha: 0.8),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'N.O.R.A. PLATFORMS · JULY 4, 2026',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fallback: a cinematic camera move over the NORA launch-pad scene (the same
// art as the landing background) — hold, shake, engine glow, zoom into the
// rocket, then the scene drops away through a star field and whites out.
// Used whenever the cutscene MP4 isn't bundled (or fails to load), so launch
// night still gets a moment even without the video asset.
// ─────────────────────────────────────────────────────────────────────────────

class _FallbackRocketAnimation extends StatefulWidget {
  final VoidCallback onEnded;
  const _FallbackRocketAnimation({required this.onEnded});

  @override
  State<_FallbackRocketAnimation> createState() =>
      _FallbackRocketAnimationState();
}

class _FallbackRocketAnimationState extends State<_FallbackRocketAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6000),
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onEnded();
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final size = MediaQuery.of(context).size;

        // Timeline: 0–0.3 hold + building shake · 0.3–0.75 zoom into the
        // rocket while the pad drops away · 0.75–1 white-out.
        final zoom = Curves.easeInCubic
            .transform(((t - 0.30) / 0.45).clamp(0.0, 1.0));
        final drop = Curves.easeInQuart
            .transform(((t - 0.45) / 0.55).clamp(0.0, 1.0));
        final whiteout = ((t - 0.78) / 0.22).clamp(0.0, 1.0);
        final shake = t < 0.45
            ? math.sin(t * 110) * 5 * ((t / 0.45).clamp(0.0, 1.0))
            : 0.0;

        return Stack(
          fit: StackFit.expand,
          children: [
            const _StarField(),
            // The pad scene: zooms toward the rocket, then falls off-screen.
            Transform.translate(
              offset: Offset(shake, size.height * 1.3 * drop),
              child: Transform.scale(
                scale: 1.0 + zoom * 0.6,
                alignment: const Alignment(0.0, -0.35), // toward the rocket
                child: Image.asset(
                  'assets/images/launch_bg.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Color(0xFF0E0B1F),
                    child: Center(
                      child: Icon(Icons.rocket_launch,
                          color: Colors.white, size: 140),
                    ),
                  ),
                ),
              ),
            ),
            // Engine glow flaring up from the bottom during ignition.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: size.height * 0.45,
              child: IgnorePointer(
                child: Opacity(
                  opacity:
                      ((t - 0.15) * 3).clamp(0.0, 1.0) * (1 - drop),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, 1.4),
                        radius: 1.3,
                        colors: [
                          const Color(0xFFFFB74D).withValues(alpha: 0.85),
                          const Color(0xFFFF7043).withValues(alpha: 0.35),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Final white-out before landing on /home.
            IgnorePointer(
              child: Opacity(
                opacity: whiteout,
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StarField extends StatelessWidget {
  const _StarField();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StarFieldPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _StarFieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF05050C), Color(0xFF0E0B1F)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    final rng = math.Random(7);
    final star = Paint()..color = Colors.white;
    for (var i = 0; i < 120; i++) {
      star.color =
          Colors.white.withValues(alpha: 0.25 + rng.nextDouble() * 0.6);
      canvas.drawCircle(
        Offset(rng.nextDouble() * size.width, rng.nextDouble() * size.height),
        rng.nextDouble() * 1.4 + 0.3,
        star,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
