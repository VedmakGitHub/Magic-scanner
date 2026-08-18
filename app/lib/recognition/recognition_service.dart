import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../data/card_database.dart';
import '../data/models.dart';
import 'card_detector.dart';
import 'matcher.dart';
import 'phash.dart';

/// DEBUG: when true, recognize() runs on the main isolate, saves the full +
/// cropped query images to the app documents dir, and logs the top-5 distances.
const bool kRecogDebug = false;

/// Card aspect ratio: 63 mm x 88 mm => width/height ~= 0.7159 (Section 6).
const double kCardAspect = 63.0 / 88.0;

class RecognitionResult {
  final List<Uint8List> queryHashes; // multi-scale (inset) hashes
  final List<Candidate> candidates;
  final MatchConfidence confidence;
  final int hashMatchMillis;

  const RecognitionResult({
    required this.queryHashes,
    required this.candidates,
    required this.confidence,
    required this.hashMatchMillis,
  });

  /// Pre-select the best candidate only when the match is strong (Section 5.2).
  bool get shouldPreselect => confidence == MatchConfidence.strong;
}

/// Ties capture bytes -> auto-crop -> 256-bit pHash -> matcher -> candidates.
class RecognitionService {
  final CardDatabase cardDb;
  final Matcher matcher;
  RecognitionService(this.cardDb, this.matcher);

  Future<RecognitionResult> recognize(Uint8List imageBytes) async {
    final sw = Stopwatch()..start();
    final List<Uint8List> hashes;
    if (kRecogDebug) {
      hashes = await _hashAndDumpForDebug(imageBytes);
    } else {
      hashes = await compute(_hashCroppedCard, imageBytes);
    }
    final top = matcher.topKMulti(hashes);
    final candidates = <Candidate>[];
    for (final m in top) {
      final ill = matcher.illustrationIds[m.index];
      final sid = matcher.scryfallIds[m.index];
      final face = matcher.faces[m.index];
      Printing? pr;
      if (ill != null) {
        pr = await cardDb.representativeForIllustration(ill);
      }
      pr ??= await cardDb.getPrinting(sid, face: face);
      if (kRecogDebug) {
        debugPrint('  cand dist=${m.distance}  ${pr?.name ?? "?"} '
            '[${pr?.setCode ?? "?"} ${pr?.lang ?? "?"}]');
      }
      candidates.add(Candidate(
        illustrationId: ill,
        scryfallId: sid,
        face: face,
        distance: m.distance,
        printing: pr,
      ));
    }
    sw.stop();
    return RecognitionResult(
      queryHashes: hashes,
      candidates: candidates,
      confidence: classify(top),
      hashMatchMillis: sw.elapsedMilliseconds,
    );
  }
}

/// Normalize orientation, detect+warp the card (fallback to heuristic crop),
/// and hash. Returns (hash, cardImage, method).
({List<Uint8List> hashes, img.Image card, String method}) _prepareAndHash(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) throw const FormatException('Could not decode captured image');
  image = img.bakeOrientation(image);
  // OpenCV ignores EXIF, so feed it the already-upright image as PNG bytes.
  final uprightPng = img.encodePng(image);
  img.Image? card = detectAndWarpCard(uprightPng);
  final method = card != null ? 'warp' : 'crop';
  card ??= autoCropCard(image);
  return (hashes: PerceptualHash.multiScale(card), card: card, method: method);
}

/// DEBUG: run on the main isolate, save full + card images, log query hash.
Future<List<Uint8List>> _hashAndDumpForDebug(Uint8List bytes) async {
  final image = img.bakeOrientation(img.decodeImage(bytes)!);
  final r = _prepareAndHash(bytes);
  try {
    final dir = await getApplicationDocumentsDirectory();
    File('${dir.path}/last_full.jpg')
        .writeAsBytesSync(img.encodeJpg(image, quality: 70));
    File('${dir.path}/last_crop.jpg')
        .writeAsBytesSync(img.encodeJpg(r.card, quality: 90));
  } catch (e) {
    debugPrint('debug image save failed: $e');
  }
  debugPrint('QUERY method=${r.method} card=${r.card.width}x${r.card.height} '
      'insets=${r.hashes.length}');
  return r.hashes;
}

