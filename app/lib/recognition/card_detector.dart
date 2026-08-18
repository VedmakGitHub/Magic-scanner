import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;
import 'package:opencv_core/opencv.dart' as cv;

/// Canonical reference card size (matches Scryfall `normal` aspect ~0.7159).
const int kWarpW = 488;
const int kWarpH = 680;

/// Result of detecting a card in a frame: the detected quad corners (in the
/// rotated image's coordinate space) + that image's dimensions for the live
/// overlay, and optionally the perspective-warped card ready to hash. The
/// warp is null for the fast overlay-only path.
class CardDetection {
  final img.Image? warp;
  final List<Offset> quad; // [tl, tr, br, bl] in image coords
  final int imageW;
  final int imageH;
  const CardDetection(this.warp, this.quad, this.imageW, this.imageH);
}

/// Long edge (px) the fast overlay-only detection downscales to. The hash path
/// always uses full resolution for precise corners (a borderline retro frame
/// needs that — see the multi-scale matching in phash.dart).
const int _fastDetectEdge = 480;

/// Per-frame sub-step timings (ms) for the full detect path, filled in the
/// processing isolate for diagnostics. Isolate-local (not shared with main).
final Map<String, int> lastFrameTimings = {};

/// JPEG path (used by the still capture): detect + warp from encoded bytes.
img.Image? detectAndWarpCard(Uint8List jpegBytes) {
  cv.Mat? src;
  try {
    src = cv.imdecode(jpegBytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return null;
    return _warpFrom(src, _findQuad(src));
  } catch (_) {
    return null;
  } finally {
    src?.dispose();
  }
}

/// Camera-stream path. With [warp] true: full-res detect + perspective warp
/// (for hashing). With [warp] false: fast downscaled detect, quad only (for the
/// live overlay) — much cheaper so the outline tracks smoothly.
CardDetection? detectFromNv21(Uint8List nv21, int width, int height, int rotation,
    {bool warp = true}) {
  cv.Mat? yuv, bgr, rotated;
  try {
    final sw = Stopwatch()..start();
    yuv = cv.Mat.fromList(height * 3 ~/ 2, width, cv.MatType.CV_8UC1, nv21);
    bgr = cv.cvtColor(yuv, cv.COLOR_YUV2BGR_NV21);
    rotated = switch (rotation) {
      90 => cv.rotate(bgr, cv.ROTATE_90_CLOCKWISE),
      180 => cv.rotate(bgr, cv.ROTATE_180),
      270 => cv.rotate(bgr, cv.ROTATE_90_COUNTERCLOCKWISE),
      _ => bgr.clone(),
    };
    if (warp) lastFrameTimings['convert'] = sw.elapsedMilliseconds;
    return warp ? _detectAndWarp(rotated) : _detectQuadOnly(rotated);
  } catch (_) {
    return null;
  } finally {
    yuv?.dispose();
    bgr?.dispose();
    rotated?.dispose();
  }
}

/// Largest 4-point contour >= 10% of the Mat's area, or null. Corners are in
/// [m]'s coordinate space (caller scales them if [m] was downscaled).
List<cv.Point>? _findQuad(cv.Mat m) {
  cv.Mat? gray, blur, edges, kernel, dilated;
  cv.VecVecPoint? contours;
  try {
    final area = m.cols * m.rows;
    gray = cv.cvtColor(m, cv.COLOR_BGR2GRAY);
    blur = cv.gaussianBlur(gray, (5, 5), 0);
    edges = cv.canny(blur, 30, 120);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    dilated = cv.dilate(edges, kernel);
    final found = cv.findContours(dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    contours = found.$1;
    List<cv.Point>? quad;
    double bestArea = 0;
    for (var i = 0; i < contours.length; i++) {
      final c = contours[i];
      final a = cv.contourArea(c);
      if (a < area * 0.10 || a <= bestArea) continue;
      final peri = cv.arcLength(c, true);
      final approx = cv.approxPolyDP(c, 0.02 * peri, true);
      if (approx.length == 4) {
        quad = [for (var j = 0; j < 4; j++) approx[j]];
        bestArea = a;
      }
    }
    return quad;
  } finally {
    for (final mat in [gray, blur, edges, kernel, dilated]) {
      mat?.dispose();
    }
    contours?.dispose();
  }
}

/// Full-res detect + warp to canonical size (precise corners for hashing).
CardDetection? _detectAndWarp(cv.Mat src) {
  final sw = Stopwatch()..start();
  final quad = _findQuad(src);
  lastFrameTimings['quad'] = sw.elapsedMilliseconds;
  sw.reset();
  sw.start();
  final res = _warpResult(src, quad);
  lastFrameTimings['warp'] = sw.elapsedMilliseconds;
  return res;
}

CardDetection? _warpResult(cv.Mat src, List<cv.Point>? quad) {
  if (quad == null) return null;
  final warp = _warpFrom(src, quad);
  if (warp == null) return null;
  final ordered = _orderCorners(quad);
  return CardDetection(
    warp,
    [for (final p in ordered) Offset(p.x.toDouble(), p.y.toDouble())],
    src.cols,
    src.rows,
  );
}

img.Image? _warpFrom(cv.Mat src, List<cv.Point>? quad) {
  if (quad == null) return null;
  cv.Mat? m, warped;
  try {
    final ordered = _orderCorners(quad);
    final srcPts = cv.VecPoint.fromList(ordered);
    final dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(kWarpW, 0),
      cv.Point(kWarpW, kWarpH),
      cv.Point(0, kWarpH),
    ]);
    m = cv.getPerspectiveTransform(srcPts, dstPts);
    warped = cv.warpPerspective(src, m, (kWarpW, kWarpH));
    // Copy the bytes (Mat.data is a native view freed on dispose()).
    return img.Image.fromBytes(
      width: kWarpW,
      height: kWarpH,
      bytes: Uint8List.fromList(warped.data).buffer,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    );
  } finally {
    m?.dispose();
    warped?.dispose();
  }
}

