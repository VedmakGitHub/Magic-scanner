import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart' hide Matcher;
import 'package:mtg_scanner/recognition/matcher.dart';
import 'package:mtg_scanner/recognition/phash.dart';

void main() {
  // Build a 32-byte hash whose first byte is [b]; rest zero.
  Uint8List blob(int b) {
    final u = Uint8List(32);
    u[0] = b;
    return u;
  }

  Map<String, Object?> row(String ill, Uint8List phash) =>
      {'illustration_id': ill, 'scryfall_id': 's_$ill', 'face': 'front', 'phash': phash};

  test('hammingDistance counts differing bits over 32 bytes', () {
    expect(hammingDistance(Uint8List(32), Uint8List(32)), 0);
    expect(hammingDistance(blob(0x0F), blob(0x01)), 3);
    final allOnes = Uint8List(32)..fillRange(0, 32, 0xFF);
    expect(hammingDistance(allOnes, Uint8List(32)), 256);
  });

  test('toWords round-trips byte order', () {
    final u = Uint8List(32);
    u[7] = 1; // least-significant byte of word 0 (big-endian)
    final w = PerceptualHash.toWords(u);
    expect(w[0], 1);
    expect(w[1], 0);
  });

  test('topK returns nearest matches ascending', () {
    final m = Matcher.fromRows([
      row('a', blob(0x00)), // dist 0 from query 0x00
      row('b', blob(0x01)), // dist 1
      row('c', blob(0x0F)), // dist 4
      row('d', blob(0xFF)), // dist 8
    ]);
    final top = m.topK(blob(0x00), k: 3);
    expect(top.length, 3);
    expect(top[0].distance, 0);
    expect(top[1].distance, 1);
    expect(top[2].distance, 4);
    expect(m.illustrationIds[top[0].index], 'a');
  });
}
