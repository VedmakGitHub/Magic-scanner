import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// On-device OCR used only as a TIEBREAKER when pHash returns a cluster of
/// visually-similar cards (e.g. busy blue retro frames). We read the card's
/// printed text from the warped image and pick the candidate whose name matches.
class CardOcr {
  CardOcr._();

  static final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  static String? _tmpPath;

  /// OCR the warped-card JPEG and return its raw text (empty on failure).
  static Future<String> readText(Uint8List jpeg) async {
    try {
      _tmpPath ??= '${(await getTemporaryDirectory()).path}/ocr_scan.jpg';
      await File(_tmpPath!).writeAsBytes(jpeg, flush: true);
      final result = await _recognizer.processImage(InputImage.fromFilePath(_tmpPath!));
      return result.text;
    } catch (_) {
      return '';
    }
  }

  static String normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Index of the best-matching name in [names] for the OCR [text], or -1 if no
  /// candidate matches confidently. Names are matched on the front-face portion
  /// (before " // ") so DFCs work; a full substring hit wins, else token overlap.
  static int bestMatch(String text, List<String> names, {double minScore = 0.6}) {
    final hay = normalize(text);
    if (hay.isEmpty) return -1;
    final hayTokens = hay.split(' ').toSet();
    var bestIndex = -1;
    var bestScore = 0.0;
    for (var i = 0; i < names.length; i++) {
      final name = normalize(names[i].split('//').first);
      if (name.isEmpty) continue;
      double score;
      if (hay.contains(name)) {
        score = 1.0;
      } else {
        final tokens = name.split(' ').where((t) => t.length > 2).toSet();
        if (tokens.isEmpty) continue;
        final overlap = tokens.where(hayTokens.contains).length / tokens.length;
        score = overlap;
      }
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    return bestScore >= minScore ? bestIndex : -1;
  }
}
