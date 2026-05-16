import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Brand colors
  static const Color primary = Color(0xFF6C63FF);
  static const Color secondary = Color(0xFF03DAC6);
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF1A1A2E);
  static const Color surfaceLight = Color(0xFF16213E);
  static const Color accent = Color(0xFF6C63FF);
  static const Color success = Color(0xFF00C896);
  static const Color danger = Color(0xFFFF4757);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8B8FA8);
  static const Color cardBorder = Color(0xFF2A2A3E);

  // Depth tokens
  static const Color cardGradientTop = Color(0xFF1E1E34);
  static const Color cardGradientBottom = Color(0xFF13131F);

  static List<BoxShadow> cardShadow({Color? glow}) => [
        BoxShadow(
          color: (glow ?? primary).withValues(alpha: 0.07),
          blurRadius: 24,
          offset: const Offset(0, 8),
          spreadRadius: -4,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get glowShadow => [
        BoxShadow(
          color: primary.withValues(alpha: 0.22),
          blurRadius: 32,
          spreadRadius: -4,
        ),
      ];

  static ThemeData get darkTheme {
    final textTheme = GoogleFonts.interTextTheme(
      const TextTheme(
        displayLarge: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
        displayMedium:
            TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textSecondary),
        labelLarge:
            TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: secondary,
        surface: surface,
        error: danger,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.inter(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
        iconTheme: const IconThemeData(color: textPrimary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: cardGradientTop,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: primary.withValues(alpha: 0.15), width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          padding:
              const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textSecondary),
      ),
    );
  }
}
