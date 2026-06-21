import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../ui/widgets.dart';

/// One pickable card version (a unique set/collector# artwork): full card image
/// with a rarity-colored set symbol and "Set Name (CODE) #num" beneath. Shared
/// by the scan-time horizontal row and the edit-panel grid. The image uses
/// [Expanded] so the tile fills its cell exactly (no overflow) and shows the
/// whole card (BoxFit.contain — never cropped).
class VersionTile extends StatelessWidget {
  final CardVersion version;
  final double? width; // null = fill the parent cell (grid); set for the row
  final bool selected;
  final VoidCallback onTap;

  const VersionTile({
    super.key,
    required this.version,
    required this.onTap,
    this.width,
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
          children: [
            Expanded(
              child: CardImage(printing: p, thumbnail: false, fit: BoxFit.contain),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SetSymbol(setCode: p.setCode, rarity: p.rarity, size: 13),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    p.setName,
                    maxLines: 1,
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
