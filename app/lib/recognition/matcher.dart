import 'dart:typed_data';

import '../data/config.dart';
import 'phash.dart';

/// In-memory nearest-neighbour matcher over the reference hashes (Section 5.2).
///
/// Each reference hash is 256 bits, stored column-wise as four Int64List words
/// for fast popcount. M ~ 50k entries => ~1.6 MB, trivial. A query is matched by
/// a linear popcount scan (well under ~10 ms on a mid-range phone).
class HashMatch {
  final int index; // row index into the reference arrays
  final int distance; // Hamming distance (0..256)
  const HashMatch(this.index, this.distance);
}

class Matcher {
  // Four 64-bit words per reference hash, column-major for cache-friendly scan.
  final Int64List _w0, _w1, _w2, _w3;
  final List<String?> illustrationIds;
  final List<String> scryfallIds;
  final List<String> faces;

  Matcher._(this._w0, this._w1, this._w2, this._w3, this.illustrationIds,
      this.scryfallIds, this.faces);

  int get length => _w0.length;

  factory Matcher.fromRows(List<Map<String, Object?>> rows) {
    final n = rows.length;
    final w0 = Int64List(n), w1 = Int64List(n), w2 = Int64List(n), w3 = Int64List(n);
    final ill = List<String?>.filled(n, null);
    final sid = List<String>.filled(n, '');
    final faces = List<String>.filled(n, 'front');
    for (var i = 0; i < n; i++) {
      final r = rows[i];
      final blob = r['phash'] as Uint8List;
      final words = PerceptualHash.toWords(blob);
      w0[i] = words[0];
      w1[i] = words[1];
      w2[i] = words[2];
      w3[i] = words[3];
      ill[i] = r['illustration_id'] as String?;
      sid[i] = (r['scryfall_id'] as String?) ?? '';
      faces[i] = (r['face'] as String?) ?? 'front';
    }
    return Matcher._(w0, w1, w2, w3, ill, sid, faces);
  }

  /// Return the [k] lowest-distance matches to [query] (a 256-bit hash blob),
  /// ascending distance.
  List<HashMatch> topK(Uint8List query, {int k = AppConfig.topK}) {
    final q = PerceptualHash.toWords(query);
    final q0 = q[0], q1 = q[1], q2 = q[2], q3 = q[3];
    final best = <HashMatch>[];
    for (var i = 0; i < _w0.length; i++) {
      final d = _popcount(q0 ^ _w0[i]) +
          _popcount(q1 ^ _w1[i]) +
          _popcount(q2 ^ _w2[i]) +
          _popcount(q3 ^ _w3[i]);
      if (best.length < k) {
        _insertSorted(best, HashMatch(i, d));
      } else if (d < best.last.distance) {
        best.removeLast();
        _insertSorted(best, HashMatch(i, d));
      }
    }
    return best;
  }

  /// Multi-scale top-K: each reference's distance is the MIN over the query's
  /// inset hashes, so the inset that strips the sleeve margin wins. [queries]
  /// are the 256-bit hash blobs from `PerceptualHash.multiScale`.
  List<HashMatch> topKMulti(List<Uint8List> queries, {int k = AppConfig.topK}) {
    final qs = [for (final q in queries) PerceptualHash.toWords(q)];
    final n = qs.length;
    final best = <HashMatch>[];
    for (var i = 0; i < _w0.length; i++) {
      final r0 = _w0[i], r1 = _w1[i], r2 = _w2[i], r3 = _w3[i];
      var d = 257;
      for (var j = 0; j < n; j++) {
        final q = qs[j];
        final dd = _popcount(q[0] ^ r0) +
            _popcount(q[1] ^ r1) +
            _popcount(q[2] ^ r2) +
            _popcount(q[3] ^ r3);
        if (dd < d) d = dd;
      }
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

  /// popcount of a 64-bit word (Kernighan; works on the signed representation).
  static int _popcount(int x) {
    var v = x;
    var count = 0;
    while (v != 0) {
      v &= v - 1; // clear lowest set bit
      count++;
    }
    return count;
  }
}

/// Confidence classification for the candidate UI (Section 5.2). Thresholds are
/// for the 256-bit hash and tuned against real-photo testing.
enum MatchConfidence { strong, ambiguous, weak }

MatchConfidence classify(List<HashMatch> top) {
  if (top.isEmpty) return MatchConfidence.weak;
  final best = top.first.distance;
  if (best > AppConfig.weakMatchMinDistance) return MatchConfidence.weak;
  if (top.length >= 2 && (top[1].distance - best) <= AppConfig.ambiguousGap) {
    return MatchConfidence.ambiguous;
  }
  if (best <= AppConfig.strongMatchMaxDistance) return MatchConfidence.strong;
  return MatchConfidence.ambiguous;
}
