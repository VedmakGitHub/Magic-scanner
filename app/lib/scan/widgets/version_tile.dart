import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../ui/widgets.dart';

/// One pickable card version (a unique set/collector# artwork): full card image
/// with a rarity-colored set symbol and "Set Name (CODE) #num" beneath. Shared
/// by the scan-time horizontal row and the edit-panel grid.
class VersionTile extends StatelessWidget {
  final CardVersion version;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  const VersionTile({
    super.key,
    required this.version,
    required this.onTap,
    this.width = 116,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = version.representative;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 488 / 680,
              child: CardImage(printing: p, thumbnail: false),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetSymbol(setCode: p.setCode, rarity: p.rarity, size: 14),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    p.setName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            Text(
              '(${p.setCode.toUpperCase()}) #${p.collectorNumber}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
