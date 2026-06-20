import 'package:flutter_test/flutter_test.dart' hide Matcher;
import 'package:mtg_scanner/recognition/matcher.dart';
import 'package:mtg_scanner/recognition/phash.dart';

void main() {
  Map<String, Object?> row(String ill, int phash) =>
      {'illustration_id': ill, 'scryfall_id': 's_$ill', 'face': 'front', 'phash': phash};

  test('hammingDistance counts differing bits', () {
    expect(hammingDistance(0, 0), 0);
    expect(hammingDistance(0xF, 0x1), 3);
    expect(hammingDistance(-1, 0), 64); // all bits set
  });

  test('topK returns nearest matches ascending', () {
    final m = Matcher.fromRows([
      row('a', 0x0000000000000000),
      row('b', 0x0000000000000001), // dist 1 from query 0
      row('c', 0x000000000000000F), // dist 4
      row('d', 0x00000000000000FF), // dist 8
    ]);
    final top = m.topK(0x0000000000000000, k: 3);
    expect(top.length, 3);
    expect(top[0].distance, 0);
    expect(top[1].distance, 1);
    expect(top[2].distance, 4);
    expect(m.illustrationIds[top[0].index], 'a');
  });

  test('classify: strong / ambiguous / weak', () {
    // Strong: best <= 10 and clear gap.
    final strong = Matcher.fromRows([row('a', 0), row('b', 0xFFFF)])
        .topK(0, k: 5);
    expect(classify(strong), MatchConfidence.strong);

    // Ambiguous: top two within 2 bits.
    final ambig = Matcher.fromRows([row('a', 0x3), row('b', 0x1)]).topK(0, k: 5);
    expect(classify(ambig), MatchConfidence.ambiguous);

    // Weak: best distance large.
    final weak = Matcher.fromRows([row('a', 0x7FFFFFF)]).topK(0, k: 5);
    expect(classify(weak), MatchConfidence.weak);
  });
}
