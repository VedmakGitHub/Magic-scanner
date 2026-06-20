import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../ui/widgets.dart';

/// Version picker — choose the exact set/printing + finish for the matched
/// artwork (Section 6 step 7, 8.4). Returns true if a card was added.
Future<bool?> showVersionPicker(
  BuildContext context,
  WidgetRef ref,
  Candidate candidate,
) async {
  final cards = await ref.read(cardDatabaseProvider.future);
  List<Printing> printings;
  if (candidate.illustrationId != null) {
    printings = await cards.printingsByIllustration(candidate.illustrationId!);
  } else {
    final single = await cards.getPrinting(candidate.scryfallId, face: candidate.face);
    printings = single == null ? const [] : [single];
  }
  // Collapse to one entry per printing (front face represents a DFC).
  final byId = <String, Printing>{};
  for (final p in printings) {
    final existing = byId[p.scryfallId];
    if (existing == null || (existing.face != 'front' && p.face == 'front')) {
      byId[p.scryfallId] = p;
    }
  }
  final list = byId.values.toList();
  if (!context.mounted) return false;

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _VersionPicker(printings: list),
  );
}

class _VersionPicker extends ConsumerWidget {
  final List<Printing> printings;
  const _VersionPicker({required this.printings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('Choose the printing',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: printings.length,
                itemBuilder: (context, i) {
                  final p = printings[i];
                  return _PrintingTile(
                    printing: p,
                    onPickFinish: (finish) => _add(context, ref, p, finish),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _add(
      BuildContext context, WidgetRef ref, Printing p, String finish) async {
    await ref.read(collectionControllerProvider.notifier).add(p.scryfallId, finish);
    if (context.mounted) Navigator.of(context).pop(true);
  }
}

class _PrintingTile extends StatelessWidget {
  final Printing printing;
  final ValueChanged<String> onPickFinish;
  const _PrintingTile({required this.printing, required this.onPickFinish});

  @override
  Widget build(BuildContext context) {
    final finishes =
        printing.finishes.isEmpty ? const ['nonfoil'] : printing.finishes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                height: 67,
                child: CardImage(printing: printing, thumbnail: true),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(printing.setName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      '${printing.setCode.toUpperCase()} · #${printing.collectorNumber}'
                      '${printing.rarity != null ? ' · ${printing.rarity}' : ''}'
                      '${printing.releasedAt != null ? ' · ${printing.releasedAt}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final f in finishes)
                          ActionChip(
                            label: Text(_finishLabel(f)),
                            avatar: const Icon(Icons.add, size: 16),
                            onPressed: () => onPickFinish(f),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _finishLabel(String f) {
    switch (f) {
      case 'nonfoil':
        return 'Nonfoil';
      case 'foil':
        return 'Foil';
      case 'etched':
        return 'Etched';
      default:
        return f;
    }
  }
}
