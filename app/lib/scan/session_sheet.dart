import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/widgets.dart';
import 'edit_panel.dart';
import 'manual_search.dart';
import 'scan_session.dart';

Future<void> showSessionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SessionSheet(),
  );
}

class _SessionSheet extends ConsumerStatefulWidget {
  const _SessionSheet();

  @override
  ConsumerState<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends ConsumerState<_SessionSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(scanSessionProvider);
    final ctrl = ref.read(scanSessionProvider.notifier);
    final count = items.fold<int>(0, (s, i) => s + i.qty);
    final filtered = _query.isEmpty
        ? items
        : items.where((i) {
            final p = i.printing;
            return '${p.name} ${p.setName} ${p.setCode}'
                .toLowerCase()
                .contains(_query);
          }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('$count card${count == 1 ? '' : 's'} scanned',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'clear' && items.isNotEmpty) ctrl.clear();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'clear', child: Text('Clear all')),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search cards',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add a card by name',
                  onPressed: () => showManualSearch(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No cards scanned yet.'))
                : filtered.isEmpty
                    ? const Center(child: Text('No matches.'))
                    : ListView.separated(
                        controller: scroll,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _row(context, ctrl, filtered[i]),
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
      leading:
          SizedBox(width: 40, height: 56, child: CardImage(printing: p, thumbnail: true)),
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
