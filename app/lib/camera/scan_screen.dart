import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../data/scan_settings.dart';
import '../recognition/frame_processor.dart';
import '../recognition/ocr.dart';
import '../scan/edit_panel.dart';
import '../scan/feedback.dart';
import '../scan/scan_session.dart';
import '../scan/scan_settings_sheet.dart';
import '../scan/session_sheet.dart';
import '../scan/widgets/control_pill.dart';
import '../scan/widgets/scan_result_panel.dart';
import '../scan/widgets/version_row.dart';

/// DEBUG: log the top candidate + distance per recognition attempt (and the
/// top-3 on each add) so accuracy can be diagnosed from logcat.
const bool kScanDebug = true;

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
  bool _initing = false;
  String? _error;

  // Detection / overlay.
  List<Offset>? _smoothQuad;
  int _imgW = 1, _imgH = 1;
  Offset? _lastCentroid;
  int _stableCount = 0;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRecognized = DateTime.fromMillisecondsSinceEpoch(0);

  // Recognition state.
  String? _lastAddedKey; // last committed card (cleared when it leaves frame)
  int _noDetectStreak = 0; // consecutive no-card frames (re-arms _lastAddedKey)
  String? _pendingMatchKey; // candidate awaiting consecutive agreement
  int _pendingMatchCount = 0;
  final Map<String, Printing?> _printingCache = {}; // illustration/sid -> Printing?
  int _frames = 0; // fps window
  DateTime _fpsT0 = DateTime.now();
  bool _paused = false; // true while the version row is up (Quick OFF / editing)
  int? _activeItemId; // result panel target (Quick ON)
  List<CardVersion>? _pendingVersions; // version row contents
  String _pendingName = '';
  String? _pendingSelectedId; // highlight/first the matched version in the row
  int? _editingItemId; // when the version row edits an existing item

  static const _throttleMs = 90;
  static const _stableNeeded = 3;
  static const _cooldownMs = 1200;
  static const _consensus = 2; // agreeing frames for a marginal match
  static const _confidentSkipMargin = 12; // margin >= this -> commit on 1 frame
  static const _reArmNoDetect = 3; // no-card frames before the same card re-arms
  static const _maxMatchDist = 70; // best above this -> treat as no card
  static const _tieMargin = 4; // top-1 within this of top-2 -> OCR tiebreak only

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    if (_initing || _controller != null) return;
    _initing = true;
    try {
      if (_proc == null) {
        _proc = FrameProcessor();
        await _proc!.start();
      }
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _error = 'No camera available on this device.');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // High resolution for a sharp warp (hard retro frames need it); the
      // detector downscales internally for speed, so this stays responsive.
      final c = CameraController(back, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _controller = c;
      await c.initialize();
      await c.startImageStream(_onFrame);
      _streaming = true;
      _error = null;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera error: $e');
    } finally {
      _initing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _init();
    } else {
      // inactive / paused / hidden / detached: release the camera so its
      // ImageReader can't deliver a frame into a detaching engine (the
      // "FlutterJNI is not attached" native crash).
      _teardownCamera();
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
    final rotation = _controller!.description.sensorOrientation;
    // Copy once so the buffer stays valid across the awaits below.
    final bytes = Uint8List.fromList(image.planes[0].bytes);
    final w = image.width, h = image.height;
    try {
      // Fast, downscaled detection every frame -> smooth overlay + stability.
      final res = await _proc!.process(bytes, w, h, rotation, full: false);
      _trackFps(res.detectMs);
      if (!res.found) {
        _pendingMatchKey = null;
        _pendingMatchCount = 0;
        _stableCount = 0;
        if (++_noDetectStreak >= _reArmNoDetect) {
          _lastAddedKey = null; // card truly removed -> the same card can re-add
        }
        if (mounted && _smoothQuad != null) setState(() => _smoothQuad = null);
        return;
      }
      _noDetectStreak = 0;
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

      // Precise full-res warp + multi-scale hash only once the card is steady.
      if (_stableCount >= _stableNeeded &&
          now.difference(_lastRecognized).inMilliseconds > _cooldownMs) {
        final full = await _proc!.process(bytes, w, h, rotation, full: true);
        if (full.hashes != null) await _handleMatch(full);
      }
    } finally {
      _busy = false;
    }
  }

  void _trackFps(int fastDetectMs) {
    _frames++;
    final dt = DateTime.now().difference(_fpsT0).inMilliseconds;
    if (dt >= 2000) {
      if (kScanDebug) {
        debugPrint('scan fps=${(_frames * 1000 / dt).toStringAsFixed(1)} '
            'fastDetect=${fastDetectMs}ms session=${ref.read(scanSessionProvider).length}');
      }
      _frames = 0;
      _fpsT0 = DateTime.now();
    }
  }

  Future<void> _handleMatch(FrameResult res) async {
    final hashes = res.hashes;
    if (hashes == null) return;
    final svc = ref.read(recognitionServiceProvider).valueOrNull;
    if (svc == null) return;
    Future<Printing?> resolve(int index) async {
      final il = svc.matcher.illustrationIds[index];
      final sd = svc.matcher.scryfallIds[index];
      final ckey = il ?? sd;
      if (_printingCache.containsKey(ckey)) return _printingCache[ckey];
      Printing? pr =
          il != null ? await svc.cardDb.representativeForIllustration(il) : null;
      pr ??= await svc.cardDb.getPrinting(sd);
      _printingCache[ckey] = pr;
      return pr;
    }

    final sw = Stopwatch()..start();
    final top = svc.matcher.topKMulti(hashes);
    final matchMs = sw.elapsedMilliseconds;
    if (top.isEmpty) {
      _pendingMatchKey = null;
      _pendingMatchCount = 0;
      return;
    }
    final best = top.first.distance;
    if (best > _maxMatchDist) {
      _pendingMatchKey = null;
      _pendingMatchCount = 0;
      return; // no plausible card in view
    }

    final second = top.length > 1 ? top[1].distance : 999;
    final nearTie = (second - best) <= _tieMargin;

    // Trust the multi-scale rank-1 (15/15 on the benchmark). Only when the top
    // two are a near-tie do we OCR the card name to break it — keeps the common
    // case fast and reserves OCR for genuine ambiguity.
    var chosen = 0;
    var ocrMs = 0;
    if (nearTie && res.warpJpeg != null) {
      final s2 = Stopwatch()..start();
      final names = [for (final mm in top) (await resolve(mm.index))?.name ?? ''];
      final text = await CardOcr.readText(res.warpJpeg!);
      final picked = CardOcr.bestMatch(text, names);
      ocrMs = s2.elapsedMilliseconds;
      if (picked >= 0) chosen = picked;
      if (kScanDebug) {
        debugPrint('scan OCR(${ocrMs}ms) -> '
            '${picked >= 0 ? names[picked] : "(no match)"} | cands=${names.take(3).join("|")}');
      }
    }

    final m = top[chosen];
    final ill = svc.matcher.illustrationIds[m.index];
    final sid = svc.matcher.scryfallIds[m.index];
    final key = ill ?? sid;

    if (kScanDebug) {
      final pr = await resolve(m.index);
      debugPrint('scan pick=${pr?.name ?? "?"} dist=${m.distance} '
          'margin=${second - best} tie=$nearTie detect=${res.detectMs}ms '
          'match=${matchMs}ms ocr=${ocrMs}ms pend=$_pendingMatchCount '
          'breakdown=${res.timings}');
    }

    // Adaptive consensus: a clearly confident match (large margin to #2) commits
    // on the first stable frame; marginal/near-tie matches need _consensus
    // agreeing frames to reject transient mis-identifications.
    final needed = (second - best) >= _confidentSkipMargin ? 1 : _consensus;
    if (key == _pendingMatchKey) {
      _pendingMatchCount++;
    } else {
      _pendingMatchKey = key;
      _pendingMatchCount = 1;
    }
    if (_pendingMatchCount < needed) return;
    if (key == _lastAddedKey) return; // still in view -> don't duplicate

    final rep = await resolve(m.index);
    if (rep == null) return;
    final versions = groupCardVersions(
        await svc.cardDb.printingsForCard(rep.name, oracleId: rep.oracleId));
    if (versions.isEmpty) return;

    if (kScanDebug) {
      final parts = <String>[];
      for (var i = 0; i < top.length && i < 5; i++) {
        final pr = await resolve(top[i].index);
        parts.add('${top[i].distance}:${pr?.name ?? "?"}');
      }
      debugPrint('scan ADD ${rep.name} | top5: ${parts.join("  ")}');
    }

    _lastRecognized = DateTime.now();
    _lastAddedKey = key;
    _pendingMatchKey = null;
    _pendingMatchCount = 0;
    final s = ref.read(scanSettingsProvider);
    if (s.quickMode) {
      // Default to the MATCHED artwork's printing (the scanned set/version);
      // Lock-set overrides the set, Prefer-foil sets the finish.
      final chosen = _resolveQuickPrinting(rep, versions, s);
      final item = ref.read(scanSessionProvider.notifier).add(
            chosen,
            finish: _quickFinish(chosen, s),
            distance: m.distance,
          );
      ScanFeedback.added(sound: s.playSounds);
      if (mounted) setState(() => _activeItemId = item.id);
    } else {
      final mf = _matchedFirst(versions, rep);
      if (mounted) {
        setState(() {
          _paused = true;
          _editingItemId = null;
          _pendingVersions = mf.ordered;
          _pendingSelectedId = mf.selectedId;
          _pendingName = rep.name;
        });
      }
    }
  }

  /// The printing to auto-add in Quick mode: the matched artwork's printing by
  /// default (so the scanned set/version wins), overridden by a Locked set.
  Printing _resolveQuickPrinting(
      Printing matched, List<CardVersion> versions, ScanSettings s) {
    if (s.lockedSetCode != null) {
      for (final v in versions) {
        if (v.representative.setCode.toLowerCase() ==
            s.lockedSetCode!.toLowerCase()) {
          return v.representative;
        }
      }
    }
    return matched;
  }

  /// Order so versions sharing the MATCHED artwork (illustration) come first,
  /// newest-to-oldest, then versions of the same card with a different artwork.
  /// Returns the id of the newest same-artwork version to highlight it.
  /// (`versions` is already newest-first, so each partition keeps that order.)
  ({List<CardVersion> ordered, String? selectedId}) _matchedFirst(
      List<CardVersion> versions, Printing matched) {
    final ill = matched.illustrationId;
    if (ill == null) {
      // No illustration id: fall back to putting the exact (set, #) first.
      final copy = [...versions];
      final i = copy.indexWhere((v) =>
          v.representative.setCode == matched.setCode &&
          v.representative.collectorNumber == matched.collectorNumber);
      if (i < 0) return (ordered: copy, selectedId: null);
      final sel = copy[i].representative.scryfallId;
      if (i > 0) copy.insert(0, copy.removeAt(i));
      return (ordered: copy, selectedId: sel);
    }
    final same = <CardVersion>[];
    final others = <CardVersion>[];
    for (final v in versions) {
      (v.representative.illustrationId == ill ? same : others).add(v);
    }
    return (
      ordered: [...same, ...others],
      selectedId: same.isNotEmpty
          ? same.first.representative.scryfallId
          : matched.scryfallId,
    );
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
      _pendingSelectedId = null;
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
    final mf = _matchedFirst(versions, it.printing);
    setState(() {
      _paused = true;
      _editingItemId = itemId;
      _pendingVersions = mf.ordered;
      _pendingSelectedId = mf.selectedId;
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
      // Self-heal: if the camera was lost (memory pressure, returning from a
      // sheet), re-initialize instead of showing a permanent spinner.
      if (_error == null && !_initing) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => mounted ? _init() : null);
      }
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
              selectedScryfallId: _pendingSelectedId,
              onPick: _onPickVersion,
              onClose: () => setState(() {
                _pendingVersions = null;
                _pendingSelectedId = null;
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
              onOpenEdit: () => showEditPanel(context, _activeItemId!),
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
