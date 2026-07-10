import 'package:flutter/material.dart';

import '../../../../core/widgets/family_public_image.dart';

/// Аватар с фото или инициалами.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.assetPath,
    this.radius = 24,
  });

  final String name;
  final String? avatarUrl;
  final String? assetPath;
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

    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: FamilyPublicImage(
            url: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: _loadingAvatar(bg, size, radius),
            error: _initialsBox(bg, size, radius),
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
