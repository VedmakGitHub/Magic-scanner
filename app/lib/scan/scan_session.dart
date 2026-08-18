import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';

/// One staged scan, before it is committed to the collection. Identical
/// (printing, finish, condition) scans merge by bumping [qty].
class ScanSessionItem {
  final int id; // stable within the session, survives edits
  final Printing printing;
  final String finish;
  final Condition condition;
  final int qty;
  final DateTime addedAt;
  final int distance; // recognition Hamming distance (0 for manual adds)

  const ScanSessionItem({
    required this.id,
    required this.printing,
    required this.finish,
    this.condition = Condition.nm,
    this.qty = 1,
    required this.addedAt,
    this.distance = 0,
  });

  ScanSessionItem copyWith({
    Printing? printing,
    String? finish,
    Condition? condition,
    int? qty,
  }) =>
      ScanSessionItem(
        id: id,
        printing: printing ?? this.printing,
        finish: finish ?? this.finish,
        condition: condition ?? this.condition,
        qty: qty ?? this.qty,
        addedAt: addedAt,
        distance: distance,
      );
}

/// The transient staging area for scanned cards (the "N cards scanned" sheet).
/// "Add to" commits the batch to the collection; "Clear" discards it.
class ScanSessionController extends StateNotifier<List<ScanSessionItem>> {
  final Ref ref;
  ScanSessionController(this.ref) : super(const []);

  int _seq = 0;

  /// Total card count (sum of quantities) — drives the control-pill badge.
  int get totalCount => state.fold(0, (s, i) => s + i.qty);

  String _defaultFinish(Printing p) =>
      p.finishes.contains('nonfoil') ? 'nonfoil' : (p.finishes.isEmpty ? 'nonfoil' : p.finishes.first);

  /// Add a scan; merges into an existing identical row, else prepends a new one.
  ScanSessionItem add(
    Printing printing, {
    String? finish,
    Condition condition = Condition.nm,
    int qty = 1,
    int distance = 0,
  }) {
    final f = finish ?? _defaultFinish(printing);
    final idx = state.indexWhere((i) =>
        i.printing.scryfallId == printing.scryfallId &&
        i.finish == f &&
        i.condition == condition);
    if (idx >= 0) {
      final merged = state[idx].copyWith(qty: state[idx].qty + qty);
      state = [...state]..[idx] = merged;
      return merged;
    }
    final item = ScanSessionItem(
      id: _seq++,
      printing: printing,
      finish: f,
      condition: condition,
      qty: qty,
      addedAt: DateTime.now(),
      distance: distance,
    );
    state = [item, ...state];
    return item;
  }

  void update(int id,
      {Printing? printing, String? finish, Condition? condition, int? qty}) {
    state = [
      for (final i in state)
        if (i.id == id)
          i.copyWith(
              printing: printing, finish: finish, condition: condition, qty: qty)
        else
          i,
    ];
  }

  void remove(int id) => state = state.where((i) => i.id != id).toList();

  void clear() => state = const [];

  /// Commit every staged item to the collection, then clear the session.
  Future<void> commitToCollection() async {
    final col = await ref.read(collectionDatabaseProvider.future);
    for (final i in state) {
      await col.add(i.printing.scryfallId, i.finish,
          condition: i.condition.code, qty: i.qty);
    }
    clear();
    await ref.read(collectionControllerProvider.notifier).load();
  }
}

final scanSessionProvider =
    StateNotifierProvider<ScanSessionController, List<ScanSessionItem>>(
        (ref) => ScanSessionController(ref));
