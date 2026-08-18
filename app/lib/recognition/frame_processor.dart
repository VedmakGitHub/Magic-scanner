import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:opencv_core/opencv.dart' as cv;

import 'card_detector.dart';
import 'phash.dart';

/// Result of processing one camera frame off the UI isolate.
class FrameResult {
  final bool found;
  final List<double> quad; // [x0,y0, x1,y1, x2,y2, x3,y3] in image coords
  final int imageW;
  final int imageH;
  final List<Uint8List>? hashes; // multi-scale 256-bit hashes (null if no card)
  final Uint8List? warpJpeg; // optional encoded warp for debug/saving
  final int detectMs;
  final Map<String, int> timings; // sub-step ms (full path): convert/quad/warp/hash/jpeg
  const FrameResult(this.found, this.quad, this.imageW, this.imageH, this.hashes,
      this.warpJpeg, this.detectMs, [this.timings = const {}]);
}

/// Long-lived isolate that runs OpenCV detection + warp + pHash so the camera
/// preview stays smooth. The matcher (top-K) runs on the main isolate, which is
/// cheap; only the heavy CV+hash is offloaded here.
class FrameProcessor {
  late final Isolate _isolate;
  late final SendPort _sendPort;
  final ReceivePort _recv = ReceivePort();
  final _ready = Completer<void>();
  Completer<FrameResult>? _pending;

  Future<void> start() async {
    _recv.listen((msg) {
      if (msg is SendPort) {
        _sendPort = msg;
        _ready.complete();
      } else if (msg is FrameResult) {
        _pending?.complete(msg);
        _pending = null;
      }
    });
    _isolate = await Isolate.spawn(_entry, _recv.sendPort);
    await _ready.future;
  }

  /// Process one NV21 frame. Modes (only one in flight at a time):
  ///  - default: fast downscaled detect, quad only (smooth live overlay)
  ///  - [full]: full-res detect + warp + multi-scale hash (for matching)
  ///  - [jpegOnly]: full-res detect + warp + JPEG encode (standalone tiebreak)
  ///  - [jpegFromLast]: encode the OCR title strip from the warp cached by the
  ///    preceding [full] pass (SAME frame) — skips a redundant detect+warp.
  /// The JPEG is encoded ONLY on demand, not on every full pass — see the
  /// "Lazy JPEG (Option A)" decision in docs/ARCHITECTURE.md.
  Future<FrameResult> process(Uint8List nv21, int w, int h, int rotation,
      {bool full = false,
      bool jpegOnly = false,
      bool jpegFromLast = false,
      bool fullWarp = false,
      bool orbBench = false,
      String benchDir = ''}) {
    final c = Completer<FrameResult>();
    _pending = c;
    // jpegFromLast/orbBench reuse the cached warp: no frame bytes to transfer.
    final reuse = jpegFromLast || orbBench;
    _sendPort.send(_FrameJob(
      TransferableTypedData.fromList([reuse ? Uint8List(0) : nv21]),
      w,
      h,
      rotation,
      full,
      jpegOnly,
      jpegFromLast,
      fullWarp,
      orbBench,
      benchDir,
    ));
    return c.future;
  }

