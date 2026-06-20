import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/image_urls.dart';
import '../data/models.dart';

/// Card image with lazy load + disk cache (Section 4.6). When offline and the
/// image was never cached, shows a name/set placeholder rather than failing.
/// Images are shown as-is — never cropped/distorted/recolored/watermarked
/// (Section 9).
class CardImage extends StatelessWidget {
  final Printing printing;
  final bool thumbnail;
  final double? width;
  final double? height;
  final BoxFit fit;

  const CardImage({
    super.key,
    required this.printing,
    this.thumbnail = true,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final url = thumbnail ? printing.thumbUrl() : printing.imageUrl();
    final radius = BorderRadius.circular(8);
    if (url == null) {
      return _placeholder(context, radius);
    }
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: fit,
        placeholder: (_, __) => _loading(radius),
        errorWidget: (_, __, ___) => _placeholder(context, radius),
      ),
    );
  }

  Widget _loading(BorderRadius radius) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: radius,
        ),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );

  Widget _placeholder(BuildContext context, BorderRadius radius) => Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: radius,
          border: Border.all(color: Colors.white12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_not_supported_outlined, size: 20),
              const SizedBox(height: 4),
              Text(
                printing.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                printing.setCode.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      );
}

/// "estimate, may be stale" price label (Sections 8, 9). Never presented as a
/// live/market price.
String formatPriceEstimate(double? usd) {
  if (usd == null) return '—';
  return '~\$${usd.toStringAsFixed(2)}';
}

class PriceEstimateText extends StatelessWidget {
  final double? usd;
  final bool foil;
  const PriceEstimateText(this.usd, {super.key, this.foil = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      '${formatPriceEstimate(usd)} (est., may be stale)',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
    );
  }
}

/// Set-symbol color encodes rarity (Common=black, Uncommon=silver, Rare=gold,
/// Mythic=dark orange); anything else (special/bonus) falls back to grey.
Color rarityColor(String? rarity) {
  switch (rarity) {
    case 'mythic':
      return const Color(0xFFD3582B); // dark orange
    case 'rare':
      return const Color(0xFFC9B037); // gold
    case 'uncommon':
      return const Color(0xFFC0C0C0); // silver
    case 'common':
      return const Color(0xFF000000); // black
    default:
      return const Color(0xFF9E9E9E);
  }
}

/// A set's Scryfall icon, tinted to reflect the printing's rarity, used in every
/// scan/collection menu. A soft halo keeps the black (common) glyph visible on
/// the dark theme; falls back to a rarity-colored dot while loading or on error.
class SetSymbol extends StatelessWidget {
  final String setCode;
  final String? rarity;
  final double size;

  const SetSymbol({
    super.key,
    required this.setCode,
    this.rarity,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    final color = rarityColor(rarity);
    final url = scryfallSetIconUrl(setCode);
    Widget layer(Color c, double s) => SvgPicture.network(
          url,
          width: s,
          height: s,
          colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
          placeholderBuilder: (_) => _dot(color, size * 0.6),
        );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          layer(Colors.white.withValues(alpha: 0.45), size), // halo / outline
          layer(color, size * 0.84), // rarity-colored glyph
        ],
      ),
    );
  }

  Widget _dot(Color color, double d) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 0.5),
        ),
      );
}
