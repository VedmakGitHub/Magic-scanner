import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;
import 'package:opencv_core/opencv.dart' as cv;

/// Canonical reference card size (matches Scryfall `normal` aspect ~0.7159).
const int kWarpW = 488;
const int kWarpH = 680;

/// Result of detecting a card in a frame: the perspective-warped card (ready to
/// hash) plus the detected quad corners in the (rotated) image's coordinate
/// space and that image's dimensions (for drawing the live overlay).
class CardDetection {
  final img.Image warp;
  final List<Offset> quad; // [tl, tr, br, bl] in image coords
  final int imageW;
  final int imageH;
  const CardDetection(this.warp, this.quad, this.imageW, this.imageH);
}

/// JPEG path (used by the still capture): detect + warp from encoded bytes.
img.Image? detectAndWarpCard(Uint8List jpegBytes) {
  cv.Mat? src;
  try {
    src = cv.imdecode(jpegBytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return null;
    final d = _detectInMat(src);
    return d?.warp;
  } catch (_) {
    return null;
  } finally {
    src?.dispose();
  }
}

/// Camera-stream path: detect + warp from an NV21 frame. [rotation] is the
/// sensor orientation (0/90/180/270) used to make the card upright.
CardDetection? detectFromNv21(
    Uint8List nv21, int width, int height, int rotation) {
  cv.Mat? yuv, bgr, rotated;
  try {
    yuv = cv.Mat.fromList(height * 3 ~/ 2, width, cv.MatType.CV_8UC1, nv21);
    bgr = cv.cvtColor(yuv, cv.COLOR_YUV2BGR_NV21);
    rotated = switch (rotation) {
      90 => cv.rotate(bgr, cv.ROTATE_90_CLOCKWISE),
      180 => cv.rotate(bgr, cv.ROTATE_180),
      270 => cv.rotate(bgr, cv.ROTATE_90_COUNTERCLOCKWISE),
      _ => bgr.clone(),
    };
    return _detectInMat(rotated);
  } catch (_) {
    return null;
  } finally {
    yuv?.dispose();
    bgr?.dispose();
    rotated?.dispose();
  }
}

/// Core detection on a BGR Mat: largest 4-point contour >=10% of frame, warped
/// to canonical size. Returns null if no convincing card outline.
CardDetection? _detectInMat(cv.Mat src) {
  cv.Mat? gray, blur, edges, kernel, dilated, m, warped;
  cv.VecVecPoint? contours;
  try {
    final w = src.cols, h = src.rows;
    final area = w * h;
    gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
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
    if (quad == null) return null;

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

    // BGR Mat -> img.Image. Copy the bytes (Mat.data is a view into native
    // memory that's freed on dispose() in the finally block).
    final bytes = Uint8List.fromList(warped.data);
    final image = img.Image.fromBytes(
      width: kWarpW,
      height: kWarpH,
      bytes: bytes.buffer,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    );
    final quadOffsets = [
      for (final p in ordered) Offset(p.x.toDouble(), p.y.toDouble())
    ];
    return CardDetection(image, quadOffsets, w, h);
  } finally {
    for (final mat in [gray, blur, edges, kernel, dilated, m, warped]) {
      mat?.dispose();
    }
    contours?.dispose();
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
