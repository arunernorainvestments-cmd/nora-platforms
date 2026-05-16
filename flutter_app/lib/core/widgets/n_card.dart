import 'package:flutter/material.dart';
import 'package:nora_platforms/core/theme/app_theme.dart';
import 'package:nora_platforms/core/widgets/n_tappable.dart';

/// Emil Kowalski-inspired card with gradient depth, glow border,
/// colored shadow, and top-edge highlight.
///
/// Drop in as a direct replacement for Container + BoxDecoration card patterns.
/// Pass [accentColor] to tint the glow for avatar/brand-colored cards.
/// Pass [onTap] to automatically wrap with [NTappable] press physics.
class NCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color? accentColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const NCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = 16,
    this.accentColor,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final glow = accentColor ?? AppTheme.primary;

    Widget card = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.cardGradientTop, AppTheme.cardGradientBottom],
        ),
        border: Border.all(
          color: glow.withValues(alpha: 0.18),
          width: 1,
        ),
        boxShadow: AppTheme.cardShadow(glow: glow),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            // Top-edge highlight — Emil's signature depth layer
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: radius * 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            if (padding != null)
              Padding(padding: padding!, child: child)
            else
              child,
          ],
        ),
      ),
    );

    if (onTap != null || onLongPress != null) {
      return NTappable(
        onTap: onTap,
        onLongPress: onLongPress,
        child: card,
      );
    }
    return card;
  }
}
