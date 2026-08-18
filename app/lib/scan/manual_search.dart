import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../ui/widgets.dart';
import 'scan_session.dart';

/// Manual fallback: find a card by name/set when recognition misses, then pick
/// the exact printing + finish and add it. Uses the bundle data already on
/// device (CardDatabase.search). Useful for debugging recognition too.
Future<bool?> showManualSearch(BuildContext context) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const ManualSearchScreen()),
  );
}

class ManualSearchScreen extends ConsumerStatefulWidget {
  const ManualSearchScreen({super.key});

  @override
  ConsumerState<ManualSearchScreen> createState() => _ManualSearchScreenState();
}

class _ManualSearchScreenState extends ConsumerState<ManualSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Printing> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    final db = await ref.read(cardDatabaseProvider.future);
    final res = await db.search(q, limit: 60);
    if (mounted) {
      setState(() {
        _results = res;
        _loading = false;
      });
    }
  }

  Future<void> _pick(Printing p) async {
    ref.read(scanSessionProvider.notifier).add(p);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to the scan session')),
      );
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search card name or set…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                setState(() => _results = []);
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: Text(
                    _controller.text.trim().length < 2
                        ? 'Type at least 2 characters'
                        : 'No matches',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = _results[i];
                    return ListTile(
                      leading: SizedBox(
                        width: 44,
                        height: 62,
                        child: CardImage(printing: p, thumbnail: true),
                      ),
                      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${p.setName} (${p.setCode.toUpperCase()})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pick(p),
                    );
                  },
                ),
    );
  }
}
