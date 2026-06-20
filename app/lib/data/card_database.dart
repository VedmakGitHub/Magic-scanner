import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Read-only access to the downloaded bundle DB `cards.sqlite` (Section 7).
///
/// Kept entirely separate from the collection DB so refreshing the bundle never
/// risks the user's collection (Section 7).
class CardDatabase {
  final Database _db;
  CardDatabase._(this._db);

  static Future<CardDatabase> open(String path) async {
    final db = await openReadOnlyDatabase(path);
    return CardDatabase._(db);
  }

  Future<void> close() => _db.close();

  /// Load every reference hash row for the in-memory matcher (Section 5.2).
  Future<List<Map<String, Object?>>> loadAllHashes() {
    return _db.query('hashes',
        columns: ['illustration_id', 'scryfall_id', 'face', 'phash']);
  }

  Future<int> hashCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM hashes')) ?? 0;

  Future<int> printingCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM printings')) ?? 0;

  Future<String?> bundleVersion() async {
    try {
      final rows = await _db.query('meta',
          where: 'key = ?', whereArgs: ['bundle_version'], limit: 1);
      return rows.isEmpty ? null : rows.first['value'] as String?;
    } catch (_) {
      return null; // older bundles may lack the meta table
    }
  }

  /// All printings that share an artwork — drives the version picker (Section 6, 7).
  /// Sorted by release date desc (newest first), nulls last.
  Future<List<Printing>> printingsByIllustration(String illustrationId) async {
    final rows = await _db.query(
      'printings',
      where: 'illustration_id = ?',
      whereArgs: [illustrationId],
      orderBy: 'released_at IS NULL, released_at DESC',
    );
    return rows.map(Printing.fromRow).toList();
  }

  /// A single representative printing for a recognition candidate (front face).
  Future<Printing?> representativeForIllustration(String illustrationId) async {
    final list = await printingsByIllustration(illustrationId);
    if (list.isEmpty) return null;
    // Prefer a front face if present.
    return list.firstWhere((p) => p.face == 'front', orElse: () => list.first);
  }

  /// Look up an exact printing (front face used for display in the collection).
  Future<Printing?> getPrinting(String scryfallId, {String face = 'front'}) async {
    var rows = await _db.query('printings',
        where: 'scryfall_id = ? AND face = ?',
        whereArgs: [scryfallId, face],
        limit: 1);
    if (rows.isEmpty) {
      rows = await _db.query('printings',
          where: 'scryfall_id = ?', whereArgs: [scryfallId], limit: 1);
    }
    return rows.isEmpty ? null : Printing.fromRow(rows.first);
  }

  /// Resolve many printings at once (collection list). Returns front faces.
  Future<Map<String, Printing>> getPrintingsByIds(Iterable<String> ids) async {
    final unique = ids.toSet().toList();
    final out = <String, Printing>{};
    const chunk = 400; // stay under SQLite variable limits
    for (var i = 0; i < unique.length; i += chunk) {
      final part = unique.sublist(i, (i + chunk).clamp(0, unique.length));
      final placeholders = List.filled(part.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT * FROM printings WHERE scryfall_id IN ($placeholders)',
        part,
      );
      for (final r in rows) {
        final p = Printing.fromRow(r);
        // Prefer the front face when both faces exist.
        final existing = out[p.scryfallId];
        if (existing == null || (existing.face != 'front' && p.face == 'front')) {
          out[p.scryfallId] = p;
        }
      }
    }
    return out;
  }

  /// Every printing of a CARD (across all artworks, sets and languages) — drives
  /// the version row/grid. Queries by `name` (indexed) and returns front faces
  /// newest-first; optionally narrows to a single `oracleId` to disambiguate the
  /// rare same-name/different-card case. Group with [groupCardVersions].
  Future<List<Printing>> printingsForCard(String name, {String? oracleId}) async {
    final rows = await _db.query(
      'printings',
      where: "name = ? AND face = 'front'",
      whereArgs: [name],
      orderBy: 'released_at IS NULL, released_at DESC',
    );
    var list = rows.map(Printing.fromRow).toList();
    if (oracleId != null) {
      final narrowed = list.where((p) => p.oracleId == oracleId).toList();
      if (narrowed.isNotEmpty) list = narrowed;
    }
    return list;
  }

  /// Distinct sets matching a query — for the "Lock set" autocomplete (Section 8).
  Future<List<({String code, String name})>> setSearch(String query,
      {int limit = 30}) async {
    final q = '%${query.trim()}%';
    final rows = await _db.rawQuery(
      '''SELECT set_code, set_name FROM printings
         WHERE set_name LIKE ? OR set_code LIKE ?
         GROUP BY set_code
         ORDER BY set_name COLLATE NOCASE
         LIMIT ?''',
      [q, q, limit],
    );
    return rows
        .map((r) => (code: r['set_code'] as String, name: r['set_name'] as String))
        .toList();
  }

  /// Free-text search by name or set (Section 8, collection search). Returns one
  /// representative front-face printing per scryfall_id, name-ordered.
  Future<List<Printing>> search(String query, {int limit = 100}) async {
    final q = '%${query.trim()}%';
    final rows = await _db.rawQuery(
      '''SELECT * FROM printings
         WHERE (name LIKE ? OR set_name LIKE ? OR set_code LIKE ?)
           AND face = 'front'
         ORDER BY name COLLATE NOCASE
         LIMIT ?''',
      [q, q, q, limit],
    );
    return rows.map(Printing.fromRow).toList();
  }
}
