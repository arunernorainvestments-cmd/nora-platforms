import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:nora_platforms/core/theme/app_theme.dart';

/// Glassmorphism bottom sheet container.
/// Wraps content with backdrop blur, translucent surface, and a top-edge
/// highlight border. Drop in as a direct replacement for solid surface containers.
class NGlassSheet extends StatelessWidget {
  final Widget child;
  final double topRadius;
  final EdgeInsetsGeometry? padding;

  const NGlassSheet({
    super.key,
    required this.child,
    this.topRadius = 24,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(top: Radius.circular(topRadius));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surface.withValues(alpha: 0.88),
            borderRadius: radius,
            border: Border(
              top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08), width: 1),
              left: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08), width: 1),
              right: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08), width: 1),
            ),
          ),
          child: padding != null
              ? Padding(padding: padding!, child: child)
              : child,
        ),
      ),
    );
  }
}

/// Consistent drag handle for all bottom sheets.
class NSheetHandle extends StatelessWidget {
  const NSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
