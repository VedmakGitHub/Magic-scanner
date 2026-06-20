import 'package:flutter/material.dart';

/// App theme. Intentionally generic — no Wizards logos/trademarks in branding
/// or icons (Section 9).
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3A6EA5),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF121316),
    appBarTheme: const AppBarTheme(centerTitle: false),
  );
}
