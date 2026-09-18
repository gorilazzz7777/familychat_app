import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Значок «уже есть в альбоме»: двойная галочка как у прочитанного в чате.
class AlreadyInAlbumBadge extends StatelessWidget {
  const AlreadyInAlbumBadge({super.key, this.tooltip = 'Уже в альбоме'});

  final String tooltip;

  static const _green = Color(0xFF4CAF50);

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: EdgeInsets.all(3),
          child: Icon(
            LucideIcons.check_check,
            size: 14,
            color: _green,
          ),
        ),
      ),
    );
  }
}
