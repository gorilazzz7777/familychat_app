import 'package:flutter/material.dart';

/// Значок «уже есть в альбоме / FamilyChat» на превью в шторке выбора.
class AlreadyInAlbumBadge extends StatelessWidget {
  const AlreadyInAlbumBadge({super.key, this.tooltip = 'Уже в альбоме'});

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(
          Icons.photo_album_outlined,
          size: 14,
          color: Colors.white,
        ),
      ),
    );
  }
}
