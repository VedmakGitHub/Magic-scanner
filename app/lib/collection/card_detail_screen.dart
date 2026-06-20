import 'package:flutter/material.dart';

import '../data/models.dart';
import '../legal/legal_strings.dart';
import '../ui/widgets.dart';

/// Card detail: large image (lazy from CDN), name, set, collector number,
/// rarity, finish, artist, estimated price (labelled) (Sections 8.6, 9).
class CardDetailScreen extends StatelessWidget {
  final Printing printing;
  final String? finish;
  const CardDetailScreen({super.key, required this.printing, this.finish});

  @override
  Widget build(BuildContext context) {
    final p = printing;
    final price = (finish == 'foil') ? (p.priceUsdFoil ?? p.priceUsd) : p.priceUsd;
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360, maxHeight: 503),
              child: AspectRatio(
                aspectRatio: 63 / 88,
                child: CardImage(printing: p, thumbnail: false, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _row('Name', p.name),
          _row('Set', '${p.setName} (${p.setCode.toUpperCase()})'),
          _row('Collector #', p.collectorNumber),
          if (p.rarity != null) _row('Rarity', p.rarity!),
          if (finish != null) _row('Finish', finish!),
          if (p.artist != null) _row('Artist', p.artist!), // Scryfall attribution (Section 9)
          const SizedBox(height: 8),
          PriceEstimateText(price, foil: finish == 'foil'),
          const SizedBox(height: 16),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              LegalStrings.prices,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Colors.white60)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
