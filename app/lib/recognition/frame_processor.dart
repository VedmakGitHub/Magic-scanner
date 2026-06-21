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
  const FrameResult(this.found, this.quad, this.imageW, this.imageH, this.hashes,
      this.warpJpeg, this.detectMs);
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

  /// Process one NV21 frame. [full] false = fast downscaled detect, quad only
  /// (smooth live overlay); [full] true = full-res detect + warp + multi-scale
  /// hash + warp JPEG (for matching/OCR). Only one in flight at a time.
  Future<FrameResult> process(Uint8List nv21, int w, int h, int rotation,
      {bool full = false}) {
    final c = Completer<FrameResult>();
    _pending = c;
    _sendPort.send(_FrameJob(
      TransferableTypedData.fromList([nv21]),
      w,
      h,
      rotation,
      full,
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
    port.listen((msg) {
      if (msg is _FrameJob) {
        final sw = Stopwatch()..start();
        final nv21 = msg.data.materialize().asUint8List();
        final det = detectFromNv21(nv21, msg.w, msg.h, msg.rotation, warp: msg.full);
        if (det == null) {
          main.send(FrameResult(false, const [], 0, 0, null, null, sw.elapsedMilliseconds));
          return;
        }
        List<Uint8List>? hashes;
        Uint8List? warpJpeg;
        if (msg.full && det.warp != null) {
          hashes = PerceptualHash.multiScale(det.warp!);
          warpJpeg = Uint8List.fromList(img.encodeJpg(det.warp!, quality: 88));
        }
        final quad = <double>[
          for (final p in det.quad) ...[p.dx, p.dy]
        ];
        main.send(FrameResult(
            true, quad, det.imageW, det.imageH, hashes, warpJpeg, sw.elapsedMilliseconds));
      }
    });
  }
}

class _FrameJob {
  final TransferableTypedData data;
  final int w, h, rotation;
  final bool full;
  const _FrameJob(this.data, this.w, this.h, this.rotation, this.full);
}
