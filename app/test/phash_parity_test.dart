import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mtg_scanner/recognition/phash.dart';

/// MANDATORY parity test (Section 5.3).
///
/// Hashes the fixtures in test/fixtures/ with the on-device implementation
/// (lib/recognition/phash.dart) and asserts the 64-bit values are IDENTICAL to
/// the golden values produced by the reference implementation (dataprep/phash.py
/// via dataprep/gen_fixtures.py).
///
/// Gate all downstream work on this passing. If it fails, regenerate the shared
/// cosine table and golden values (see app/README.md).
void main() {
  final fixturesDir = Directory('test/fixtures');
  final goldenFile = File('test/fixtures/golden.json');

  test('fixtures + golden.json exist', () {
    expect(fixturesDir.existsSync(), isTrue,
        reason: 'Run dataprep/gen_fixtures.py to create fixtures.');
    expect(goldenFile.existsSync(), isTrue);
  });

  final golden = goldenFile.existsSync()
      ? (jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>)
      : <String, dynamic>{};

  test('golden set is non-trivial', () {
    expect(golden.length, greaterThanOrEqualTo(15),
        reason: 'Expected a spread of fixtures (Section 5.3 asks for ~20).');
  });

  for (final entry in golden.entries) {
    final name = entry.key;
    final expected = entry.value as String;
    test('pHash parity: $name', () {
      final bytes = File('test/fixtures/$name').readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      expect(decoded, isNotNull, reason: 'could not decode $name');
      final h = PerceptualHash.fromImage(decoded!);
      final hex = PerceptualHash.toHex(h);
      expect(hex, equals(expected),
          reason: 'Dart pHash for $name ($hex) != Python golden ($expected). '
              'Parity is broken — recognition will silently fail (Section 5).');
    });
  }
}
