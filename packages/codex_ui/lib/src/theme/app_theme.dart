import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Colors
  static const Color background = Color(0xFF19191C); // zinc-950
  static const Color textMain = Color(0xFFE4E4E7); // zinc-200
  static const Color textMuted = Color(0xFFA1A1AA); // zinc-400
  static const Color textSubtle = Color(0xFF71717A); // zinc-500

  // Accents
  static const Color emerald = Color(0xFF10B981); // emerald-500
  static const Color amber = Color(0xFFF59E0B); // amber-500
  static const Color rose = Color(0xFFF43F5E); // rose-500

  // Surface colors
  static const Color surfaceZinc100 = Color(
    0xFFF4F4F5,
  ); // zinc-100 (primary buttons)
  static const Color surfaceZinc800 = Color(0xFF27272A); // zinc-800
  static const Color surfaceZinc900 = Color(0xFF19191C); // zinc-900

  static ThemeData get darkTheme {
    final base = ThemeData.dark();
    // Default to Satoshi/Outfit-like sans serif. Inter is a solid modern alternative if Satoshi isn't bundled.
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).copyWith(
      bodyLarge: GoogleFonts.inter(color: textMain),
      bodyMedium: GoogleFonts.inter(color: textMain),
      displayLarge: GoogleFonts.inter(color: textMain, letterSpacing: -1.5),
      displayMedium: GoogleFonts.inter(color: textMain, letterSpacing: -0.5),
      displaySmall: GoogleFonts.inter(color: textMain),
      headlineMedium: GoogleFonts.inter(color: textMain, letterSpacing: -0.5),
      headlineSmall: GoogleFonts.inter(color: textMain),
      titleLarge: GoogleFonts.inter(color: textMain),
      titleMedium: GoogleFonts.inter(color: textMain),
      titleSmall: GoogleFonts.inter(color: textMain),
      labelLarge: GoogleFonts.inter(color: textMain),
      labelSmall: GoogleFonts.inter(color: textMain),
    );

    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: emerald,
        secondary: emerald,
        surface: background,
        error: rose,
        onPrimary: background,
        onSecondary: background,
        onSurface: textMain,
        onError: Colors.white,
      ),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
    );
  }

  // Mono style helper
  static TextStyle get monoTextStyle {
    return GoogleFonts.jetBrainsMono();
  }
}
