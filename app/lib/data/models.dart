import 'dart:convert';

import 'image_urls.dart';

/// A single printing row (per face) from the bundle `printings` table (Section 7).
class Printing {
  final String scryfallId;
  final String? oracleId;
  final String? illustrationId;
  final String name;
  final String setCode;
  final String setName;
  final String collectorNumber;
  final String? rarity;
  final List<String> finishes;
  final String lang;
  final String? releasedAt;
  final String? imageId;
  final String face; // "front" | "back"
  final double? priceUsd;
  final double? priceUsdFoil;
  final String? artist;

  const Printing({
    required this.scryfallId,
    this.oracleId,
    this.illustrationId,
    required this.name,
    required this.setCode,
    required this.setName,
    required this.collectorNumber,
    this.rarity,
    required this.finishes,
    required this.lang,
    this.releasedAt,
    this.imageId,
    required this.face,
    this.priceUsd,
    this.priceUsdFoil,
    this.artist,
  });

  factory Printing.fromRow(Map<String, Object?> r) {
    return Printing(
      scryfallId: r['scryfall_id'] as String,
      oracleId: r['oracle_id'] as String?,
      illustrationId: r['illustration_id'] as String?,
      name: r['name'] as String,
      setCode: r['set_code'] as String,
      setName: r['set_name'] as String,
      collectorNumber: r['collector_number'] as String,
      rarity: r['rarity'] as String?,
      finishes: _parseFinishes(r['finishes'] as String?),
      lang: r['lang'] as String,
      releasedAt: r['released_at'] as String?,
      imageId: r['image_id'] as String?,
      face: (r['face'] as String?) ?? 'front',
      priceUsd: (r['price_usd'] as num?)?.toDouble(),
      priceUsdFoil: (r['price_usd_foil'] as num?)?.toDouble(),
      artist: r['artist'] as String?,
    );
  }

  static List<String> _parseFinishes(String? raw) {
    if (raw == null || raw.isEmpty) return const ['nonfoil'];
    try {
      final list = jsonDecode(raw);
      if (list is List && list.isNotEmpty) {
        return list.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const ['nonfoil'];
  }

  String? thumbUrl() =>
      imageId == null ? null : scryfallImageUrl(imageId!, size: ImageSize.small, face: face);

  String? imageUrl() =>
      imageId == null ? null : scryfallImageUrl(imageId!, size: ImageSize.normal, face: face);

  String get setLabel => '$setName (${setCode.toUpperCase()}) #$collectorNumber';
}

/// A reference hash row from the bundle `hashes` table (Section 7).
class HashEntry {
  final String? illustrationId;
  final String scryfallId;
  final String face;
  final int phash; // 64-bit (stored signed in SQLite)

  const HashEntry({
    required this.illustrationId,
    required this.scryfallId,
    required this.face,
    required this.phash,
  });
}

/// A recognition candidate: a reference match plus its display printing.
class Candidate {
  final String? illustrationId;
  final String scryfallId;
  final String face;
  final int distance; // Hamming distance to the query (Section 5.2)
  final Printing? printing; // a representative printing for display

  const Candidate({
    required this.illustrationId,
    required this.scryfallId,
    required this.face,
    required this.distance,
    required this.printing,
  });
}

/// A collection item joined with its printing for display.
class CollectionEntry {
  final int id;
  final String scryfallId;
  final String finish; // "nonfoil" | "foil" | "etched" ...
  final int quantity;
  final String addedAt;
  final Printing? printing; // resolved from the bundle (front face)

  const CollectionEntry({
    required this.id,
    required this.scryfallId,
    required this.finish,
    required this.quantity,
    required this.addedAt,
    required this.printing,
  });
}
