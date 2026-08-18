import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_core/opencv.dart' as cv;
import 'package:sqflite/sqflite.dart';

/// One identification from the ORB local-feature matcher.
class OrbResult {
  final String illustrationId;
  final int inliers; // RANSAC inliers: the accept/reject evidence
  final int matches; // Lowe-ratio good matches
  final double bowScore;
  const OrbResult(this.illustrationId, this.inliers, this.matches, this.bowScore);
}

/// Two-stage local-feature matcher (the deep-fix descriptor).
///
/// Stage 1 retrieves a shortlist from a PREBUILT inverted index over binary
/// visual words; stage 2 re-ranks only those candidates with exact Hamming
/// matching plus a RANSAC homography. Measured offline against the shipped
/// index: 93.3% top-1 at N=50 over 50,747 cards, versus 59% for the pHash
/// descriptor on the same photos. See docs/ARCHITECTURE.md.
///
/// Geometric verification is what makes REJECTION possible: genuine matches
/// average ~30 inliers while impostors average ~0, so a threshold accepts 97%
/// of real cards and 0% of unknown ones.
class OrbMatcher {
  OrbMatcher._(this._db, this._vocab, this._idf, this._postCard, this._postWeight,
      this._wordOffset, this._illu, this._soft, this._nfeat, this._artBox,
      this._edge);

  final Database _db;
  final cv.Mat _vocab; // [K,32] packed binary centroids
  final Float32List _idf;
  final Int32List _postCard; // grouped by word
  final Float32List _postWeight;
  final Int32List _wordOffset; // K+1 slice bounds
  final List<String> _illu;
  final int _soft, _nfeat, _edge;
  final List<double> _artBox;

  /// Shortlist size. 10 was tuned on an 8k pool where recall had already
  /// saturated; on the real 50,747-card corpus it has not, so 50 buys ~1.4pp
  /// for cheap re-rank work. Past ~50 distractors start winning (see the sweep
  /// in docs/ARCHITECTURE.md).
  static const int shortlist = 50;
  static const double ratio = 0.75;

  /// Accept threshold on RANSAC inliers: at >=8, 97% of genuine matches are
  /// accepted and 0% of impostors.
  static const int minInliers = 8;

  /// Load from FILES beside the database, not sqlite BLOBs.
  ///
  /// Android caps a single query row at ~2 MB (CursorWindow), so sqflite cannot
  /// return the 2.1 MB vocabulary or the 57 MB posting arrays at all -- it
  /// throws "Row too big to fit into CursorWindow". Files have no such limit,
  /// load faster and can be mmapped later. `orb_desc` stays in sqlite because
  /// its rows are ~3.2 KB, comfortably under the cap.
  static Future<OrbMatcher?> load(Database db, String dir) async {
    try {
      final mf = File('$dir/orb/index.json');
      if (!mf.existsSync()) {
        print('ORB-LOAD: no orb/index.json in $dir -> pHash-only bundle');
        return null;
      }
      final m = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      final k = m['k'] as int;

      Future<Uint8List> rd(String n) async {
        final f = File('$dir/orb/$n');
        if (!f.existsSync()) throw StateError('missing $n');
        return f.readAsBytes();
      }

      final sw = Stopwatch()..start();
      final vocabBytes = await rd('vocab.bin');
      final idfBytes = await rd('idf.bin');
      final pc = await rd('post_card.bin');
      final pw = await rd('post_weight.bin');
      final wo = await rd('word_offset.bin');
      final cards = const LineSplitter()
          .convert(await File('$dir/orb/cards.txt').readAsString());
      final vocab = cv.Mat.fromList(k, 32, cv.MatType.CV_8UC1, vocabBytes);
      print('ORB-LOAD: ${cards.length} cards, ${m['postings']} postings, '
          '${(pc.length + pw.length + vocabBytes.length) ~/ 1000000} MB '
          'in ${sw.elapsedMilliseconds}ms');

      return OrbMatcher._(
        db,
        vocab,
        _f32(idfBytes),
        _i32(pc),
        _f32(pw),
        _i32(wo),
        cards,
        m['soft'] as int,
        m['nfeatures'] as int,
        (m['art_box'] as String).split(',').map(double.parse).toList(),
        m['resize_long_edge'] as int,
      );
    } catch (e, st) {
      // Never swallow: a null matcher and a failed load look identical to the
      // caller, which already cost one debugging round-trip.
      print('ORB-LOAD FAILED: $e');
      print('$st');
      return null;
    }
  }

  static Int32List _i32(Uint8List b) =>
      Int32List.view(b.buffer, b.offsetInBytes, b.lengthInBytes ~/ 4);
  static Float32List _f32(Uint8List b) =>
      Float32List.view(b.buffer, b.offsetInBytes, b.lengthInBytes ~/ 4);

  int get cardCount => _illu.length;
  int get postingCount => _postCard.length;

  /// Preprocess exactly as the index was built. The recipe comes from
  /// `orb_meta`, so the query side cannot silently drift from the reference
  /// side — the same contract the pHash parity test enforces.
  cv.Mat _prep(cv.Mat bgrWarp) {
    cv.Mat? gray, art, small;
    try {
      gray = cv.cvtColor(bgrWarp, cv.COLOR_BGR2GRAY);
      final w = gray.cols, h = gray.rows;
      final x0 = (w * _artBox[0]).round(), y0 = (h * _artBox[1]).round();
      final cw = (w * (_artBox[2] - _artBox[0])).round();
      final ch = (h * (_artBox[3] - _artBox[1])).round();
      art = gray.region(cv.Rect(x0, y0, cw, ch));
      final maxEdge = cw > ch ? cw : ch;
      final s = maxEdge > _edge ? _edge / maxEdge : 1.0;
      small = s < 1.0
          ? cv.resize(art, ((cw * s).round(), (ch * s).round()))
          : art.clone();
      return cv.equalizeHist(small);
    } finally {
      gray?.dispose();
      art?.dispose();
      small?.dispose();
    }
  }

