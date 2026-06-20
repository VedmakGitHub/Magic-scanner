import 'config.dart';

/// Build Scryfall CDN image URLs at runtime from stored components (Section 4.6).
///
///   https://cards.scryfall.io/<size>/<face>/<id[0]>/<id[1]>/<id>.jpg
///
/// We never ship images in the bundle; they are fetched lazily and cached.
/// Per Scryfall rules we must not crop/distort/recolor/watermark these images
/// (Section 9) — callers display them as-is.
class ImageSize {
  static const small = 'small'; // list thumbnails
  static const normal = 'normal'; // detail views
  static const large = 'large';
  static const artCrop = 'art_crop';
}

String scryfallImageUrl(
  String imageId, {
  String size = ImageSize.normal,
  String face = 'front',
}) {
  final f = (face == 'back') ? 'back' : 'front';
  return '${AppConfig.scryfallImageBase}/$size/$f/'
      '${imageId[0]}/${imageId[1]}/$imageId.jpg';
}
