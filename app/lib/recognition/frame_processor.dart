import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
      {bool full = false, bool jpegOnly = false, bool jpegFromLast = false}) {
    final c = Completer<FrameResult>();
    _pending = c;
    // jpegFromLast reuses the cached warp, so no frame bytes need transferring.
    _sendPort.send(_FrameJob(
      TransferableTypedData.fromList([jpegFromLast ? Uint8List(0) : nv21]),
      w,
      h,
      rotation,
      full,
      jpegOnly,
      jpegFromLast,
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
        if (msg.jpegFromLast) {
          final wimg = lastWarp;
          if (wimg == null) {
            main.send(FrameResult(false, const [], 0, 0, null, null, sw.elapsedMilliseconds));
            return;
          }
          main.send(FrameResult(true, const [], wimg.width, wimg.height, null,
              _encodeTitleStrip(wimg), sw.elapsedMilliseconds));
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
  const _FrameJob(this.data, this.w, this.h, this.rotation, this.full,
      this.jpegOnly, this.jpegFromLast);
}
