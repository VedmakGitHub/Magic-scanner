/// App-wide constants and the data-bundle endpoints (Sections 0.2, 4.5, 9).
class AppConfig {
  AppConfig._();

  static const appName = 'MTGScanner';
  static const appVersion = '0.1.0';

  /// A specific User-Agent is REQUIRED on all Scryfall requests (Section 9, 4.2).
  static const userAgent = '$appName/$appVersion (Android; Phase1 MVP)';

  /// Fixed-tag GitHub Release manifest URL (Section 0.2). Replace <owner>/<repo>.
  /// This is a direct asset-download URL, so it never hits the rate-limited
  /// api.github.com.
  static const manifestUrl =
      'https://github.com/VedmakGitHub/Magic-scanner/releases/download/data-bundle/manifest.json';

  /// Scryfall image CDN base (Section 4.6).
  static const scryfallImageBase = 'https://cards.scryfall.io';

  /// Filenames in the app documents dir.
  static const bundleDbFileName = 'cards.sqlite';
  static const collectionDbFileName = 'collection.sqlite';
  static const bundleVersionKey = 'bundle_version';

  /// Matching thresholds (Section 5.2) — tune during acceptance testing.
  static const int strongMatchMaxDistance = 10;
  static const int weakMatchMinDistance = 18;
  static const int topK = 5;
}
