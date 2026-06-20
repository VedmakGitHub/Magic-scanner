import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import 'version_tile.dart';

/// Full-screen "Search sets" grid of every version of a card (all artworks /
/// sets, English representative per set+collector#). Returns the chosen
/// representative [Printing], or null if dismissed.
Future<Printing?> showVersionGrid(
  BuildContext context, {
  required String cardName,
  String? oracleId,
  String? selectedScryfallId,
}) {
  return Navigator.of(context).push<Printing>(MaterialPageRoute(
    builder: (_) => _VersionGridScreen(
      cardName: cardName,
      oracleId: oracleId,
      selectedScryfallId: selectedScryfallId,
    ),
  ));
}

class _VersionGridScreen extends ConsumerStatefulWidget {
  final String cardName;
  final String? oracleId;
  final String? selectedScryfallId;
  const _VersionGridScreen({
    required this.cardName,
    this.oracleId,
    this.selectedScryfallId,
  });

  @override
  ConsumerState<_VersionGridScreen> createState() => _VersionGridScreenState();
}

class _VersionGridScreenState extends ConsumerState<_VersionGridScreen> {
  List<CardVersion> _all = const [];
  bool _loading = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await ref.read(cardDatabaseProvider.future);
    final versions = groupCardVersions(
        await db.printingsForCard(widget.cardName, oracleId: widget.oracleId));
    if (mounted) {
      setState(() {
        _all = versions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? _all
        : _all.where((v) {
            final p = v.representative;
            return '${p.setName} ${p.setCode}'.toLowerCase().contains(_filter);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search sets',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty
              ? const Center(child: Text('No matching versions'))
              : GridView.builder(
                  padding: const EdgeInsets.all(10),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.56,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => VersionTile(
                    version: filtered[i],
                    selected: filtered[i].representative.scryfallId ==
                        widget.selectedScryfallId,
                    onTap: () =>
                        Navigator.of(context).pop(filtered[i].representative),
                  ),
                ),
    );
  }
}
