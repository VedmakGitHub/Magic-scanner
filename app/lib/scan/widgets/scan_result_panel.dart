import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';
import '../scan_session.dart';

/// The two stacked bottom elements on the Quick-ON scan screen:
///  - result panel: thumb + rarity set symbol + English name + (placeholder)
///    Buylist price + ">" (opens the edit panel);
///  - chip bar: Normal/Foil toggle · set symbol+#number (opens the version row)
///    · Language · +1 quantity.
/// Operates on the just-added [ScanSessionItem] by id; closes if it disappears.
class ScanResultPanel extends ConsumerWidget {
  final int itemId;
  final VoidCallback onOpenVersions;
  final VoidCallback onOpenEdit;
  final VoidCallback onClose;

  const ScanResultPanel({
    super.key,
    required this.itemId,
    required this.onOpenVersions,
    required this.onOpenEdit,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(scanSessionProvider);
    ScanSessionItem? item;
    for (final i in items) {
      if (i.id == itemId) item = i;
    }
    if (item == null) return const SizedBox.shrink();
    final it = item;
    final p = it.printing;
    final ctrl = ref.read(scanSessionProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // --- result panel ---------------------------------------------------
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 62,
                child: CardImage(printing: p, thumbnail: true),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        SetSymbol(setCode: p.setCode, rarity: p.rarity, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Buylist pricing is deferred — placeholder, addressed later.
                    Text('Buylist  —',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.greenAccent)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: onOpenEdit,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // --- chip bar -------------------------------------------------------
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(24),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _chip(
                label: _finishLabel(it.finish),
                onTap: p.finishes.length < 2 ? null : () => _cycleFinish(ctrl, it),
              ),
              _chip(
                leading: SetSymbol(setCode: p.setCode, rarity: p.rarity, size: 16),
                label: '#${p.collectorNumber}',
                onTap: onOpenVersions,
              ),
              _chip(
                label: p.lang.toUpperCase(),
                onTap: () => _pickLanguage(context, ref, it),
              ),
              _chip(
                leading: const Icon(Icons.add, size: 16, color: Colors.white),
                label: '${it.qty}',
                onTap: () => ctrl.update(it.id, qty: it.qty + 1),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip({String? label, Widget? leading, VoidCallback? onTap}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 4)],
              if (label != null)
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: onTap == null ? Colors.white38 : Colors.white,
                          fontWeight: FontWeight.w500)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _finishLabel(String f) => switch (f) {
        'nonfoil' => 'Normal',
        'foil' => 'Foil',
        'etched' => 'Etched',
        _ => f,
      };

  void _cycleFinish(ScanSessionController ctrl, ScanSessionItem it) {
    final fs = it.printing.finishes;
    final i = fs.indexOf(it.finish);
    ctrl.update(it.id, finish: fs[(i + 1) % fs.length]);
  }

  /// Swap to another language printing of the same (set, collector#).
  Future<void> _pickLanguage(
      BuildContext context, WidgetRef ref, ScanSessionItem it) async {
    final p = it.printing;
    final db = await ref.read(cardDatabaseProvider.future);
    final versions =
        groupCardVersions(await db.printingsForCard(p.name, oracleId: p.oracleId));
    CardVersion? match;
    for (final v in versions) {
      if (v.representative.setCode == p.setCode &&
          v.representative.collectorNumber == p.collectorNumber) {
        match = v;
      }
    }
    if (match == null || !context.mounted) return;
    final langs = match.languages;
    if (langs.length < 2) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final l in langs)
              ListTile(
                title: Text(l.toUpperCase()),
                trailing: l == p.lang ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, l),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      ref.read(scanSessionProvider.notifier).update(it.id, printing: match.forLang(chosen));
    }
  }
}
