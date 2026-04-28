import 'package:flutter/material.dart';

class OrbWidget extends StatefulWidget {
  final double flowRate;
  final double totalFlow; // sum of both sides; used to compute relative size
  final Color color;
  final bool paused;

  const OrbWidget({
    super.key,
    required this.flowRate,
    required this.totalFlow,
    required this.color,
    this.paused = false,
  });

  @override
  State<OrbWidget> createState() => _OrbWidgetState();
}

class _OrbWidgetState extends State<OrbWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  static const double _baseSize = 100;
  static const double _maxDelta = 40; // max extra px when winning

  double _targetSize = _baseSize;
  double _displaySize = _baseSize;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _displaySize = _targetSize = _computeSize();
  }

  @override
  void didUpdateWidget(OrbWidget old) {
    super.didUpdateWidget(old);
    if (widget.paused != old.paused) {
      widget.paused ? _pulseCtrl.stop() : _pulseCtrl.repeat(reverse: true);
    }
    final newSize = _computeSize();
    if ((newSize - _targetSize).abs() > 0.5) {
      setState(() => _targetSize = newSize);
    }
  }

  double _computeSize() {
    if (widget.totalFlow == 0) return _baseSize;
    final fraction = widget.flowRate / widget.totalFlow;
    // fraction 0→1 maps to size 60→140 (centred around base 100)
    return (_baseSize - _maxDelta / 2) + fraction * _maxDelta;
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _displaySize, end: _targetSize),
      duration: const Duration(milliseconds: 3000),
      curve: Curves.easeInOut,
      onEnd: () => _displaySize = _targetSize,
      builder: (context, size, _) {
        return AnimatedBuilder(
          animation: _pulseAnim,
          builder: (context, _) {
            final scale = _pulseAnim.value;
            return SizedBox(
              width: size * scale,
              height: size * scale,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.3),
                    radius: 0.8,
                    colors: [
                      widget.color.withValues(alpha: 0.9),
                      widget.color.withValues(alpha: 0.4),
                      widget.color.withValues(alpha: 0.05),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.35),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
