import 'package:sqflite/sqflite.dart';

/// Read-write collection store, in its own file so a bundle refresh can never
/// touch it (Section 7). Quantities are tracked per (printing, finish).
class CollectionDatabase {
  final Database _db;
  CollectionDatabase._(this._db);

  static Future<CollectionDatabase> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE collection_items (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            scryfall_id  TEXT NOT NULL,
            finish       TEXT NOT NULL,
            quantity     INTEGER NOT NULL DEFAULT 1,
            added_at     TEXT NOT NULL,
            UNIQUE(scryfall_id, finish)
          )
        ''');
      },
    );
    return CollectionDatabase._(db);
  }

  Future<void> close() => _db.close();

  /// Add one of (scryfall_id, finish), incrementing if it already exists
  /// (Section 6, step 8).
  Future<void> add(String scryfallId, String finish, {int qty = 1}) async {
    await _db.rawInsert(
      '''INSERT INTO collection_items (scryfall_id, finish, quantity, added_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(scryfall_id, finish)
         DO UPDATE SET quantity = quantity + excluded.quantity''',
      [scryfallId, finish, qty, DateTime.now().toUtc().toIso8601String()],
    );
  }

  Future<void> setQuantity(int id, int quantity) async {
    if (quantity <= 0) {
      await delete(id);
      return;
    }
    await _db.update('collection_items', {'quantity': quantity},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) async {
    await _db.delete('collection_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> all() {
    return _db.query('collection_items', orderBy: 'added_at DESC');
  }

  Future<int> totalCards() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COALESCE(SUM(quantity),0) FROM collection_items')) ??
      0;
}
