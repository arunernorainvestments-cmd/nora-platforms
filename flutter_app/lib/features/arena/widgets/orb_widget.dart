import 'package:flutter/material.dart';
import '../models/active_effect.dart';

class OrbWidget extends StatefulWidget {
  final double flowRate;
  final double totalFlow;
  final Color color;
  final bool paused;
  final List<ActiveEffect> activeEffects;

  const OrbWidget({
    super.key,
    required this.flowRate,
    required this.totalFlow,
    required this.color,
    this.paused = false,
    this.activeEffects = const [],
  });

  @override
  State<OrbWidget> createState() => _OrbWidgetState();
}

class _OrbWidgetState extends State<OrbWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  static const double _baseSize = 100;
  static const double _maxDelta = 40;

  double _targetSize = _baseSize;
  double _displaySize = _baseSize;

  // Track previous active effects to detect new arrivals for flash animation
  List<String> _prevEffectIds = [];
  bool _flash = false;

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

    // Flash when a new non-passive effect arrives
    final newIds = widget.activeEffects
        .where((e) => !e.isPassive)
        .map((e) => e.effectId)
        .toList();
    final hasNew = newIds.any((id) => !_prevEffectIds.contains(id));
    if (hasNew && !_flash) {
      setState(() => _flash = true);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) setState(() => _flash = false);
      });
    }
    _prevEffectIds = newIds;
  }

  double _computeSize() {
    if (widget.totalFlow == 0) return _baseSize;
    final fraction = widget.flowRate / widget.totalFlow;
    return (_baseSize - _maxDelta / 2) + fraction * _maxDelta;
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Non-passive trigger effects shown as small badges (max 4)
    final triggerEffects =
        widget.activeEffects.where((e) => !e.isPassive).take(4).toList();
    final extraCount =
        widget.activeEffects.where((e) => !e.isPassive).length - 4;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _displaySize, end: _targetSize),
      duration: const Duration(milliseconds: 3000),
      curve: Curves.easeInOut,
      onEnd: () => _displaySize = _targetSize,
      builder: (context, size, _) {
        return SizedBox(
          width: size + 32,  // extra room for badges
          height: size + 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Flash overlay
              if (_flash)
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: _flash ? 0.3 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color,
                      ),
                    ),
                  ),
                ),

              // Orb
              AnimatedBuilder(
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
              ),

              // Active effect badges (corner region, bottom-right)
              if (triggerEffects.isNotEmpty)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ...triggerEffects.map(
                        (e) => _EffectBadge(effect: e, color: widget.color),
                      ),
                      if (extraCount > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: widget.color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '+$extraCount',
                            style: TextStyle(
                              color: widget.color,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EffectBadge extends StatefulWidget {
  final ActiveEffect effect;
  final Color color;
  const _EffectBadge({required this.effect, required this.color});

  @override
  State<_EffectBadge> createState() => _EffectBadgeState();
}

class _EffectBadgeState extends State<_EffectBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..forward();
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _remainingLabel() {
    final r = widget.effect.remaining;
    if (r == Duration.zero) return '';
    return '${r.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _remainingLabel().isEmpty
              ? '⚡'
              : '⚡${_remainingLabel()}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
