import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class AttachCameraPreviewImpl extends StatefulWidget {
  const AttachCameraPreviewImpl({super.key});

  @override
  State<AttachCameraPreviewImpl> createState() =>
      _AttachCameraPreviewImplState();
}

class _AttachCameraPreviewImplState extends State<AttachCameraPreviewImpl> {
  CameraController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null || !c.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black87,
        child: Center(
          child: Icon(Icons.camera_alt_outlined, color: Colors.white54),
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.previewSize?.height ?? 100,
        height: c.value.previewSize?.width ?? 100,
        child: CameraPreview(c),
      ),
    );
  }
}