  /// Identify a warped card (BGR, canonical 488x680). Returns null when nothing
  /// clears [minInliers] — "not recognised" is a real answer here, not a
  /// low-confidence guess.
  Future<OrbResult?> identify(cv.Mat bgrWarp) async {
    cv.Mat? eq, desc;
    cv.VecKeyPoint? kp;
    try {
      eq = _prep(bgrWarp);
      final orb = cv.ORB.create(nFeatures: _nfeat);
      final r = orb.detectAndCompute(eq, cv.Mat.empty());
      kp = r.$1;
      desc = r.$2;
      if (desc.isEmpty || kp.length < 8) return null;
      final bf = cv.BFMatcher.create(type: cv.NORM_HAMMING);

      // --- stage 1: quantise to visual words, score via the inverted index ---
      final mm = bf.knnMatch(desc, _vocab, _soft);
      final qw = <int, double>{};
      for (var i = 0; i < mm.length; i++) {
        final ms = mm[i];
        for (var rank = 0; rank < ms.length && rank < _soft; rank++) {
          final w = 1.0 / (rank + 1);
          qw.update(ms[rank].trainIdx, (v) => v + w, ifAbsent: () => w);
        }
      }
      if (qw.isEmpty) return null;
      var sum = 0.0;
      for (final e in qw.entries) {
        final t = e.value * _idf[e.key];
        qw[e.key] = t;
        sum += t * t;
      }
      if (sum <= 0) return null;
      final inv = 1.0 / math.sqrt(sum);

      final scores = Float32List(_illu.length);
      qw.forEach((w, v) {
        final qv = v * inv;
        for (var p = _wordOffset[w]; p < _wordOffset[w + 1]; p++) {
          scores[_postCard[p]] += qv * _postWeight[p];
        }
      });

      // Partial selection of the top-N (cheaper than sorting 50k entries).
      final short = _topN(scores, shortlist);

      // --- stage 2: exact re-rank + RANSAC, shortlist only ------------------
      String? bestIllu;
      var bestInl = -1, bestMatches = 0;
      var bestBow = 0.0;
      for (final ci in short) {
        final illu = _illu[ci];
        final rows = await _db.query('orb_desc',
            columns: ['n', 'desc', 'kpts'],
            where: 'illustration_id = ?',
            whereArgs: [illu],
            limit: 1);
        if (rows.isEmpty) continue;
        final n = rows.first['n'] as int;
        if (n < 2) continue;
        final rd = cv.Mat.fromList(
            n, 32, cv.MatType.CV_8UC1, rows.first['desc'] as Uint8List);
        final rk = _f32(rows.first['kpts'] as Uint8List);
        final pairs = <int>[];
        for (final ms in bf.knnMatch(desc, rd, 2)) {
          if (ms.length == 2 && ms[0].distance < ratio * ms[1].distance) {
            pairs
              ..add(ms[0].queryIdx)
              ..add(ms[0].trainIdx);
          }
        }
        var inl = 0;
        if (pairs.length >= 16) {
          final cnt = pairs.length ~/ 2;
          final sp = <double>[], dp = <double>[];
          for (var i = 0; i < cnt; i++) {
            final q = pairs[i * 2], t = pairs[i * 2 + 1];
            sp
              ..add(kp[q].x)
              ..add(kp[q].y);
            dp
              ..add(rk[t * 2])
              ..add(rk[t * 2 + 1]);
          }
          final sm = cv.Mat.fromList(cnt, 1, cv.MatType.CV_32FC2, sp);
          final dm = cv.Mat.fromList(cnt, 1, cv.MatType.CV_32FC2, dp);
          final mask = cv.Mat.empty();
          final hm = cv.findHomography(sm, dm,
              method: cv.RANSAC, ransacReprojThreshold: 5.0, mask: mask);
          if (!mask.isEmpty) inl = cv.countNonZero(mask);
          hm.dispose();
          sm.dispose();
          dm.dispose();
          mask.dispose();
        }
        rd.dispose();
        final m = pairs.length ~/ 2;
        if (inl > bestInl || (inl == bestInl && m > bestMatches)) {
          bestInl = inl;
          bestMatches = m;
          bestIllu = illu;
          bestBow = scores[ci];
        }
      }
      if (bestIllu == null || bestInl < minInliers) return null;
      return OrbResult(bestIllu, bestInl, bestMatches, bestBow);
    } catch (_) {
      return null;
    } finally {
      eq?.dispose();
      desc?.dispose();
    }
  }

  static List<int> _topN(Float32List s, int n) {
    final idx = <int>[];
    var worst = -1.0;
    for (var i = 0; i < s.length; i++) {
      if (idx.length < n) {
        idx.add(i);
        if (idx.length == n) {
          idx.sort((a, b) => s[b].compareTo(s[a]));
          worst = s[idx.last];
        }
      } else if (s[i] > worst) {
        idx.removeLast();
        var lo = 0, hi = idx.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (s[idx[mid]] >= s[i]) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        idx.insert(lo, i);
        worst = s[idx.last];
      }
    }
    if (idx.length < n) idx.sort((a, b) => s[b].compareTo(s[a]));
    return idx;
  }

  void dispose() => _vocab.dispose();
}
