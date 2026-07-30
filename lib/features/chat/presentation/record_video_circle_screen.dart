import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

/// Результат записи кружка.
class VideoCircleRecording {
  const VideoCircleRecording({
    required this.bytes,
    required this.durationMs,
    required this.filename,
    this.contentType = 'video/mp4',
  });

  final Uint8List bytes;
  final int durationMs;
  final String filename;
  final String contentType;
}

/// Запись видео-кружка: запись → предпросмотр → перезаписать / отправить.
class RecordVideoCircleScreen extends StatefulWidget {
  const RecordVideoCircleScreen({super.key});

  static Future<VideoCircleRecording?> open(BuildContext context) {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Кружки пока только в приложении')),
      );
      return Future.value(null);
    }
    return Navigator.of(context).push<VideoCircleRecording>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const RecordVideoCircleScreen(),
      ),
    );
  }

  @override
  State<RecordVideoCircleScreen> createState() =>
      _RecordVideoCircleScreenState();
}

class _RecordVideoCircleScreenState extends State<RecordVideoCircleScreen> {
  static const _maxVideoMs = 30000;

  bool _recording = false;
  bool _submitting = false;
  int _elapsedMs = 0;
  Timer? _tick;

  CameraController? _camera;
  bool _cameraReady = false;
  String? _videoPath;
  int _videoDurationMs = 0;
  VideoPlayerController? _videoPreview;

  @override
  void initState() {
    super.initState();
    unawaited(_initCamera());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_camera?.dispose() ?? Future<void>.value());
    unawaited(_videoPreview?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  bool get _hasPreview => _videoPath != null;

  Future<void> _ensureCameraPermission() async {
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!cam.isGranted || !mic.isGranted) {
      throw Exception('Нужен доступ к камере и микрофону');
    }
  }

  Future<void> _initCamera() async {
    try {
      await _ensureCameraPermission();
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('Камера недоступна');
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
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  void _startTick() {
    _tick?.cancel();
    _elapsedMs = 0;
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _elapsedMs += 100);
      if (_elapsedMs >= _maxVideoMs) {
        unawaited(_stopRecording());
      }
    });
  }

  Future<void> _startRecording() async {
    if (_recording || _submitting) return;
    try {
      if (!_cameraReady || _camera == null) {
        await _initCamera();
      }
      final cam = _camera;
      if (cam == null || !cam.value.isInitialized) {
        throw Exception('Камера не готова');
      }
      await cam.startVideoRecording();
      setState(() {
        _videoPath = null;
        _videoDurationMs = 0;
        _recording = true;
      });
      _startTick();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _tick?.cancel();
    final cam = _camera;
    try {
      final file = await cam?.stopVideoRecording();
      final path = file?.path;
      if (path == null || path.isEmpty) {
        throw Exception('Не удалось сохранить видео');
      }
      final preview = VideoPlayerController.file(File(path));
      await preview.initialize();
      await preview.setLooping(true);
      await preview.play();
      if (!mounted) {
        await preview.dispose();
        return;
      }
      setState(() {
        _recording = false;
        _videoPath = path;
        _videoDurationMs = _elapsedMs;
        _videoPreview = preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _recording = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _clearPreview() async {
    await _videoPreview?.dispose();
    setState(() {
      _videoPath = null;
      _videoDurationMs = 0;
      _videoPreview = null;
      _elapsedMs = 0;
    });
  }

  Future<void> _submit() async {
    if (_submitting || !_hasPreview || _videoPath == null) return;
    setState(() => _submitting = true);
    try {
      final bytes = await File(_videoPath!).readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(
        VideoCircleRecording(
          bytes: bytes,
          durationMs: _videoDurationMs > 0 ? _videoDurationMs : _elapsedMs,
          filename:
              'circle_${DateTime.now().millisecondsSinceEpoch}.mp4',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: $e')),
      );
      setState(() => _submitting = false);
    }
  }

  String _formatMs(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(1, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Кружок'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Text(
              'До 30 секунд',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white70,
              ),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipOval(
                    child: ColoredBox(
                      color: Colors.black,
                      child: _buildVideoStage(),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: _buildControls(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoStage() {
    if (_videoPath != null && _videoPreview != null) {
      final c = _videoPreview!;
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      );
    }
    final cam = _camera;
    if (cam != null && cam.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: cam.value.previewSize?.height ?? 240,
          height: cam.value.previewSize?.width ?? 240,
          child: CameraPreview(cam),
        ),
      );
    }
    return const Center(
      child: CircularProgressIndicator(color: Colors.white54),
    );
  }

  Widget _buildControls(ThemeData theme) {
    if (_submitting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasPreview && !_recording) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _clearPreview,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              child: const Text('Перезаписать'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _submit,
              child: const Text('Отправить'),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        if (_recording)
          Text(
            _formatMs(_elapsedMs),
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
          ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _recording ? _stopRecording : _startRecording,
          icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
          label: Text(_recording ? 'Стоп' : 'Запись'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    );
  }
}