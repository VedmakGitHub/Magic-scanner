import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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

Color rarityColor(String? rarity) {
  switch (rarity) {
    case 'mythic':
      return const Color(0xFFD3582B);
    case 'rare':
      return const Color(0xFFC9B037);
    case 'uncommon':
      return const Color(0xFFA7B5BD);
    default:
      return const Color(0xFF9E9E9E);
  }
}
