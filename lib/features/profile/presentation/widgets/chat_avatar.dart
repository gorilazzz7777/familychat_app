import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Аватар с фото или инициалами.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.radius = 24,
  });

  final String name;
  final String? avatarUrl;
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
    final size = radius * 2;

    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg.withValues(alpha: 0.15),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            placeholder: (_, __) => _initialsBox(bg, size),
            errorWidget: (_, __, ___) => _initialsBox(bg, size),
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

  Widget _initialsBox(Color bg, double size) {
    return Container(
      width: size,
      height: size,
      color: bg,
      alignment: Alignment.center,
      child: _initialsText(radius),
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
