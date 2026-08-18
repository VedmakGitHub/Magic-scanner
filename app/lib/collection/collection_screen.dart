import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../ui/widgets.dart';
import 'card_detail_screen.dart';

/// Collection list: search, quantity badges, per-finish entries, edit, delete,
/// and an optional estimated total (Sections 8.5, 9).
class CollectionScreen extends ConsumerStatefulWidget {
  const CollectionScreen({super.key});

  @override
  ConsumerState<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<CollectionScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(collectionControllerProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search your collection by name or set',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load collection: $e')),
            data: (entries) => _buildList(context, entries),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<CollectionEntry> all) {
    final filtered = _query.isEmpty
        ? all
        : all.where((e) {
            final p = e.printing;
            final hay =
                '${p?.name ?? ''} ${p?.setName ?? ''} ${p?.setCode ?? ''}'
                    .toLowerCase();
            return hay.contains(_query);
          }).toList();

    if (all.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Your collection is empty.\nScan a card to add it.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (filtered.isEmpty) {
      return const Center(child: Text('No matches.'));
    }

    final total = _estimatedTotal(filtered);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_cardCount(filtered)} cards',
                  style: Theme.of(context).textTheme.bodySmall),
              Text('Est. total ~\$${total.toStringAsFixed(2)} (may be stale)',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _entryTile(context, filtered[i]),
          ),
        ),
      ],
    );
  }

  int _cardCount(List<CollectionEntry> e) =>
      e.fold(0, (sum, x) => sum + x.quantity);

  double _estimatedTotal(List<CollectionEntry> entries) {
    var sum = 0.0;
    for (final e in entries) {
      final p = e.printing;
      if (p == null) continue;
      final unit = e.finish == 'nonfoil' ? p.priceUsd : (p.priceUsdFoil ?? p.priceUsd);
      if (unit != null) sum += unit * e.quantity;
    }
    return sum;
  }

  Widget _entryTile(BuildContext context, CollectionEntry e) {
    final p = e.printing;
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 62,
        child: p == null
            ? const Icon(Icons.image_not_supported_outlined)
            : CardImage(printing: p, thumbnail: true),
      ),
      title: Text(p?.name ?? e.scryfallId,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${p?.setName ?? ''} · ${e.finish}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _QuantityControls(entry: e),
      onTap: p == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CardDetailScreen(printing: p, finish: e.finish),
              )),
    );
  }
}

class _QuantityControls extends ConsumerWidget {
  final CollectionEntry entry;
  const _QuantityControls({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(collectionControllerProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => controller.setQuantity(entry.id, entry.quantity - 1),
        ),
        Text('${entry.quantity}',
            style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => controller.setQuantity(entry.id, entry.quantity + 1),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete(context, ref),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from collection?'),
        content: Text('${entry.printing?.name ?? entry.scryfallId} (${entry.finish})'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(collectionControllerProvider.notifier).remove(entry.id);
    }
  }
}
