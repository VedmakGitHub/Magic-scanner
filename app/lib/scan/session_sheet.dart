import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets.dart';
import 'edit_panel.dart';
import 'scan_session.dart';

Future<void> showSessionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SessionSheet(),
  );
}

class _SessionSheet extends ConsumerWidget {
  const _SessionSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(scanSessionProvider);
    final ctrl = ref.read(scanSessionProvider.notifier);
    final count = items.fold<int>(0, (s, i) => s + i.qty);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('$count card${count == 1 ? '' : 's'} scanned',
                style: Theme.of(context).textTheme.titleLarge),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No cards scanned yet.'))
                : ListView.separated(
                    controller: scroll,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _row(context, ctrl, items[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: items.isEmpty
                          ? null
                          : () {
                              ctrl.clear();
                              Navigator.pop(context);
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: items.isEmpty
                          ? null
                          : () async {
                              await ctrl.commitToCollection();
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'Added $count card${count == 1 ? '' : 's'} to your collection')),
                                );
                              }
                            },
                      icon: const Icon(Icons.add),
                      label: const Text('Add to'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ScanSessionController ctrl, ScanSessionItem it) {
    final p = it.printing;
    final price = p.priceForFinish(it.finish);
    return ListTile(
      onTap: () => showEditPanel(context, it.id),
      leading: SizedBox(width: 40, height: 56, child: CardImage(printing: p, thumbnail: true)),
      title: Text('${it.qty}x ${p.name}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          SetSymbol(setCode: p.setCode, rarity: p.rarity, size: 14),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${p.setName} #${p.collectorNumber} · ${p.lang.toUpperCase()} · ${it.condition.code}'
              '${price == null ? '' : ' · ~\$${price.toStringAsFixed(2)}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showEditPanel(context, it.id),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => ctrl.remove(it.id),
          ),
        ],
      ),
    );
  }
}
