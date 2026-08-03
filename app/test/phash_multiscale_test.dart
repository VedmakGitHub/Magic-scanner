import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mtg_scanner/recognition/phash.dart';

/// Guards the Commit-2 hash optimization (grayscale-once + windowed resize +
/// direct-byte gray). These cases are NOT covered by the golden parity test
/// (which only feeds RGB fixtures through fromImage), so they lock the parts the
/// optimization actually changed:
///   1. windowed inset == crop-then-hash  (the core equivalence claim)
///   2. channel-order invariance          (BGR warp == RGB, via getBytes(rgb))
///   3. alpha is dropped like getPixel     (RGBA == RGB)
void main() {
  int r(int x, int y) => (x * 7 + y * 3) & 0xff;
  int g(int x, int y) => (x * 3 + y * 11) & 0xff;
  int b(int x, int y) => (x * 13 + y * 5) & 0xff;

  img.Image buildRgb(int w, int h) {
    final im = img.Image(width: w, height: h, numChannels: 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        im.setPixelRgb(x, y, r(x, y), g(x, y), b(x, y));
      }
    }
    return im;
  }

  // Same logical colours but stored BGR — mimics the OpenCV warp buffer.
  img.Image buildBgr(int w, int h) {
    final bytes = Uint8List(w * h * 3);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        bytes[i++] = b(x, y);
        bytes[i++] = g(x, y);
        bytes[i++] = r(x, y);
      }
    }
    return img.Image.fromBytes(
        width: w,
        height: h,
        bytes: bytes.buffer,
        numChannels: 3,
        order: img.ChannelOrder.bgr);
  }

  img.Image buildRgba(int w, int h) {
    final im = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        im.setPixelRgba(x, y, r(x, y), g(x, y), b(x, y), (x + y) & 0xff);
      }
    }
    return im;
  }

  String hex(Uint8List h) => PerceptualHash.toHex(h);

  test('windowed inset hash == crop-then-hash for every inset', () {
    const w = 488, h = 680;
    final card = buildRgb(w, h);
    final ms = PerceptualHash.multiScale(card);
    expect(ms.length, kInsets.length);
    for (var k = 0; k < kInsets.length; k++) {
      final p = kInsets[k];
      final img.Image ref;
      if (p <= 0) {
        ref = card;
      } else {
        final dx = (w * p).round(), dy = (h * p).round();
        ref = img.copyCrop(card,
            x: dx, y: dy, width: w - 2 * dx, height: h - 2 * dy);
      }
      expect(hex(ms[k]), equals(hex(PerceptualHash.fromImage(ref))),
          reason: 'inset $p: windowed hash != crop-then-hash');
    }
  });

  test('fromImage is channel-order invariant (BGR warp == RGB)', () {
    final rgb = buildRgb(200, 280);
    final bgr = buildBgr(200, 280);
    expect(hex(PerceptualHash.fromImage(bgr)),
        equals(hex(PerceptualHash.fromImage(rgb))));
  });

  test('alpha is ignored (RGBA == RGB of same colours)', () {
    final rgb = buildRgb(200, 280);
    final rgba = buildRgba(200, 280);
    expect(hex(PerceptualHash.fromImage(rgba)),
        equals(hex(PerceptualHash.fromImage(rgb))));
  });
}
