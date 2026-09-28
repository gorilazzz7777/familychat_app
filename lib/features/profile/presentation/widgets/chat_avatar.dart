import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/widgets/family_public_image.dart';

/// Аватар с фото или инициалами.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.userId,
    this.assetPath,
    this.localFilePath,
    this.memoryBytes,
    this.radius = 24,
  });

  final String name;
  final String? avatarUrl;
  final int? userId;
  final String? assetPath;
  /// Local filesystem path (e.g. TDLib downloaded chat photo).
  final String? localFilePath;
  /// In-memory JPEG/PNG (e.g. TDLib minithumbnail) until file is ready.
  final List<int>? memoryBytes;
  final double radius;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) {
      final s = parts.first;
      return s.length >= 2 ? s.substring(0, 2).toUpperCase() : s.toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primary;
    final url = avatarUrl?.trim();
    final asset = assetPath?.trim();
    final local = localFilePath?.trim();
    final size = radius * 2;

    if (asset != null && asset.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: Image.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    // Prefer full local photo over URL / minithumbnail whenever we have a path.
    // Trust TDLib path cache — no sync existsSync on the UI thread (hub scroll).
    if (!kIsWeb && local != null && local.isNotEmpty) {
      final file = File(local);
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
      final px = (size * dpr).round();
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: Image.file(
            file,
            width: size,
            height: size,
            cacheWidth: px,
            cacheHeight: px,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => _initialsBox(bg, size, radius),
          ),
        ),
      );
    }

    // Network URL before TDLib minithumbnail — mini is ~40px and looks blurry.
    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: FamilyPublicImage(
            url: url,
            userId: userId,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: _loadingAvatar(bg, size, radius),
            error: _initialsBox(bg, size, radius),
          ),
        ),
      );
    }

    final bytes = memoryBytes;
    if (bytes != null && bytes.isNotEmpty) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
      final px = (size * dpr).round().clamp(32, 128);
      final raw =
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: Image.memory(
            raw,
            width: size,
            height: size,
            cacheWidth: px,
            cacheHeight: px,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, __, ___) => _initialsBox(bg, size, radius),
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: _initialsText(radius),
    );
  }

  Widget _loadingAvatar(Color bg, double size, double r) {
    return ColoredBox(
      color: bg.withValues(alpha: 0.15),
      child: Center(
        child: SizedBox(
          width: r * 0.9,
          height: r * 0.9,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }

  Widget _initialsBox(Color bg, double size, double r) {
    return Container(
      width: size,
      height: size,
      color: bg,
      alignment: Alignment.center,
      child: _initialsText(r),
    );
  }

  Widget _initialsText(double r) {
    return Text(
      initials(name),
      style: TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
        fontSize: r * 0.72,
      ),
    );
  }
}
