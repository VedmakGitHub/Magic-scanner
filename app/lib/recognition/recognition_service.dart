import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../data/card_database.dart';
import '../data/models.dart';
import 'matcher.dart';
import 'phash.dart';

/// Card aspect ratio: 63 mm x 88 mm => width/height ~= 0.7159 (Section 6).
const double kCardAspect = 63.0 / 88.0;

class RecognitionResult {
  final int queryHash;
  final List<Candidate> candidates;
  final MatchConfidence confidence;
  final int hashMatchMillis;

  const RecognitionResult({
    required this.queryHash,
    required this.candidates,
    required this.confidence,
    required this.hashMatchMillis,
  });

  /// Pre-select the best candidate only when the match is strong (Section 5.2).
  bool get shouldPreselect => confidence == MatchConfidence.strong;
}

/// Ties capture bytes -> pHash -> matcher -> display candidates (Section 6).
class RecognitionService {
  final CardDatabase cardDb;
  final Matcher matcher;
  RecognitionService(this.cardDb, this.matcher);

  Future<RecognitionResult> recognize(Uint8List imageBytes) async {
    final sw = Stopwatch()..start();
    // Hash off the UI isolate (decode + DCT) to keep the latency target tight.
    final hash = await compute(_hashCroppedGuide, imageBytes);
    final top = matcher.topK(hash);
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
      queryHash: hash,
      candidates: candidates,
      confidence: classify(top),
      hashMatchMillis: sw.elapsedMilliseconds,
    );
  }
}

/// Top-level (isolate-safe) entry: decode, normalize orientation, crop to the
/// guide rectangle, then hash. The crop must match the on-screen guide overlay
/// (camera/guide_overlay.dart) so the hashed pixels are what the user framed.
int _hashCroppedGuide(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('Could not decode captured image');
  }
  image = img.bakeOrientation(image); // normalize EXIF rotation
  final cropped = cropToCardGuide(image);
  return PerceptualHash.fromImage(cropped);
}

/// Centered crop with the card aspect ratio, sized to the guide margins
/// (Section 6 step 2 — fixed crop region, no perspective correction in MVP).
img.Image cropToCardGuide(img.Image src, {double widthFraction = 0.86}) {
  final w = src.width;
  final h = src.height;
  // Try width-led sizing first.
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
