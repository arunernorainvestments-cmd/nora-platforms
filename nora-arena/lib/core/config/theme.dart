import 'package:flutter/material.dart';

/// Identical palette to nora-platforms (CLAUDE.md theme).
class NoraColors {
  static const bg = Color(0xFF0A0A0F);
  static const surface = Color(0xFF1A1A2E);
  static const primary = Color(0xFF6C63FF);
  static const secondary = Color(0xFF03DAC6);
  static const success = Color(0xFF00C896);
  static const danger = Color(0xFFFF4757);
}

ThemeData buildNoraTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: NoraColors.primary,
    brightness: Brightness.dark,
    surface: NoraColors.surface,
  ).copyWith(
    primary: NoraColors.primary,
    secondary: NoraColors.secondary,
    error: NoraColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NoraColors.bg,
    fontFamily: 'Inter',
  );
}
