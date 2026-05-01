import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/active_effect.dart';

// Phase B: repurposed from empty stubs to per-player active effect indicators.
// Two slots per player: P1 slots on the left, P2 slots on the right.
// When no effects are active the slot renders as a dim placeholder.

class ActiveEffectSlotRow extends StatelessWidget {
  final List<ActiveEffect> effectsP1;
  final List<ActiveEffect> effectsP2;

  const ActiveEffectSlotRow({
    super.key,
    required this.effectsP1,
    required this.effectsP2,
  });

  @override
  Widget build(BuildContext context) {
    // Show up to 2 non-passive effects per player in the slots
    final p1 = effectsP1.where((e) => !e.isPassive).take(2).toList();
    final p2 = effectsP2.where((e) => !e.isPassive).take(2).toList();
    final p1Extra = effectsP1.where((e) => !e.isPassive).length - 2;
    final p2Extra = effectsP2.where((e) => !e.isPassive).length - 2;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _Slot(effect: p1.isNotEmpty ? p1[0] : null, color: AppTheme.primary),
        _Slot(
          effect: p1.length > 1 ? p1[1] : null,
          color: AppTheme.primary,
          extraCount: p1Extra > 0 ? p1Extra : 0,
        ),
        _Slot(
          effect: p2.isNotEmpty ? p2[0] : null,
          color: AppTheme.secondary,
          extraCount: p2Extra > 0 ? p2Extra : 0,
        ),
        _Slot(effect: p2.length > 1 ? p2[1] : null, color: AppTheme.secondary),
      ],
    );
  }
}

class _Slot extends StatefulWidget {
  final ActiveEffect? effect;
  final Color color;
  final int extraCount;

  const _Slot({this.effect, required this.color, this.extraCount = 0});

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  String? _prevEffectId;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    if (widget.effect != null) _ctrl.value = 1.0;
  }

  @override
  void didUpdateWidget(_Slot old) {
    super.didUpdateWidget(old);
    if (widget.effect?.effectId != _prevEffectId) {
      if (widget.effect != null) {
        _ctrl.forward(from: 0);
      } else {
        _ctrl.reverse();
      }
      _prevEffectId = widget.effect?.effectId;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _remainingLabel() {
    final r = widget.effect?.remaining ?? Duration.zero;
    if (r == Duration.zero) return '';
    return '${r.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.effect != null;
    return ScaleTransition(
      scale: active ? _scale : const AlwaysStoppedAnimation(1.0),
      child: AnimatedOpacity(
        opacity: active ? 1.0 : 0.3,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? widget.color.withValues(alpha: 0.5)
                  : AppTheme.cardBorder,
              width: 1.5,
            ),
            color: active
                ? widget.color.withValues(alpha: 0.12)
                : AppTheme.surface.withValues(alpha: 0.5),
          ),
          child: active
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.flash_on, color: widget.color, size: 16),
                    if (_remainingLabel().isNotEmpty)
                      Text(
                        _remainingLabel(),
                        style: TextStyle(
                          color: widget.color,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (widget.extraCount > 0)
                      Text(
                        '+${widget.extraCount}',
                        style: TextStyle(
                          color: widget.color.withValues(alpha: 0.7),
                          fontSize: 7,
                        ),
                      ),
                  ],
                )
              : const Icon(
                  Icons.bolt_outlined,
                  color: AppTheme.textSecondary,
                  size: 18,
                ),
        ),
      ),
    );
  }
}
