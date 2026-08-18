import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bundle_manifest.dart';
import 'config.dart';

enum BundlePhase { idle, checking, downloading, verifying, unpacking, ready, offlineReady, error }

/// Immutable status the UI renders (first-launch screen, Section 8.1).
class BundleStatus {
  final BundlePhase phase;
  final double progress; // 0..1 during download; -1 = indeterminate
  final String message;
  final String? bundleVersion;
  final Object? error;

  const BundleStatus({
    required this.phase,
    this.progress = -1,
    this.message = '',
    this.bundleVersion,
    this.error,
  });

  bool get isReady => phase == BundlePhase.ready || phase == BundlePhase.offlineReady;

  BundleStatus copyWith({
    BundlePhase? phase,
    double? progress,
    String? message,
    String? bundleVersion,
    Object? error,
  }) =>
      BundleStatus(
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        message: message ?? this.message,
        bundleVersion: bundleVersion ?? this.bundleVersion,
        error: error,
      );
}

/// Downloads, verifies, and unpacks the data bundle (Section 4.5).
///
/// First-launch flow: fetch manifest → if no local DB or bundle_version differs
/// → download cards.sqlite.gz → verify sha256 → gunzip into docs dir → ready.
/// Works offline thereafter; a settings action re-runs the same two fetches.
class BundleLoader {
  final Dio _dio;
  BundleLoader([Dio? dio]) : _dio = dio ?? Dio();

  Future<String> _docsDir() async =>
      (await getApplicationDocumentsDirectory()).path;

  Future<String> bundleDbPath() async =>
      p.join(await _docsDir(), AppConfig.bundleDbFileName);

  Future<String> collectionDbPath() async =>
      p.join(await _docsDir(), AppConfig.collectionDbFileName);

  File _versionFile(String dir) => File(p.join(dir, 'bundle_version.txt'));

  Future<String?> localBundleVersion() async {
    final f = _versionFile(await _docsDir());
    return f.existsSync() ? (await f.readAsString()).trim() : null;
  }

  Future<bool> hasLocalBundle() async => File(await bundleDbPath()).existsSync();

  /// Ensure a usable bundle exists, downloading/updating as needed.
  /// [onStatus] is called with progress updates.
  Future<BundleStatus> ensureBundle(
    void Function(BundleStatus) onStatus, {
    bool forceCheck = false,
  }) async {
    final dir = await _docsDir();
    final dbPath = await bundleDbPath();
    final localVersion = await localBundleVersion();
    final haveLocal = File(dbPath).existsSync();

    void emit(BundleStatus s) => onStatus(s);

    BundleManifest? manifest;
    try {
      emit(const BundleStatus(phase: BundlePhase.checking, message: 'Checking for card data…'));
      manifest = await _fetchManifest();
    } on Object catch (e) {
      // Offline: if we already have a bundle, proceed; otherwise surface error.
      if (haveLocal) {
        final s = BundleStatus(
          phase: BundlePhase.offlineReady,
          bundleVersion: localVersion,
          message: 'Offline — using cached card data',
        );
        emit(s);
        return s;
      }
      final s = BundleStatus(
        phase: BundlePhase.error,
        error: e,
        message: 'Could not reach the card-data server. Connect to the internet '
            'for the one-time download.',
      );
      emit(s);
      return s;
    }

    final upToDate = haveLocal && localVersion == manifest.bundleVersion && !forceCheck;
    if (upToDate) {
      final s = BundleStatus(
        phase: BundlePhase.ready,
        bundleVersion: localVersion,
        message: 'Card data up to date',
      );
      emit(s);
      return s;
    }
    if (haveLocal && localVersion == manifest.bundleVersion && forceCheck) {
      final s = BundleStatus(
        phase: BundlePhase.ready,
        bundleVersion: localVersion,
        message: 'Already up to date (v${manifest.bundleVersion})',
      );
      emit(s);
      return s;
    }

    // Download the gzipped bundle to a temp file.
    final gzPath = p.join(dir, 'cards.sqlite.gz.part');
    try {
      emit(const BundleStatus(
          phase: BundlePhase.downloading, progress: 0, message: 'Downloading card data…'));
      await _dio.download(
        manifest.sqliteUrl,
        gzPath,
        options: Options(headers: {'User-Agent': AppConfig.userAgent}),
        onReceiveProgress: (rec, total) {
          final prog = total > 0 ? rec / total : -1.0;
          emit(BundleStatus(
            phase: BundlePhase.downloading,
            progress: prog,
            message: 'Downloading card data…',
          ));
        },
      );

      emit(const BundleStatus(phase: BundlePhase.unpacking, message: 'Unpacking…'));
      final gzBytes = await File(gzPath).readAsBytes();
      final raw = GZipDecoder().decodeBytes(gzBytes);

      emit(const BundleStatus(phase: BundlePhase.verifying, message: 'Verifying…'));
      final digest = sha256.convert(raw).toString();
      if (manifest.sqliteSha256.isNotEmpty && digest != manifest.sqliteSha256) {
        throw StateError('SHA-256 mismatch: bundle download is corrupt.');
      }

      // Atomic-ish swap: write to .new, then rename over the live DB.
      final newPath = '$dbPath.new';
      await File(newPath).writeAsBytes(raw, flush: true);
      if (File(dbPath).existsSync()) await File(dbPath).delete();
      await File(newPath).rename(dbPath);
      await _versionFile(dir).writeAsString(manifest.bundleVersion);
      await File(gzPath).delete().catchError((_) => File(gzPath));

      final s = BundleStatus(
        phase: BundlePhase.ready,
        bundleVersion: manifest.bundleVersion,
        message: 'Card data ready (v${manifest.bundleVersion})',
      );
      emit(s);
      return s;
    } on Object catch (e) {
      // Clean up partial download; fall back to existing bundle if any.
      try {
        if (File(gzPath).existsSync()) await File(gzPath).delete();
      } catch (_) {}
      if (haveLocal) {
        final s = BundleStatus(
          phase: BundlePhase.offlineReady,
          bundleVersion: localVersion,
          message: 'Update failed — keeping current card data',
          error: e,
        );
        emit(s);
        return s;
      }
      final s = BundleStatus(
        phase: BundlePhase.error,
        error: e,
        message: 'Download failed: $e',
      );
      emit(s);
      return s;
    }
  }

  Future<BundleManifest> _fetchManifest() async {
    final resp = await _dio.get<String>(
      AppConfig.manifestUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'User-Agent': AppConfig.userAgent},
      ),
    );
    final body = resp.data ?? '';
    return BundleManifest.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }
}
