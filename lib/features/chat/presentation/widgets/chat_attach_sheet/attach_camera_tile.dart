import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attach_camera_preview_impl.dart'
    if (dart.library.html) 'attach_camera_preview_web.dart';

/// Live-превью камеры (native) или статичная плитка (web).
class AttachCameraTile extends StatelessWidget {
  const AttachCameraTile({
    super.key,
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!kIsWeb)
              const AttachCameraPreviewImpl()
            else
              const ColoredBox(color: Colors.black87),
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.camera_alt, color: Colors.white70, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
