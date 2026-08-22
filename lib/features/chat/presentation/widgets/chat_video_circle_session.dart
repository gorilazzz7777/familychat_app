import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../record_video_circle_screen.dart';

/// Сессия записи кружка с превью камеры (hold / lock из композа).
class ChatVideoCircleSession extends ChangeNotifier {
  static const maxMs = 30000;

  CameraController? _camera;
  bool _ready = false;
  bool _recording = false;
  int _elapsedMs = 0;
  Timer? _tick;
  Object? _error;

  bool get isReady => _ready;
  bool get isRecording => _recording;
  int get elapsedMs => _elapsedMs;
  Object? get error => _error;
  CameraController? get camera => _camera;

  Future<void> ensureReady() async {
    if (kIsWeb) {
      _error = StateError('web');
      notifyListeners();
      return;
    }
    if (_ready && _camera != null) return;
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
      try {
        final cam = await Permission.camera.request();
        final mic = await Permission.microphone.request();
        if (!cam.isGranted || !mic.isGranted) {
          throw StateError('permission');
        }
        final cameras = await availableCameras();
        if (cameras.isEmpty) throw StateError('no_camera');
        final front = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first,
        );
        final controller = CameraController(
          front,
          ResolutionPreset.medium,
          enableAudio: true,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        await controller.initialize();
        await _camera?.dispose();
        _camera = controller;
        _ready = true;
        _error = null;
        notifyListeners();
        return;
      } catch (e) {
        lastError = e;
      }
    }
    _error = lastError;
    notifyListeners();
  }

  Future<void> start() async {
    if (_recording) return;
    await ensureReady();
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      throw _error ?? StateError('camera');
    }
    await cam.startVideoRecording();
    _elapsedMs = 0;
    _recording = true;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _elapsedMs += 100;
      notifyListeners();
      if (_elapsedMs >= maxMs) {
        // Caller should stop/send; just notify.
      }
    });
    notifyListeners();
  }

  Future<VideoCircleRecording?> stop() async {
    if (!_recording) return null;
    _tick?.cancel();
    _tick = null;
    final elapsed = _elapsedMs.clamp(1, maxMs);
    final cam = _camera;
    if (cam == null) {
      _recording = false;
      notifyListeners();
      return null;
    }
    try {
      final file = await cam.stopVideoRecording();
      _recording = false;
      notifyListeners();
      final bytes = await File(file.path).readAsBytes();
      if (bytes.isEmpty) return null;
      return VideoCircleRecording(
        bytes: bytes,
        durationMs: elapsed,
        filename: 'circle_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
    } catch (_) {
      _recording = false;
      notifyListeners();
      return null;
    }
  }

  Future<void> cancel() async {
    _tick?.cancel();
    _tick = null;
    if (_recording) {
      try {
        final file = await _camera?.stopVideoRecording();
        final path = file?.path;
        if (path != null) {
          unawaited(
            File(path).delete().then((_) {}, onError: (_) {}),
          );
        }
      } catch (_) {}
    }
    _recording = false;
    _elapsedMs = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    final cam = _camera;
    _camera = null;
    unawaited(cam?.dispose() ?? Future<void>.value());
    super.dispose();
  }
}

/// Превью кружка (камера) — ClipOval + cover.
class ChatVideoCirclePreview extends StatelessWidget {
  const ChatVideoCirclePreview({
    super.key,
    required this.session,
    this.size = 280,
    this.progress,
  });

  final ChatVideoCircleSession session;
  final double size;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final cam = session.camera;
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipOval(
                child: ColoredBox(
                  color: Colors.black,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: cam != null && cam.value.isInitialized
                        ? FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: cam.value.previewSize?.height ?? 240,
                              height: cam.value.previewSize?.width ?? 240,
                              child: CameraPreview(cam),
                            ),
                          )
                        : const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                  ),
                ),
              ),
              if (progress != null)
                IgnorePointer(
                  child: CustomPaint(
                    size: Size(size, size),
                    painter: _CircleProgressPainter(
                      progress: progress!.clamp(0.0, 1.0),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CircleProgressPainter extends CustomPainter {
  _CircleProgressPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final active = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.57079632679,
      6.28318530718 * progress,
      false,
      active,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleProgressPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
