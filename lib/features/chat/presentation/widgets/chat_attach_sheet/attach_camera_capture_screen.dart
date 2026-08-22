import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../../core/media/gallery_media_utils.dart';
import '../../../../../core/media/image_upload_pipeline.dart';
import 'chat_attach_models.dart';

/// Полноэкранная камера для шторки вложений.
/// Тап по затвору — фото; удержание — видео до отпускания.
class AttachCameraCaptureScreen extends StatefulWidget {
  const AttachCameraCaptureScreen({super.key});

  static Future<ChatAttachSelectionItem?> open(BuildContext context) {
    if (kIsWeb) return Future.value(null);
    return Navigator.of(context).push<ChatAttachSelectionItem>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const AttachCameraCaptureScreen(),
      ),
    );
  }

  @override
  State<AttachCameraCaptureScreen> createState() =>
      _AttachCameraCaptureScreenState();
}

class _AttachCameraCaptureScreenState extends State<AttachCameraCaptureScreen> {
  static const _maxVideoMs = 5 * 60 * 1000;

  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _ready = false;
  bool _busy = false;
  bool _recording = false;
  int _elapsedMs = 0;
  Timer? _tick;
  /// After long-press recording, ignore a following tap.
  bool _suppressNextTap = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initCamera());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_camera?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _initCamera({CameraLensDirection? prefer}) async {
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 280 * attempt));
      }
      try {
        final cam = await Permission.camera.request();
        if (!cam.isGranted) {
          throw Exception('Нужен доступ к камере');
        }
        _cameras = await availableCameras();
        if (_cameras.isEmpty) throw Exception('Камера недоступна');

        final want = prefer ?? CameraLensDirection.back;
        _cameraIndex = _cameras.indexWhere((c) => c.lensDirection == want);
        if (_cameraIndex < 0) _cameraIndex = 0;

        await _camera?.dispose();
        final controller = CameraController(
          _cameras[_cameraIndex],
          ResolutionPreset.high,
          enableAudio: true,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _camera = controller;
          _ready = true;
        });
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$lastError')),
    );
  }

  Future<void> _flipCamera() async {
    if (_busy || _recording || _cameras.length < 2) return;
    final current = _cameras[_cameraIndex];
    final next = current.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    setState(() => _ready = false);
    await _initCamera(prefer: next);
  }

  Future<void> _takePhoto() async {
    if (_suppressNextTap) {
      _suppressNextTap = false;
      return;
    }
    final cam = _camera;
    if (!_ready || cam == null || _busy || _recording) return;
    setState(() => _busy = true);
    try {
      HapticFeedback.lightImpact();
      final file = await cam.takePicture();
      final bytes = await File(file.path).readAsBytes();
      if (bytes.isEmpty) return;
      final data = Uint8List.fromList(bytes);
      final thumb = await compressImageBytes(
        data,
        maxSide: 200,
        quality: 55,
        localPath: file.path,
      );
      final name = file.name.isNotEmpty
          ? file.name
          : 'camera_${DateTime.now().millisecondsSinceEpoch}.jpg';
      if (!mounted) return;
      Navigator.of(context).pop(
        ChatAttachSelectionItem(
          id: 'cam_i_${DateTime.now().microsecondsSinceEpoch}',
          filename: name,
          bytes: data,
          thumbnailBytes: thumb,
          contentType: contentTypeForFilename(name),
          localPath: file.path,
          kind: 'image',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сделать фото: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startVideo() async {
    final cam = _camera;
    if (!_ready || cam == null || _busy || _recording) return;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нужен доступ к микрофону для видео')),
      );
      return;
    }
    try {
      HapticFeedback.mediumImpact();
      await cam.startVideoRecording();
      _suppressNextTap = true;
      _elapsedMs = 0;
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        setState(() => _elapsedMs += 100);
        if (_elapsedMs >= _maxVideoMs) {
          unawaited(_stopVideo());
        }
      });
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось начать запись: $e')),
      );
    }
  }

  Future<void> _stopVideo() async {
    final cam = _camera;
    if (!_recording || cam == null) return;
    _tick?.cancel();
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      final file = await cam.stopVideoRecording();
      final raw = await File(file.path).readAsBytes();
      if (raw.isEmpty) return;
      final filename = file.name.isNotEmpty
          ? file.name
          : 'camera_${DateTime.now().millisecondsSinceEpoch}.mp4';
      if (!mounted) return;
      Navigator.of(context).pop(
        ChatAttachSelectionItem(
          id: 'cam_v_${DateTime.now().microsecondsSinceEpoch}',
          filename: filename,
          bytes: Uint8List.fromList(raw),
          contentType: contentTypeForFilename(filename),
          localPath: file.path,
          kind: 'video',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить видео: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatElapsed(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    final ready = _ready && cam != null && cam.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            Positioned.fill(
              child: _FullScreenCameraPreview(controller: cam!),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          // Soft scrims so controls stay readable on bright scenes.
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Color(0x66000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
          const IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
                child: SizedBox(height: 180, width: double.infinity),
              ),
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  ),
                ),
                if (_recording)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.fiber_manual_record,
                              color: Colors.redAccent,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatElapsed(_elapsedMs),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _recording
                            ? 'Отпустите, чтобы закончить'
                            : 'Нажмите — фото · удерживайте — видео',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          const SizedBox(width: 56),
                          _ShutterButton(
                            recording: _recording,
                            enabled: _ready && !_busy,
                            onTap: () => unawaited(_takePhoto()),
                            onLongPressStart: () => unawaited(_startVideo()),
                            onLongPressEnd: () => unawaited(_stopVideo()),
                          ),
                          SizedBox(
                            width: 56,
                            child: IconButton(
                              onPressed: _ready &&
                                      !_busy &&
                                      !_recording &&
                                      _cameras.length > 1
                                  ? () => unawaited(_flipCamera())
                                  : null,
                              icon: const Icon(
                                Icons.cameraswitch,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Превью на весь экран с cover (как системная камера).
class _FullScreenCameraPreview extends StatelessWidget {
  const _FullScreenCameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    // previewSize is landscape; swap for portrait phone layout.
    final previewW = size?.height ?? 720.0;
    final previewH = size?.width ?? 1280.0;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: previewW,
          height: previewH,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.recording,
    required this.enabled,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      onLongPressStart: enabled ? (_) => onLongPressStart() : null,
      onLongPressEnd: enabled ? (_) => onLongPressEnd() : null,
      onLongPressCancel: enabled ? onLongPressEnd : null,
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: recording ? 84 : 76,
              height: recording ? 84 : 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: recording ? Colors.redAccent : Colors.white,
                  width: recording ? 5 : 4,
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: recording ? 58 : 60,
              height: recording ? 58 : 60,
              decoration: BoxDecoration(
                color: recording ? Colors.redAccent : Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
