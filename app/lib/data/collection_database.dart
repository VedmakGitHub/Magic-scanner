import 'package:sqflite/sqflite.dart';

/// Read-write collection store, in its own file so a bundle refresh can never
/// touch it (Section 7). Quantities are tracked per (printing, finish).
class CollectionDatabase {
  final Database _db;
  CollectionDatabase._(this._db);

  static Future<CollectionDatabase> open(String path) async {
    final db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute(_createV2);
      },
      onUpgrade: (db, oldV, newV) async {
        // v2 adds `condition` and widens the unique key to include it. SQLite
        // can't drop a table-level UNIQUE, so rebuild the table and copy rows.
        if (oldV < 2) {
          await db.execute(
              'ALTER TABLE collection_items RENAME TO collection_items_v1');
          await db.execute(_createV2);
          await db.execute('''
            INSERT INTO collection_items
              (id, scryfall_id, finish, condition, quantity, added_at)
            SELECT id, scryfall_id, finish, 'NM', quantity, added_at
            FROM collection_items_v1
          ''');
          await db.execute('DROP TABLE collection_items_v1');
        }
      },
    );
    return CollectionDatabase._(db);
  }

  static const _createV2 = '''
    CREATE TABLE collection_items (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      scryfall_id  TEXT NOT NULL,
      finish       TEXT NOT NULL,
      condition    TEXT NOT NULL DEFAULT 'NM',
      quantity     INTEGER NOT NULL DEFAULT 1,
      added_at     TEXT NOT NULL,
      UNIQUE(scryfall_id, finish, condition)
    )
  ''';

  Future<void> close() => _db.close();

  /// Add one of (scryfall_id, finish), incrementing if it already exists
  /// (Section 6, step 8).
  Future<void> add(String scryfallId, String finish,
      {String condition = 'NM', int qty = 1}) async {
    await _db.rawInsert(
      '''INSERT INTO collection_items
           (scryfall_id, finish, condition, quantity, added_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(scryfall_id, finish, condition)
         DO UPDATE SET quantity = quantity + excluded.quantity''',
      [
        scryfallId,
        finish,
        condition,
        qty,
        DateTime.now().toUtc().toIso8601String()
      ],
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
