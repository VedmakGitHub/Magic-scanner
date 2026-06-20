import 'package:flutter/services.dart';

/// Lightweight scan feedback: a haptic tick plus an optional system click on a
/// successful add. Dependency-free (no audio asset to ship); the click is gated
/// by the Play-sounds setting.
class ScanFeedback {
  const ScanFeedback._();

  static void added({required bool sound}) {
    HapticFeedback.lightImpact();
    if (sound) SystemSound.play(SystemSoundType.click);
  }
}
