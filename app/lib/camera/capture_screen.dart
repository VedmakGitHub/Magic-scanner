import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../recognition/recognition_service.dart';
import '../scan/candidate_sheet.dart';
import 'guide_overlay.dart';

/// Scan screen: live preview + card guide overlay + capture (Section 6, 8.2).
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera available on this device.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _controller = controller;
      _initFuture = controller.initialize();
      await _initFuture;
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      setState(() => _error = 'Camera error: ${e.description ?? e.code}');
    } catch (e) {
      setState(() => _error = 'Camera error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final serviceAsync = ref.read(recognitionServiceProvider);
      final service = serviceAsync.valueOrNull;
      if (service == null) {
        _snack('Card data still loading — try again in a moment.');
        return;
      }
      final shot = await controller.takePicture();
      final Uint8List bytes = await shot.readAsBytes();
      final RecognitionResult result = await service.recognize(bytes);
      if (!mounted) return;
      await showCandidateSheet(context, ref, result);
    } catch (e) {
      _snack('Capture failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.no_photography_outlined,
        message: _error!,
        action: TextButton(onPressed: _initCamera, child: const Text('Retry')),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.previewSize?.height ?? 1080,
            height: controller.value.previewSize?.width ?? 1920,
            child: CameraPreview(controller),
          ),
        ),
        const GuideOverlay(),
        Positioned(
          left: 0,
          right: 0,
          top: 48,
          child: _hint(),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 36,
          child: Center(child: _captureButton()),
        ),
      ],
    );
  }

  Widget _hint() => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Place the card on a plain, evenly-lit surface and fit it inside the frame.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: 14, shadows: [
            Shadow(blurRadius: 6, color: Colors.black),
          ]),
        ),
      );

  Widget _captureButton() {
    return GestureDetector(
      onTap: _busy ? null : _capture,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white24,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Colors.white),
              )
            : const Icon(Icons.camera_alt, color: Colors.white, size: 34),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final Widget? action;
  const _CenteredMessage({required this.icon, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}
