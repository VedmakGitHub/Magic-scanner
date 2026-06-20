import 'package:flutter/material.dart';

/// App theme. Intentionally generic — no Wizards logos/trademarks in branding
/// or icons (Section 9). Amber accent mirrors the ManaBox scan UI.
ThemeData buildTheme() {
  const accent = Color(0xFFFFA000); // ManaBox-style amber
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(primary: accent, onPrimary: Colors.black);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF121316),
    appBarTheme: const AppBarTheme(centerTitle: false),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: accent.withValues(alpha: 0.22),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? accent : Colors.white70),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          color: s.contains(WidgetState.selected) ? accent : Colors.white70,
        ),
      ),
    ),
  );
}
