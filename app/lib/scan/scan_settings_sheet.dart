import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/scan_settings.dart';

Future<void> showScanSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ScanSettingsSheet(),
  );
}

class _ScanSettingsSheet extends ConsumerWidget {
  const _ScanSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(scanSettingsProvider);
    final c = ref.read(scanSettingsProvider.notifier);
    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          Center(
            child: Text('Settings',
                style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: s.quickMode,
            onChanged: (v) => c.setQuickMode(v ?? false),
            title: const Text('Quick mode'),
            subtitle: const Text('Auto-add the newest printing; off = pick the version'),
            secondary: const Icon(Icons.bolt),
          ),
          ListTile(
            title: const Text('Lock set'),
            subtitle: Text(s.lockedSetCode == null
                ? 'Off — add cards from any set'
                : 'Locked to ${s.lockedSetCode!.toUpperCase()}'),
            trailing: s.lockedSetCode == null
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => c.setLockedSet(null),
                  ),
            onTap: () => _pickLockSet(context, ref),
          ),
          CheckboxListTile(
            value: s.ignorePromos,
            onChanged: (v) => c.setIgnorePromos(v ?? false),
            title: const Text('Ignore promos'),
          ),
          CheckboxListTile(
            value: s.preferFoil,
            onChanged: (v) => c.setPreferFoil(v ?? false),
            title: const Text('Prefer foil if possible'),
          ),
          CheckboxListTile(
            value: s.playSounds,
            onChanged: (v) => c.setPlaySounds(v ?? false),
            title: const Text('Play sounds'),
          ),
          CheckboxListTile(
            value: s.displayTotalValue,
            onChanged: (v) => c.setDisplayTotalValue(v ?? false),
            title: const Text('Display total value'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.help_outline),
            label: const Text('Scanning tips'),
            onPressed: () => _showTips(context),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLockSet(BuildContext context, WidgetRef ref) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LockSetSearch(),
    );
    if (code != null) ref.read(scanSettingsProvider.notifier).setLockedSet(code);
  }

  void _showTips(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Scanning tips'),
        content: const Text(
          'Place the card on a plain, evenly-lit surface. Fill the frame and '
          'hold steady until the outline turns and the card is recognized. '
          'Glare and sleeves with heavy tint can reduce accuracy.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Got it')),
        ],
      ),
    );
  }
}

class _LockSetSearch extends ConsumerStatefulWidget {
  const _LockSetSearch();
  @override
  ConsumerState<_LockSetSearch> createState() => _LockSetSearchState();
}

class _LockSetSearchState extends ConsumerState<_LockSetSearch> {
  List<({String code, String name})> _results = const [];

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    final db = await ref.read(cardDatabaseProvider.future);
    final r = await db.setSearch(q);
    if (mounted) setState(() => _results = r);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search sets',
                  border: OutlineInputBorder(),
                ),
                onChanged: _search,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in _results)
                    ListTile(
                      title: Text(s.name),
                      trailing: Text(s.code.toUpperCase()),
                      onTap: () => Navigator.pop(context, s.code),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
