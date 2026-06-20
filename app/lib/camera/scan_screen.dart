import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../data/scan_settings.dart';
import '../recognition/frame_processor.dart';
import '../recognition/matcher.dart';
import '../scan/feedback.dart';
import '../scan/scan_session.dart';
import '../scan/scan_settings_sheet.dart';
import '../scan/session_sheet.dart';
import '../scan/widgets/control_pill.dart';
import '../scan/widgets/scan_result_panel.dart';
import '../scan/widgets/version_row.dart';

/// Continuous, no-tap scan screen (ManaBox-style). The camera streams frames to
/// an off-isolate [FrameProcessor] (detect → warp → multi-scale hash); the
/// matcher runs here. On a confident match, Quick mode auto-adds the newest
/// printing and shows the result panel; otherwise it pauses and shows the
/// horizontal version row to pick the exact printing.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  FrameProcessor? _proc;
  bool _busy = false;
  bool _streaming = false;
  bool _flashOn = false;
  String? _error;

  // Detection / overlay.
  List<Offset>? _smoothQuad;
  int _imgW = 1, _imgH = 1;
  Offset? _lastCentroid;
  int _stableCount = 0;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRecognized = DateTime.fromMillisecondsSinceEpoch(0);

  // Recognition state.
  String? _lastAddedKey; // dedup until the card leaves the frame
  bool _paused = false; // true while the version row is up (Quick OFF / editing)
  int? _activeItemId; // result panel target (Quick ON)
  List<CardVersion>? _pendingVersions; // version row contents
  String _pendingName = '';
  int? _editingItemId; // when the version row edits an existing item

  static const _throttleMs = 90;
  static const _stableNeeded = 3;
  static const _cooldownMs = 1200;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      _proc = FrameProcessor();
      await _proc!.start();
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'No camera available on this device.');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(back, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _controller = c;
      await c.initialize();
      await c.startImageStream(_onFrame);
      _streaming = true;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _teardownCamera();
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  Future<void> _teardownCamera() async {
    final c = _controller;
    _controller = null;
    try {
      if (c != null && _streaming) await c.stopImageStream();
    } catch (_) {}
    _streaming = false;
    await c?.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final p = _proc;
    _proc = null;
    _teardownCamera();
    p?.dispose();
    super.dispose();
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _paused || _proc == null) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed).inMilliseconds < _throttleMs) return;
    _busy = true;
    _lastProcessed = now;
    try {
      final res = await _proc!.process(
        image.planes[0].bytes,
        image.width,
        image.height,
        _controller!.description.sensorOrientation,
      );
      if (!res.found) {
        _lastAddedKey = null; // card left the frame -> allow re-add
        _stableCount = 0;
        if (mounted && _smoothQuad != null) setState(() => _smoothQuad = null);
        return;
      }
      final quad = [
        for (var i = 0; i < 4; i++) Offset(res.quad[i * 2], res.quad[i * 2 + 1])
      ];
      _imgW = res.imageW;
      _imgH = res.imageH;
      final centroid = quad.reduce((a, b) => a + b) / 4.0;
      if (_lastCentroid != null && (centroid - _lastCentroid!).distance < 30) {
        _stableCount++;
      } else {
        _stableCount = 1;
      }
      _lastCentroid = centroid;
      if (mounted) setState(() => _smoothQuad = _smooth(_smoothQuad, quad));

      if (_stableCount >= _stableNeeded &&
          now.difference(_lastRecognized).inMilliseconds > _cooldownMs &&
          res.hashes != null) {
        await _handleMatch(res.hashes!);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _handleMatch(List<Uint8List> hashes) async {
    final svc = ref.read(recognitionServiceProvider).valueOrNull;
    if (svc == null) return;
    final top = svc.matcher.topKMulti(hashes);
    if (top.isEmpty || classify(top) != MatchConfidence.strong) return;
    final best = top.first;
    final ill = svc.matcher.illustrationIds[best.index];
    final sid = svc.matcher.scryfallIds[best.index];
    final key = ill ?? sid;
    if (key == _lastAddedKey) return; // already handled this card

    Printing? rep =
        ill != null ? await svc.cardDb.representativeForIllustration(ill) : null;
    rep ??= await svc.cardDb.getPrinting(sid);
    if (rep == null) return;
    final versions = groupCardVersions(
        await svc.cardDb.printingsForCard(rep.name, oracleId: rep.oracleId));
    if (versions.isEmpty) return;

    _lastRecognized = DateTime.now();
    _lastAddedKey = key;
    final s = ref.read(scanSettingsProvider);
    if (s.quickMode) {
      final v = _quickPick(versions, s);
      final item = ref.read(scanSessionProvider.notifier).add(
            v.representative,
            finish: _quickFinish(v.representative, s),
            distance: best.distance,
          );
      ScanFeedback.added(sound: s.playSounds);
      if (mounted) setState(() => _activeItemId = item.id);
    } else {
      if (mounted) {
        setState(() {
          _paused = true;
          _editingItemId = null;
          _pendingVersions = versions;
          _pendingName = rep!.name;
        });
      }
    }
  }

  CardVersion _quickPick(List<CardVersion> versions, ScanSettings s) {
    if (s.lockedSetCode != null) {
      for (final v in versions) {
        if (v.representative.setCode.toLowerCase() ==
            s.lockedSetCode!.toLowerCase()) {
          return v;
        }
      }
    }
    if (s.ignorePromos) {
      final nonPromo = versions
          .where((v) => !v.representative.setName.toLowerCase().contains('promo'))
          .toList();
      if (nonPromo.isNotEmpty) return nonPromo.first;
    }
    return versions.first; // newest (printings are ordered newest-first)
  }

  String _quickFinish(Printing p, ScanSettings s) {
    if (s.preferFoil && p.finishes.contains('foil')) return 'foil';
    if (p.finishes.contains('nonfoil')) return 'nonfoil';
    return p.finishes.isEmpty ? 'nonfoil' : p.finishes.first;
  }

  void _onPickVersion(CardVersion v) {
    final s = ref.read(scanSettingsProvider);
    final ctrl = ref.read(scanSessionProvider.notifier);
    if (_editingItemId != null) {
      ctrl.update(_editingItemId!,
          printing: v.representative, finish: _quickFinish(v.representative, s));
    } else {
      final item =
          ctrl.add(v.representative, finish: _quickFinish(v.representative, s));
      ScanFeedback.added(sound: s.playSounds);
      _activeItemId = item.id;
    }
    setState(() {
      _pendingVersions = null;
      _editingItemId = null;
      _paused = false;
      _lastRecognized = DateTime.now();
    });
  }

  Future<void> _openVersionsForItem(int itemId) async {
    final items = ref.read(scanSessionProvider);
    ScanSessionItem? it;
    for (final i in items) {
      if (i.id == itemId) it = i;
    }
    if (it == null) return;
    final svc = ref.read(recognitionServiceProvider).valueOrNull;
    if (svc == null) return;
    final versions = groupCardVersions(await svc.cardDb
        .printingsForCard(it.printing.name, oracleId: it.printing.oracleId));
    if (versions.isEmpty || !mounted) return;
    setState(() {
      _paused = true;
      _editingItemId = itemId;
      _pendingVersions = versions;
      _pendingName = it!.printing.name;
    });
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null) return;
    try {
      _flashOn = !_flashOn;
      await c.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  List<Offset> _smooth(List<Offset>? prev, List<Offset> cur) {
    if (prev == null || prev.length != 4) return cur;
    const a = 0.4;
    return [for (var i = 0; i < 4; i++) prev[i] * (1 - a) + cur[i] * a];
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final count = ref.watch(scanSessionProvider).fold<int>(0, (s, i) => s + i.qty);

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: c.value.previewSize?.height ?? 1080,
            height: c.value.previewSize?.width ?? 1920,
            child: CameraPreview(c),
          ),
        ),
        if (_smoothQuad != null && !_paused)
          Positioned.fill(
            child: CustomPaint(
              painter: _QuadPainter(
                  _smoothQuad!, _imgW.toDouble(), _imgH.toDouble()),
            ),
          ),
        Positioned(
          right: 8,
          top: 8,
          child: SafeArea(
            child: ScanControlPill(
              sessionCount: count,
              flashOn: _flashOn,
              onSession: () => showSessionSheet(context),
              onFlash: _toggleFlash,
              onSettings: () => showScanSettingsSheet(context),
            ),
          ),
        ),
        // Bottom overlay: version row (pick) takes precedence over result panel.
        if (_pendingVersions != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VersionRow(
              cardName: _pendingName,
              versions: _pendingVersions!,
              onPick: _onPickVersion,
              onClose: () => setState(() {
                _pendingVersions = null;
                _editingItemId = null;
                _paused = false;
                _lastRecognized = DateTime.now();
              }),
            ),
          )
        else if (_activeItemId != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: ScanResultPanel(
              itemId: _activeItemId!,
              onOpenVersions: () => _openVersionsForItem(_activeItemId!),
              onOpenEdit: () => showSessionSheet(context),
              onClose: () => setState(() => _activeItemId = null),
            ),
          ),
      ],
    );
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> quad;
  final double imgW, imgH;
  _QuadPainter(this.quad, this.imgW, this.imgH);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / imgW) > (size.height / imgH)
        ? size.width / imgW
        : size.height / imgH;
    final dx = (size.width - imgW * scale) / 2;
    final dy = (size.height - imgH * scale) / 2;
    Offset m(Offset p) => Offset(p.dx * scale + dx, p.dy * scale + dy);
    final path = Path()..addPolygon([for (final p in quad) m(p)], true);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFA000),
    );
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) => true;
}
