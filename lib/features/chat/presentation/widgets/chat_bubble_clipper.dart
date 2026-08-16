import 'package:flutter/material.dart';

/// Хвостик пузыря в духе Telegram: клювик с внешней стороны снизу.
///
/// Ширина под хвостик резервируется всегда — тело пузыря не «прыгает»,
/// когда у соседних сообщений хвостик скрыт (кластер одного автора).
class ChatBubbleClipper extends CustomClipper<Path> {
  const ChatBubbleClipper({
    required this.isMine,
    required this.showTail,
    this.compactWithPrevious = false,
    this.compactWithNext = false,
    this.radius = 16,
    this.tailWidth = 8,
    this.mergedRadius = 6,
  });

  final bool isMine;
  final bool showTail;
  final bool compactWithPrevious;
  final bool compactWithNext;
  final double radius;
  final double tailWidth;
  final double mergedRadius;

  @override
  Path getClip(Size size) {
    final tw = tailWidth;
    final h = size.height;
    // Всегда оставляем место под хвостик у внешнего края.
    final left = isMine ? 0.0 : tw;
    final right = isMine ? size.width - tw : size.width;

    final topOuter = compactWithPrevious ? mergedRadius : radius;
    final topInner = radius;
    final bottomOuter = showTail
        ? radius
        : (compactWithNext ? mergedRadius : radius);
    final bottomInner = radius;

    final path = Path();

    // Top edge
    path.moveTo(left + (isMine ? topInner : topOuter), 0);
    path.lineTo(right - (isMine ? topOuter : topInner), 0);
    path.quadraticBezierTo(
      right,
      0,
      right,
      isMine ? topOuter : topInner,
    );

    if (isMine && showTail) {
      path.lineTo(right, h - 11);
      path.cubicTo(right, h - 2.5, right + tw * 0.35, h, right + tw, h);
      path.cubicTo(right + tw * 0.28, h, right - 5, h, right - 12, h);
      path.lineTo(left + bottomInner, h);
      path.quadraticBezierTo(left, h, left, h - bottomInner);
    } else if (!isMine && showTail) {
      path.lineTo(right, h - bottomInner);
      path.quadraticBezierTo(right, h, right - bottomInner, h);
      path.lineTo(left + 12, h);
      path.cubicTo(left + 5, h, left - tw * 0.28, h, left - tw, h);
      path.cubicTo(left - tw * 0.35, h, left, h - 2.5, left, h - 11);
      path.lineTo(left, topOuter);
      path.quadraticBezierTo(left, 0, left + topOuter, 0);
      path.close();
      return path;
    } else {
      // Без хвостика: скругление на том же внешнем краю тела.
      path.lineTo(right, h - (isMine ? bottomOuter : bottomInner));
      path.quadraticBezierTo(
        right,
        h,
        right - (isMine ? bottomOuter : bottomInner),
        h,
      );
      path.lineTo(left + (isMine ? bottomInner : bottomOuter), h);
      path.quadraticBezierTo(
        left,
        h,
        left,
        h - (isMine ? bottomInner : bottomOuter),
      );
    }

    path.lineTo(left, isMine ? topInner : topOuter);
    path.quadraticBezierTo(
      left,
      0,
      left + (isMine ? topInner : topOuter),
      0,
    );
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant ChatBubbleClipper oldClipper) {
    return oldClipper.isMine != isMine ||
        oldClipper.showTail != showTail ||
        oldClipper.compactWithPrevious != compactWithPrevious ||
        oldClipper.compactWithNext != compactWithNext ||
        oldClipper.radius != radius ||
        oldClipper.tailWidth != tailWidth ||
        oldClipper.mergedRadius != mergedRadius;
  }
}
