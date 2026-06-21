import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'version_tile.dart';

/// Scan-time version picker: a "Filter sets" field above a horizontally
/// scrollable row of card versions, overlaid on the bottom of the live preview.
/// Used by Quick-OFF (auto) and by the Quick-ON chip bar's version chip.
class VersionRow extends StatefulWidget {
  final String cardName;
  final List<CardVersion> versions;
  final String? selectedScryfallId;
  final ValueChanged<CardVersion> onPick;
  final VoidCallback onClose;

  const VersionRow({
    super.key,
    required this.cardName,
    required this.versions,
    required this.onPick,
    required this.onClose,
    this.selectedScryfallId,
  });

  @override
  State<VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<VersionRow> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final filtered = _filter.isEmpty
        ? widget.versions
        : widget.versions.where((v) {
            final p = v.representative;
            return '${p.setName} ${p.setCode}'.toLowerCase().contains(_filter);
          }).toList();

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF21B1C1F),
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.cardName,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter sets',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 230,
              child: filtered.isEmpty
                  ? const Center(child: Text('No matching sets'))
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => VersionTile(
                        version: filtered[i],
                        width: 150,
                        selected: filtered[i].representative.scryfallId ==
                            widget.selectedScryfallId,
                        onTap: () => widget.onPick(filtered[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