/// Fast overlay path: downscale, find the quad, scale corners back to full-res.
CardDetection? _detectQuadOnly(cv.Mat src) {
  cv.Mat? small;
  try {
    final w = src.cols, h = src.rows;
    final maxEdge = w > h ? w : h;
    final scale = maxEdge > _fastDetectEdge ? _fastDetectEdge / maxEdge : 1.0;
    final cv.Mat det;
    if (scale < 1.0) {
      small = cv.resize(src, ((w * scale).round(), (h * scale).round()));
      det = small;
    } else {
      det = src;
    }
    final quad = _findQuad(det);
    if (quad == null) return null;
    final inv = scale < 1.0 ? 1.0 / scale : 1.0;
    final ordered = _orderCorners(
        [for (final p in quad) cv.Point((p.x * inv).round(), (p.y * inv).round())]);
    return CardDetection(
      null,
      [for (final p in ordered) Offset(p.x.toDouble(), p.y.toDouble())],
      w,
      h,
    );
  } finally {
    small?.dispose();
  }
}

/// Order 4 corners as [tl, tr, br, bl] via the sum/diff trick.
List<cv.Point> _orderCorners(List<cv.Point> p) {
  cv.Point byMin(int Function(cv.Point) f) =>
      p.reduce((a, b) => f(a) <= f(b) ? a : b);
  cv.Point byMax(int Function(cv.Point) f) =>
      p.reduce((a, b) => f(a) >= f(b) ? a : b);
  final tl = byMin((q) => q.x + q.y);
  final br = byMax((q) => q.x + q.y);
  final tr = byMin((q) => q.y - q.x);
  final bl = byMax((q) => q.y - q.x);
  return [tl, tr, br, bl];
}
