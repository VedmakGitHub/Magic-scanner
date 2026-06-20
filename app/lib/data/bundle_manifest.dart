/// The bundle manifest (Section 4.5).
class BundleManifest {
  final String bundleVersion;
  final String? scryfallUpdatedAt;
  final int cardCount;
  final int hashCount;
  final String sqliteSha256;
  final String sqliteUrl;
  final int sqliteGzipBytes;

  const BundleManifest({
    required this.bundleVersion,
    this.scryfallUpdatedAt,
    required this.cardCount,
    required this.hashCount,
    required this.sqliteSha256,
    required this.sqliteUrl,
    required this.sqliteGzipBytes,
  });

  factory BundleManifest.fromJson(Map<String, dynamic> j) {
    return BundleManifest(
      bundleVersion: j['bundle_version'].toString(),
      scryfallUpdatedAt: j['scryfall_updated_at']?.toString(),
      cardCount: (j['card_count'] as num?)?.toInt() ?? 0,
      hashCount: (j['hash_count'] as num?)?.toInt() ?? 0,
      sqliteSha256: (j['sqlite_sha256'] ?? '').toString(),
      sqliteUrl: (j['sqlite_url'] ?? '').toString(),
      sqliteGzipBytes: (j['sqlite_gzip_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}
