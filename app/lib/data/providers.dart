import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../recognition/matcher.dart';
import '../recognition/recognition_service.dart';
import 'bundle_loader.dart';
import 'card_database.dart';
import 'collection_database.dart';
import 'models.dart';

/// Single bundle loader instance.
final bundleLoaderProvider = Provider<BundleLoader>((ref) => BundleLoader());

/// Drives the first-launch / update flow (Section 8.1) and holds its status.
class BundleController extends StateNotifier<BundleStatus> {
  final Ref ref;
  BundleController(this.ref)
      : super(const BundleStatus(phase: BundlePhase.idle)) {
    start();
  }

  Future<void> start({bool forceCheck = false}) async {
    final loader = ref.read(bundleLoaderProvider);
    await loader.ensureBundle((s) => state = s, forceCheck: forceCheck);
  }

  /// Settings "check for card data update" (Section 4.5). Reopens DB + matcher
  /// if a new bundle was installed.
  Future<void> checkForUpdate() async {
    final before = state.bundleVersion;
    await start(forceCheck: true);
    if (state.isReady && state.bundleVersion != before) {
      ref.invalidate(cardDatabaseProvider);
      ref.invalidate(matcherProvider);
      ref.invalidate(recognitionServiceProvider);
    }
  }
}

final bundleControllerProvider =
    StateNotifierProvider<BundleController, BundleStatus>(
        (ref) => BundleController(ref));

/// Read-only bundle DB (opens once the bundle file exists).
final cardDatabaseProvider = FutureProvider<CardDatabase>((ref) async {
  final loader = ref.watch(bundleLoaderProvider);
  final path = await loader.bundleDbPath();
  final db = await CardDatabase.open(path);
  ref.onDispose(db.close);
  return db;
});

/// Read-write collection DB (separate file, survives bundle refresh).
final collectionDatabaseProvider =
    FutureProvider<CollectionDatabase>((ref) async {
  final loader = ref.watch(bundleLoaderProvider);
  final path = await loader.collectionDbPath();
  final db = await CollectionDatabase.open(path);
  ref.onDispose(db.close);
  return db;
});

/// In-memory matcher built from the bundle's `hashes` table (Section 5.2).
final matcherProvider = FutureProvider<Matcher>((ref) async {
  final db = await ref.watch(cardDatabaseProvider.future);
  final rows = await db.loadAllHashes();
  final m = Matcher.fromRows(rows);
  debugPrint('Loaded ${m.length} reference hashes');
  return m;
});

final recognitionServiceProvider =
    FutureProvider<RecognitionService>((ref) async {
  final db = await ref.watch(cardDatabaseProvider.future);
  final matcher = await ref.watch(matcherProvider.future);
  return RecognitionService(db, matcher);
});

/// The collection list with resolved printings, plus mutation methods.
class CollectionController
    extends StateNotifier<AsyncValue<List<CollectionEntry>>> {
  final Ref ref;
  CollectionController(this.ref) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final col = await ref.read(collectionDatabaseProvider.future);
      final cards = await ref.read(cardDatabaseProvider.future);
      final rows = await col.all();
      final ids = rows.map((r) => r['scryfall_id'] as String);
      final printings = await cards.getPrintingsByIds(ids);
      final entries = rows.map((r) {
        final sid = r['scryfall_id'] as String;
        return CollectionEntry(
          id: r['id'] as int,
          scryfallId: sid,
          finish: r['finish'] as String,
          quantity: r['quantity'] as int,
          addedAt: r['added_at'] as String,
          printing: printings[sid],
        );
      }).toList();
      state = AsyncValue.data(entries);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> add(String scryfallId, String finish, {int qty = 1}) async {
    final col = await ref.read(collectionDatabaseProvider.future);
    await col.add(scryfallId, finish, qty: qty);
    await load();
  }

  Future<void> setQuantity(int id, int quantity) async {
    final col = await ref.read(collectionDatabaseProvider.future);
    await col.setQuantity(id, quantity);
    await load();
  }

  Future<void> remove(int id) async {
    final col = await ref.read(collectionDatabaseProvider.future);
    await col.delete(id);
    await load();
  }
}

final collectionControllerProvider = StateNotifierProvider<CollectionController,
    AsyncValue<List<CollectionEntry>>>((ref) => CollectionController(ref));