/// Isolate-safe: detect+warp (or crop) the card, multi-scale hash.
List<Uint8List> _hashCroppedCard(Uint8List bytes) => _prepareAndHash(bytes).hashes;

/// Auto-detect the card and crop to it (replaces the fixed guide crop).
///
/// The card is full of edges (border, art, text) while a plain table and the
/// card's drop-shadow are smooth, so we locate the card by EDGE-ENERGY
/// projection onto rows and columns. The card's vertical extent (strong top/
/// bottom border edges) is reliable, so we take the detected height and the
/// detected horizontal centre, then emit a card-aspect box (matching the
/// reference images, which are the card edge-to-edge). Falls back to a centred
/// card-aspect crop if detection looks degenerate.
img.Image autoCropCard(img.Image src, {double frac = 0.18, int step = 2}) {
  final w = src.width;
  final h = src.height;
  final rgb = src.getBytes(order: img.ChannelOrder.rgb);

  double lum(int x, int y) {
    final i = (y * w + x) * 3;
    return 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
  }

  final colE = Float64List(w);
  final rowE = Float64List(h);
  for (var y = 0; y < h - step; y += step) {
    for (var x = 0; x < w - step; x += step) {
      final l = lum(x, y);
      final g = (lum(x + step, y) - l).abs() + (lum(x, y + step) - l).abs();
      if (g > 18) {
        colE[x] += g;
        rowE[y] += g;
      }
    }
  }

  Float64List smooth(Float64List a, int r) {
    final out = Float64List(a.length);
    for (var i = 0; i < a.length; i++) {
      final lo = (i - r) < 0 ? 0 : i - r;
      final hi = (i + r + 1) > a.length ? a.length : i + r + 1;
      var s = 0.0;
      for (var j = lo; j < hi; j++) {
        s += a[j];
      }
      out[i] = s / (hi - lo);
    }
    return out;
  }

  final cE = smooth(colE, 4);
  final rE = smooth(rowE, 4);

  List<int> span(Float64List a) {
    var m = 0.0;
    for (final v in a) {
      if (v > m) m = v;
    }
    final t = m * frac;
    var lo = 0, hi = a.length - 1;
    for (var i = 0; i < a.length; i++) {
      if (a[i] > t) {
        lo = i;
        break;
      }
    }
    for (var i = a.length - 1; i >= 0; i--) {
      if (a[i] > t) {
        hi = i;
        break;
      }
    }
    return [lo, hi];
  }

  final xs = span(cE);
  final ys = span(rE);
  final detW = xs[1] - xs[0];
  final detH = ys[1] - ys[0];
  if (detW < w * 0.2 || detH < h * 0.2) {
    return _centerCardCrop(src); // detection failed -> safe fallback
  }
  // Height-led card-aspect box centred on the detected card.
  final cx = (xs[0] + xs[1]) / 2.0;
  var cropH = detH;
  var cropW = (cropH * kCardAspect).round();
  if (cropW > w) {
    cropW = w;
    cropH = (cropW / kCardAspect).round();
  }
  var x = (cx - cropW / 2).round();
  var y = ys[0];
  x = x.clamp(0, w - cropW);
  y = y.clamp(0, h - cropH);
  return img.copyCrop(src, x: x, y: y, width: cropW, height: cropH);
}

/// Centered card-aspect crop (fallback when auto-detection is unreliable).
img.Image _centerCardCrop(img.Image src, {double widthFraction = 0.86}) {
  final w = src.width;
  final h = src.height;
  var cropW = (w * widthFraction).round();
  var cropH = (cropW / kCardAspect).round();
  if (cropH > h * 0.94) {
    cropH = (h * 0.94).round();
    cropW = (cropH * kCardAspect).round();
  }
  cropW = cropW.clamp(1, w);
  cropH = cropH.clamp(1, h);
  final x = ((w - cropW) / 2).round();
  final y = ((h - cropH) / 2).round();
  return img.copyCrop(src, x: x, y: y, width: cropW, height: cropH);
}
