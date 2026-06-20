import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scan-screen preferences (the Settings modal). Persisted across launches.
class ScanSettings {
  /// Quick mode ON = auto-add the newest printing on a confident scan; OFF =
  /// pause and show the horizontal version row to pick the exact printing.
  final bool quickMode;
  final String? lockedSetCode; // when set, adds resolve to this set
  final bool ignorePromos;
  final bool preferFoil;
  final bool playSounds;
  final bool displayTotalValue;

  const ScanSettings({
    this.quickMode = true,
    this.lockedSetCode,
    this.ignorePromos = false,
    this.preferFoil = false,
    this.playSounds = true,
    this.displayTotalValue = false,
  });

  static const _sentinel = Object();

  ScanSettings copyWith({
    bool? quickMode,
    Object? lockedSetCode = _sentinel, // pass null to clear
    bool? ignorePromos,
    bool? preferFoil,
    bool? playSounds,
    bool? displayTotalValue,
  }) =>
      ScanSettings(
        quickMode: quickMode ?? this.quickMode,
        lockedSetCode: identical(lockedSetCode, _sentinel)
            ? this.lockedSetCode
            : lockedSetCode as String?,
        ignorePromos: ignorePromos ?? this.ignorePromos,
        preferFoil: preferFoil ?? this.preferFoil,
        playSounds: playSounds ?? this.playSounds,
        displayTotalValue: displayTotalValue ?? this.displayTotalValue,
      );

  Map<String, Object?> toJson() => {
        'quickMode': quickMode,
        'lockedSetCode': lockedSetCode,
        'ignorePromos': ignorePromos,
        'preferFoil': preferFoil,
        'playSounds': playSounds,
        'displayTotalValue': displayTotalValue,
      };

  factory ScanSettings.fromJson(Map<String, Object?> j) => ScanSettings(
        quickMode: j['quickMode'] as bool? ?? true,
        lockedSetCode: j['lockedSetCode'] as String?,
        ignorePromos: j['ignorePromos'] as bool? ?? false,
        preferFoil: j['preferFoil'] as bool? ?? false,
        playSounds: j['playSounds'] as bool? ?? true,
        displayTotalValue: j['displayTotalValue'] as bool? ?? false,
      );
}

class ScanSettingsController extends StateNotifier<ScanSettings> {
  ScanSettingsController() : super(const ScanSettings()) {
    _load();
  }

  static const _key = 'scan_settings_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        state = ScanSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
      } catch (_) {/* keep defaults */}
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.toJson()));
  }

  void update(ScanSettings next) {
    state = next;
    _save();
  }

  void setQuickMode(bool v) => update(state.copyWith(quickMode: v));
  void setLockedSet(String? code) => update(state.copyWith(lockedSetCode: code));
  void setIgnorePromos(bool v) => update(state.copyWith(ignorePromos: v));
  void setPreferFoil(bool v) => update(state.copyWith(preferFoil: v));
  void setPlaySounds(bool v) => update(state.copyWith(playSounds: v));
  void setDisplayTotalValue(bool v) =>
      update(state.copyWith(displayTotalValue: v));
}

final scanSettingsProvider =
    StateNotifierProvider<ScanSettingsController, ScanSettings>(
        (ref) => ScanSettingsController());
