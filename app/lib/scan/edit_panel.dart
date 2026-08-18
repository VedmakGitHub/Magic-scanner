import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../ui/widgets.dart';
import 'scan_session.dart';
import 'widgets/version_grid.dart';

/// Single-card detail editor for one staged [ScanSessionItem], reached from the
/// session list (pencil) or the result panel's ">". Edits a local working copy;
/// "Save" writes it back to the session. Set/Version opens the full grid.
Future<void> showEditPanel(BuildContext context, int itemId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EditPanel(itemId: itemId),
  );
}

class _EditPanel extends ConsumerStatefulWidget {
  final int itemId;
  const _EditPanel({required this.itemId});

  @override
  ConsumerState<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends ConsumerState<_EditPanel> {
  late Printing _printing;
  late String _finish;
  late Condition _condition;
  late int _qty;
  List<CardVersion> _versions = const [];
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    ScanSessionItem? it;
    for (final i in ref.read(scanSessionProvider)) {
      if (i.id == widget.itemId) it = i;
    }
    if (it == null) {
      _missing = true;
      _printing = _placeholder();
      _finish = 'nonfoil';
      _condition = Condition.nm;
      _qty = 1;
      return;
    }
    _printing = it.printing;
    _finish = it.finish;
    _condition = it.condition;
    _qty = it.qty;
    _loadVersions();
  }

  Printing _placeholder() => const Printing(
        scryfallId: '',
        name: '',
        setCode: '',
        setName: '',
        collectorNumber: '',
        finishes: ['nonfoil'],
        lang: 'en',
        face: 'front',
      );

  Future<void> _loadVersions() async {
    final db = await ref.read(cardDatabaseProvider.future);
    final v = groupCardVersions(
        await db.printingsForCard(_printing.name, oracleId: _printing.oracleId));
    if (mounted) setState(() => _versions = v);
  }

  CardVersion? get _currentVersion {
    for (final v in _versions) {
      if (v.representative.setCode == _printing.setCode &&
          v.representative.collectorNumber == _printing.collectorNumber) {
        return v;
      }
    }
    return null;
  }

  int get _ownedCount {
    final entries = ref.watch(collectionControllerProvider).valueOrNull ?? const [];
    var n = 0;
    for (final e in entries) {
      if (e.scryfallId == _printing.scryfallId) n += e.quantity;
    }
    return n;
  }

  void _save() {
    ref.read(scanSessionProvider.notifier).update(
          widget.itemId,
          printing: _printing,
          finish: _finish,
          condition: _condition,
          qty: _qty,
        );
    Navigator.of(context).pop();
  }

  Future<void> _changeVersion() async {
    final chosen = await showVersionGrid(
      context,
      cardName: _printing.name,
      oracleId: _printing.oracleId,
      selectedScryfallId: _printing.scryfallId,
    );
    if (chosen == null) return;
    setState(() {
      _printing = chosen;
      _finish = chosen.finishes.contains('nonfoil')
          ? 'nonfoil'
          : (chosen.finishes.isEmpty ? 'nonfoil' : chosen.finishes.first);
    });
  }

  void _toggleFoil() {
    final fs = _printing.finishes;
    if (fs.length < 2) return;
    setState(() => _finish = fs[(fs.indexOf(_finish) + 1) % fs.length]);
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('This card is no longer in the session.')),
      );
    }
    final p = _printing;
    final price = p.priceForFinish(_finish);
    final langs = _currentVersion?.languages ?? [p.lang];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.name,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            Text('In collection: $_ownedCount',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _imageColumn(p, price),
                const SizedBox(width: 16),
                Expanded(child: _controls(context, langs)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: null, // Extra attributes — deferred
                    icon: const Icon(Icons.tune),
                    label: const Text('Extra'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: null, // Purchase price — deferred
                    icon: const Icon(Icons.attach_money),
                    label: const Text('Purchase price'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageColumn(Printing p, double? price) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 120,
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 488 / 680,
                child: CardImage(printing: p, thumbnail: false),
              ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: Colors.black54,
                  child: Text('#${p.collectorNumber}',
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(price == null ? '—' : '\$${price.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _controls(BuildContext context, List<String> langs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _changeVersion,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                SetSymbol(setCode: _printing.setCode, rarity: _printing.rarity, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_printing.setName,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _labeled(
          'Quantity',
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
              ),
              Text('$_qty', style: Theme.of(context).textTheme.titleMedium),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => _qty++),
              ),
            ],
          ),
        ),
        _labeled(
          'Foil',
          OutlinedButton(
            onPressed: _printing.finishes.length < 2 ? null : _toggleFoil,
            child: Text(_finishLabel(_finish)),
          ),
        ),
        _labeled(
          'Language',
          DropdownButton<String>(
            value: langs.contains(_printing.lang) ? _printing.lang : langs.first,
            isExpanded: true,
            items: [
              for (final l in langs)
                DropdownMenuItem(value: l, child: Text(l.toUpperCase())),
            ],
            onChanged: (l) {
              final v = _currentVersion;
              if (l == null || v == null) return;
              setState(() => _printing = v.forLang(l));
            },
          ),
        ),
        _labeled(
          'Condition',
          DropdownButton<Condition>(
            value: _condition,
            isExpanded: true,
            items: [
              for (final c in Condition.values)
                DropdownMenuItem(value: c, child: Text(c.label)),
            ],
            onChanged: (c) => setState(() => _condition = c ?? Condition.nm),
          ),
        ),
      ],
    );
  }

  Widget _labeled(String label, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 88, child: Text(label)),
            Expanded(child: Align(alignment: Alignment.centerRight, child: child)),
          ],
        ),
      );

  String _finishLabel(String f) => switch (f) {
        'nonfoil' => 'Normal',
        'foil' => 'Foil',
        'etched' => 'Etched',
        _ => f,
      };
}
