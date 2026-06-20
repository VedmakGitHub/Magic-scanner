import 'dart:typed_data';

import '../data/config.dart';
import 'phash.dart';

/// In-memory nearest-neighbour matcher over the reference hashes (Section 5.2).
///
/// All M reference hashes (M ~ tens of thousands, a few hundred KB) are held in
/// memory. A query is matched by a linear popcount scan — no ANN index needed
/// for Phase 1 (well under ~10 ms on a mid-range phone).
class HashMatch {
  final int index; // row index into the reference arrays
  final int distance; // Hamming distance
  const HashMatch(this.index, this.distance);
}

class Matcher {
  /// Parallel arrays, one entry per reference hash row.
  final Int64List _hashes;
  final List<String?> illustrationIds;
  final List<String> scryfallIds;
  final List<String> faces;

  Matcher._(this._hashes, this.illustrationIds, this.scryfallIds, this.faces);

  int get length => _hashes.length;

  factory Matcher.fromRows(List<Map<String, Object?>> rows) {
    final n = rows.length;
    final hashes = Int64List(n);
    final ill = List<String?>.filled(n, null);
    final sid = List<String>.filled(n, '');
    final faces = List<String>.filled(n, 'front');
    for (var i = 0; i < n; i++) {
      final r = rows[i];
      hashes[i] = (r['phash'] as num).toInt();
      ill[i] = r['illustration_id'] as String?;
      sid[i] = (r['scryfall_id'] as String?) ?? '';
      faces[i] = (r['face'] as String?) ?? 'front';
    }
    return Matcher._(hashes, ill, sid, faces);
  }

  /// Return the [k] lowest-distance matches to [queryHash], ascending distance.
  List<HashMatch> topK(int queryHash, {int k = AppConfig.topK}) {
    // Maintain a small sorted list of the best k (k is tiny, so insertion sort
    // beats sorting the whole array).
    final best = <HashMatch>[];
    for (var i = 0; i < _hashes.length; i++) {
      final d = _hamming(queryHash ^ _hashes[i]);
      if (best.length < k) {
        _insertSorted(best, HashMatch(i, d));
      } else if (d < best.last.distance) {
        best.removeLast();
        _insertSorted(best, HashMatch(i, d));
      }
    }
    return best;
  }

  static void _insertSorted(List<HashMatch> list, HashMatch m) {
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].distance <= m.distance) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    list.insert(lo, m);
  }

  /// popcount of a 64-bit value. SWAR-free but unrolled-ish; called ~M times per
  /// query, fine for M in the tens of thousands.
  static int _hamming(int x) {
    var v = x;
    var count = 0;
    while (v != 0) {
      v &= v - 1; // clear lowest set bit
      count++;
    }
    return count;
  }
}

/// Confidence classification for the candidate UI (Section 5.2).
enum MatchConfidence { strong, ambiguous, weak }

MatchConfidence classify(List<HashMatch> top) {
  if (top.isEmpty) return MatchConfidence.weak;
  final best = top.first.distance;
  if (best > AppConfig.weakMatchMinDistance) return MatchConfidence.weak;
  if (top.length >= 2 && (top[1].distance - best) <= 2) {
    return MatchConfidence.ambiguous;
  }
  if (best <= AppConfig.strongMatchMaxDistance) return MatchConfidence.strong;
  return MatchConfidence.ambiguous;
}

/// Re-export so callers can reuse the same popcount on raw ints.
int hamming(int a, int b) => hammingDistance(a, b);
