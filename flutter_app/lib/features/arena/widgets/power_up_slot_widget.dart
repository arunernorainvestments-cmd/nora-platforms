import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

// Phase A: empty stub slots. Wired to abilities in Phase B.
class PowerUpSlotWidget extends StatelessWidget {
  const PowerUpSlotWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: 0.35,
      duration: const Duration(milliseconds: 300),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppTheme.cardBorder,
            width: 1.5,
          ),
          color: AppTheme.surface.withValues(alpha: 0.5),
        ),
        child: const Icon(
          Icons.bolt_outlined,
          color: AppTheme.textSecondary,
          size: 18,
        ),
      ),
    );
  }
}
