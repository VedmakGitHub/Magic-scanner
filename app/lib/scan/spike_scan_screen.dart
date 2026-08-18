import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../data/providers.dart';
import '../recognition/card_detector.dart';
import '../recognition/frame_processor.dart';
import '../recognition/phash.dart';

/// PHASE 0 SPIKE (labeled accuracy test). Loads a predetermined ordered card
/// list (assets/testlist.json); the operator scans each card in order (stream
/// auto-recognizes + a Still A/B), tagging every scan with the card number so
/// results can be scored against ground truth offline.
class SpikeScanScreen extends ConsumerStatefulWidget {
  const SpikeScanScreen({super.key});

  @override
  ConsumerState<SpikeScanScreen> createState() => _SpikeScanScreenState();
}

class _SpikeScanScreenState extends ConsumerState<SpikeScanScreen> {
  CameraController? _controller;
  FrameProcessor? _proc;
  bool _busy = false;
  bool _streaming = false;
  int _seq = 0;

  List<dynamic> _list = const [];
  int _card = 0; // 0-based index into _list

  List<Offset>? _smoothQuad;
  int _imgW = 1, _imgH = 1;

  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRecognized = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastCentroid;
  int _stableCount = 0;

  int _frames = 0;
  DateTime _fpsT0 = DateTime.now();
  double _fps = 0;

  String _status = 'starting…';
  String _lastMatch = '';
  String _docsDir = '';