  void dispose() {
    _recv.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _entry(SendPort main) {
    final port = ReceivePort();
    main.send(port.sendPort);
    // Warp from the last `full` pass, kept so a same-frame jpegFromLast tiebreak
    // can encode the title strip without re-running detect+warp.
    img.Image? lastWarp;
    port.listen((msg) {
      if (msg is _FrameJob) {
        final sw = Stopwatch()..start();
        if (msg.orbBench) {
          final wimg = lastWarp;
          if (wimg == null) {
            main.send(FrameResult(false, const [], 0, 0, null, null, sw.elapsedMilliseconds));
            return;
          }
          main.send(FrameResult(true, const [], wimg.width, wimg.height, null,
              null, sw.elapsedMilliseconds, _orbBench(wimg, msg.benchDir)));
          return;
        }
        if (msg.jpegFromLast) {
          final wimg = lastWarp;
          if (wimg == null) {
            main.send(FrameResult(false, const [], 0, 0, null, null, sw.elapsedMilliseconds));
            return;
          }
          // fullWarp: whole canonical warp (benchmark capture); else title strip.
          final jpg = msg.fullWarp
              ? Uint8List.fromList(img.encodeJpg(wimg, quality: 92))
              : _encodeTitleStrip(wimg);
          main.send(FrameResult(true, const [], wimg.width, wimg.height, null,
              jpg, sw.elapsedMilliseconds));
          return;
        }
        final nv21 = msg.data.materialize().asUint8List();
        final wantWarp = msg.full || msg.jpegOnly;
        final det =
            detectFromNv21(nv21, msg.w, msg.h, msg.rotation, warp: wantWarp);
        if (det == null) {
          main.send(FrameResult(false, const [], 0, 0, null, null, sw.elapsedMilliseconds));
          return;
        }
        List<Uint8List>? hashes;
        Uint8List? warpJpeg;
        var timings = const <String, int>{};
        if (msg.full && det.warp != null) {
          lastWarp = det.warp; // cache for a possible jpegFromLast this frame
          final swh = Stopwatch()..start();
          hashes = PerceptualHash.multiScale(det.warp!);
          final hashMs = swh.elapsedMilliseconds;
          final mt = PerceptualHash.lastMultiScaleTimings;
          timings = {
            'convert': lastFrameTimings['convert'] ?? -1,
            'quad': lastFrameTimings['quad'] ?? -1,
            'warp': lastFrameTimings['warp'] ?? -1,
            'hash': hashMs,
            'h.gray': mt['gray'] ?? -1,
            'h.crop': mt['crop'] ?? -1,
            'h.resize': mt['resize'] ?? -1,
            'h.dct': mt['dct'] ?? -1,
            'h.pack': mt['pack'] ?? -1,
          };
        } else if (msg.jpegOnly && det.warp != null) {
          warpJpeg = _encodeTitleStrip(det.warp!);
        }
        final quad = <double>[
          for (final p in det.quad) ...[p.dx, p.dy]
        ];
        main.send(FrameResult(true, quad, det.imageW, det.imageH, hashes,
            warpJpeg, sw.elapsedMilliseconds, timings));
      }
    });
  }

  /// DEBUG SPIKE (step D of the deep-fix plan): measure on-device cost of the
  /// ORB local-feature pipeline that beat pHash/DINOv2 offline (96.2% vs 59%).
  /// Stages timed separately so we know where the budget goes:
  ///   toMat/prep  warp -> Mat -> art crop -> 480px -> equalizeHist
  ///   orb         detectAndCompute (the per-frame cost)
  ///   match10     10x knnMatch + Lowe ratio (the stage-2 re-rank cost)
  ///   ransac      findHomography on the genuine candidate (accept/reject)
  /// References are synthetic (1 genuine self-match + 9 random) purely to time
  /// the matcher; only latency is meaningful here, not accuracy.
  static Map<String, int> _orbBench(img.Image warp, String benchDir) {
    final out = <String, int>{};
    final sw = Stopwatch();
    cv.Mat? src, gray, art, small, eq, desc, mask;
    cv.VecKeyPoint? kp;
    final refs = <cv.Mat>[];
    try {
      sw
        ..reset()
        ..start();
      final bytes = warp.getBytes(order: img.ChannelOrder.bgr);
      src = cv.Mat.fromList(warp.height, warp.width, cv.MatType.CV_8UC3, bytes);
      out['toMat'] = sw.elapsedMilliseconds;

      sw
        ..reset()
        ..start();
      gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      final x0 = (warp.width * 0.06).round();
      final y0 = (warp.height * 0.09).round();
      final cw = (warp.width * 0.88).round();
      final ch = (warp.height * 0.49).round();
      art = gray.region(cv.Rect(x0, y0, cw, ch));
      final maxEdge = cw > ch ? cw : ch;
      final s = maxEdge > 480 ? 480 / maxEdge : 1.0;
      small = s < 1.0
          ? cv.resize(art, ((cw * s).round(), (ch * s).round()))
          : art.clone();
      eq = cv.equalizeHist(small);
      out['prep'] = sw.elapsedMilliseconds;

      sw
        ..reset()
        ..start();
      final orb = cv.ORB.create(nFeatures: 100);
      final res = orb.detectAndCompute(eq, cv.Mat.empty());
      kp = res.$1;
      desc = res.$2;
      out['orb'] = sw.elapsedMilliseconds;
      out['kp'] = kp.length;
      if (desc.isEmpty || kp.length < 8) return out;

      // 1 genuine (self) + 9 random references => realistic re-rank mix.
      refs.add(desc.clone());
      for (var i = 0; i < 9; i++) {
        refs.add(cv.Mat.randu(desc.rows, desc.cols, cv.MatType.CV_8UC1));
      }
      sw
        ..reset()
        ..start();
      final bf = cv.BFMatcher.create(type: cv.NORM_HAMMING);
      final pairs = <int>[];
      var good = 0;
      for (var i = 0; i < refs.length; i++) {
        final mm = bf.knnMatch(desc, refs[i], 2);
        for (var j = 0; j < mm.length; j++) {
          final m = mm[j];
          if (m.length == 2 && m[0].distance < 0.75 * m[1].distance) {
            good++;
            if (i == 0) {
              pairs.add(m[0].queryIdx);
              pairs.add(m[0].trainIdx);
            }
          }
        }
      }
      out['match10'] = sw.elapsedMilliseconds;
      out['good'] = good;

      sw
        ..reset()
        ..start();
      if (pairs.length >= 16) {
        final n = pairs.length ~/ 2;
        final sp = <double>[], dp = <double>[];
        for (var i = 0; i < n; i++) {
          sp..add(kp[pairs[i * 2]].x)..add(kp[pairs[i * 2]].y);
          dp..add(kp[pairs[i * 2 + 1]].x)..add(kp[pairs[i * 2 + 1]].y);
        }
        final sm = cv.Mat.fromList(n, 1, cv.MatType.CV_32FC2, sp);
        final dm = cv.Mat.fromList(n, 1, cv.MatType.CV_32FC2, dp);
        mask = cv.Mat.empty();
        final hm = cv.findHomography(sm, dm,
            method: cv.RANSAC, ransacReprojThreshold: 5.0, mask: mask);
        out['inliers'] = mask.isEmpty ? -1 : cv.countNonZero(mask);
        hm.dispose();
        sm.dispose();
        dm.dispose();
      }
      out['ransac'] = sw.elapsedMilliseconds;

      // (2) QUANTIZATION: assign descriptors to words against the 65,536
      // binary centroids (2.1 MB, pushed to benchDir). This is the dominant
      // cost in the offline design (22.5 ms desktop) and the biggest unknown.
      final vf = File('$benchDir/vocab_bin.dat');
      if (vf.existsSync()) {
        final vb = vf.readAsBytesSync();
        final rows = vb.length ~/ 32;
        final vocab = cv.Mat.fromList(rows, 32, cv.MatType.CV_8UC1, vb);
        sw..reset()..start();
        final bfq = cv.BFMatcher.create(type: cv.NORM_HAMMING);
        final qm = bfq.knnMatch(desc, vocab, 3);
        out['quantize'] = sw.elapsedMilliseconds;
        out['qwords'] = qm.length;
        out['vocabRows'] = rows;
        vocab.dispose();
      } else {
        out['quantize'] = -1; // vocab not pushed
      }

      // (4) PARITY: dump the exact preprocessed input + the descriptors this
      // device produced, so the offline side can re-extract from the same
      // pixels and diff byte-for-byte. If dartcv4's ORB differs from
      // opencv-python's, the offline-built index cannot match device queries.
      if (benchDir.isNotEmpty) {
        try {
          final g = cv.imencode('.png', eq).$2;
          File('$benchDir/parity_input.png').writeAsBytesSync(g);
          final dbytes = Uint8List(desc.rows * desc.cols);
          var k = 0;
          for (var r = 0; r < desc.rows; r++) {
            for (var cc = 0; cc < desc.cols; cc++) {
              dbytes[k++] = desc.at<int>(r, cc);
            }
          }
          File('$benchDir/parity_desc.bin').writeAsBytesSync(dbytes);
          out['parityRows'] = desc.rows;
          out['parityCols'] = desc.cols;
        } catch (_) {
          out['parityRows'] = -1;
        }
      }

      // (3) MEMORY: resident set size, plus a probe allocation the size of the
      // planned in-RAM inverted index (~109 MB at 50k) to see if the device
      // tolerates it alongside the camera pipeline.
      out['rssMB'] = (ProcessInfo.currentRss / 1e6).round();
      try {
        final probe = Int32List(13500000);   // ~54 MB of posting ids
        final probeW = Float32List(13500000); // ~54 MB of weights
        probe[0] = 1; probeW[0] = 1.0;
        out['rssIndexMB'] = (ProcessInfo.currentRss / 1e6).round();
        out['probeOk'] = probe.length + probeW.length;
      } catch (_) {
        out['probeOk'] = -1;  // OOM: the in-RAM index plan is not viable as-is
      }

      out['total'] = (out['toMat'] ?? 0) +
          (out['prep'] ?? 0) +
          (out['orb'] ?? 0) +
          (out['match10'] ?? 0) +
          (out['ransac'] ?? 0);
    } catch (e) {
      out['error'] = -1;
    } finally {
      for (final m in [src, gray, art, small, eq, desc, mask, ...refs]) {
        m?.dispose();
      }
    }
    return out;
  }

  /// Crop the top ~15% (the card name) and upscale 2x so the OCR read is clean
  /// and free of rules-text noise.
  static Uint8List _encodeTitleStrip(img.Image wimg) {
    final strip = img.copyCrop(wimg,
        x: 0, y: 0, width: wimg.width, height: (wimg.height * 0.15).round());
    final up = img.copyResize(strip, width: strip.width * 2);
    return Uint8List.fromList(img.encodeJpg(up, quality: 90));
  }
}

class _FrameJob {
  final TransferableTypedData data;
  final int w, h, rotation;
  final bool full;
  final bool jpegOnly;
  final bool jpegFromLast;
  final bool fullWarp;
  final bool orbBench;
  final String benchDir;
  const _FrameJob(this.data, this.w, this.h, this.rotation, this.full,
      this.jpegOnly, this.jpegFromLast, this.fullWarp, this.orbBench,
      this.benchDir);
}