  static const _throttleMs = 90;
  static const _stableNeeded = 3;
  static const _recogCooldownMs = 1200;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _docsDir = (await getApplicationDocumentsDirectory()).path;
      await _clearOld();
      try {
        _list = jsonDecode(await rootBundle.loadString('assets/testlist.json')) as List;
      } catch (_) {}
      await _log('=== labeled test ${DateTime.now().toIso8601String()} '
          '(${_list.length} cards) ===');
      _proc = FrameProcessor();
      await _proc!.start();
      final cams = await availableCameras();
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
      if (mounted) setState(() => _status = 'scanning…');
    } catch (e) {
      if (mounted) setState(() => _status = 'init error: $e');
    }
  }

  Future<void> _clearOld() async {
    try {
      final d = Directory(_docsDir);
      for (final f in d.listSync()) {
        final n = f.path.split(Platform.pathSeparator).last;
        if (n.startsWith('scan_') || n == 'spike_log.txt') {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  int get _cardNo => _card + 1;
  String get _cardName => _card < _list.length ? (_list[_card]['name'] ?? '?') : '?';
  String get _cardInfo => _card < _list.length ? (_list[_card]['info'] ?? '') : '';
  String _pad(int n) => n.toString().padLeft(3, '0');

  Future<void> _log(String line) async {
    try {
      await File('$_docsDir/spike_log.txt')
          .writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Future<void> _save(String name, Uint8List bytes) async {
    try {
      await File('$_docsDir/$name').writeAsBytes(bytes);
    } catch (_) {}
  }

  Future<void> _logMatch(int seq, String src, List<Uint8List> hashes, int detMs) async {
    final svc = ref.read(recognitionServiceProvider).valueOrNull;
    if (svc == null) return;
    final sw = Stopwatch()..start();
    final top = svc.matcher.topKMulti(hashes);
    final ms = sw.elapsedMilliseconds;
    final parts = <String>[];
    for (var i = 0; i < top.length && i < 5; i++) {
      final ill = svc.matcher.illustrationIds[top[i].index];
      final pr = ill != null ? await svc.cardDb.representativeForIllustration(ill) : null;
      parts.add('${top[i].distance}:${pr?.name ?? "?"}[${pr?.setCode ?? "?"}]');
    }
    await _log('[#${_pad(seq)}] c$_cardNo "$_cardName" $src det=${detMs}ms '
        'match=${ms}ms fps=${_fps.toStringAsFixed(1)} | ${parts.join("  ")}');
    if (mounted) {
      setState(() => _lastMatch = parts.isNotEmpty ? '$src ${parts.first}' : 'no match');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    _frames++;
    final now = DateTime.now();
    final dtFps = now.difference(_fpsT0).inMilliseconds;
    if (dtFps >= 1000) {
      _fps = _frames * 1000 / dtFps;
      _frames = 0;
      _fpsT0 = now;
    }
    if (_busy || _proc == null) return;
    if (now.difference(_lastProcessed).inMilliseconds < _throttleMs) return;
    _busy = true;
    _lastProcessed = now;
    try {
      final res = await _proc!.process(
        image.planes[0].bytes,
        image.width,
        image.height,
        _controller!.description.sensorOrientation,
        full: true,
      );
      if (!res.found) {
        _smoothQuad = null;
        _stableCount = 0;
        if (mounted) setState(() => _status = 'no card  ${_fps.toStringAsFixed(1)}fps');
        return;
      }
      final quad = [
        for (var i = 0; i < 4; i++) Offset(res.quad[i * 2], res.quad[i * 2 + 1])
      ];
      _imgW = res.imageW;
      _imgH = res.imageH;
      _smoothQuad = _smooth(_smoothQuad, quad);
      final centroid = quad.reduce((a, b) => a + b) / 4.0;
      if (_lastCentroid != null && (centroid - _lastCentroid!).distance < 30) {
        _stableCount++;
      } else {
        _stableCount = 1;
      }
      _lastCentroid = centroid;
      if (_stableCount >= _stableNeeded &&
          now.difference(_lastRecognized).inMilliseconds > _recogCooldownMs &&
          res.hashes != null) {
        _lastRecognized = now;
        final seq = _seq++;
        if (res.warpJpeg != null) {
          await _save('scan_${_pad(seq)}_c${_cardNo}_stream_warp.jpg', res.warpJpeg!);
        }
        await _logMatch(seq, 'STREAM', res.hashes!, res.detectMs);
      }
      if (mounted) {
        setState(() =>
            _status = 'card stable=$_stableCount ${_fps.toStringAsFixed(1)}fps');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _stillAB() async {
    final c = _controller;
    if (c == null) return;
    try {
      if (_streaming) {
        await c.stopImageStream();
        _streaming = false;
      }
      final shot = await c.takePicture();
      final bytes = await shot.readAsBytes();
      final seq = _seq++;
      await _save('scan_${_pad(seq)}_c${_cardNo}_still_full.jpg', bytes);
      final warp = detectAndWarpCard(bytes);
      if (warp == null) {
        await _log('[#${_pad(seq)}] c$_cardNo "$_cardName" STILL NO-DETECT');
        if (mounted) setState(() => _lastMatch = 'STILL no-detect');
      } else {
        await _save('scan_${_pad(seq)}_c${_cardNo}_still_warp.jpg',
            Uint8List.fromList(img.encodeJpg(warp, quality: 88)));
        await _logMatch(seq, 'STILL', PerceptualHash.multiScale(warp), 0);
      }
    } catch (e) {
      await _log('STILL error: $e');
    } finally {
      try {
        await c.startImageStream(_onFrame);
        _streaming = true;
      } catch (_) {}
    }
  }

  List<Offset> _smooth(List<Offset>? prev, List<Offset> cur) {
    if (prev == null || prev.length != 4) return cur;
    const a = 0.4;
    return [for (var i = 0; i < 4; i++) prev[i] * (1 - a) + cur[i] * a];
  }

  void _go(int delta) {
    setState(() {
      _card = (_card + delta).clamp(0, _list.isEmpty ? 0 : _list.length - 1);
      _stableCount = 0;
      _lastRecognized = DateTime.fromMillisecondsSinceEpoch(0);
    });
    _log('--- now on card $_cardNo "$_cardName" ($_cardInfo) ---');
  }

  @override
  void dispose() {
    final c = _controller;
    final p = _proc;
    _controller = null;
    _proc = null;
    () async {
      try {
        if (c != null && _streaming) await c.stopImageStream();
      } catch (_) {}
      await c?.dispose();
      p?.dispose();
    }();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return Center(child: Text(_status));
    }
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
        if (_smoothQuad != null)
          Positioned.fill(
            child: CustomPaint(
              painter: _QuadPainter(_smoothQuad!, _imgW.toDouble(), _imgH.toDouble()),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          top: 44,
          child: Container(
            padding: const EdgeInsets.all(10),
            color: Colors.black.withValues(alpha: 0.6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Card $_cardNo/${_list.length}:  $_cardName',
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                Text(_cardInfo, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 4),
                Text(_status, style: const TextStyle(color: Colors.white, fontSize: 11)),
                Text(_lastMatch,
                    style: const TextStyle(color: Colors.tealAccent, fontSize: 14)),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 22,
          left: 12,
          right: 12,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton(
                onPressed: _card > 0 ? () => _go(-1) : null,
                child: const Text('◀ Prev'),
              ),
              FilledButton(onPressed: _stillAB, child: const Text('Still A/B')),
              OutlinedButton(
                onPressed: _card < _list.length - 1 ? () => _go(1) : null,
                child: const Text('Next ▶'),
              ),
            ],
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
          ..color = const Color(0xFFFFA000));
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) => true;
}
