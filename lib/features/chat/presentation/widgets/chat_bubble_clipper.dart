import 'package:flutter/material.dart';

/// Хвостик пузыря в духе Telegram: клювик с внешней стороны снизу.
class ChatBubbleClipper extends CustomClipper<Path> {
  const ChatBubbleClipper({
    required this.isMine,
    required this.showTail,
    this.radius = 16,
    this.tailWidth = 8,
  });

  final bool isMine;
  final bool showTail;
  final double radius;
  final double tailWidth;

  @override
  Path getClip(Size size) {
    final r = radius;
    final tw = showTail ? tailWidth : 0.0;
    final h = size.height;
    final left = isMine ? 0.0 : tw;
    final right = isMine ? size.width - tw : size.width;

    final path = Path();
    path.moveTo(left + r, 0);
    path.lineTo(right - r, 0);
    path.quadraticBezierTo(right, 0, right, r);

    if (isMine && showTail) {
      path.lineTo(right, h - 11);
      path.cubicTo(right, h - 2.5, right + tw * 0.35, h, right + tw, h);
      path.cubicTo(right + tw * 0.28, h, right - 5, h, right - 12, h);
      path.lineTo(left + r, h);
    } else if (!isMine && showTail) {
      path.lineTo(right, h - r);
      path.quadraticBezierTo(right, h, right - r, h);
      path.lineTo(left + 12, h);
      path.cubicTo(left + 5, h, left - tw * 0.28, h, left - tw, h);
      path.cubicTo(left - tw * 0.35, h, left, h - 2.5, left, h - 11);
      path.lineTo(left, r);
      path.quadraticBezierTo(left, 0, left + r, 0);
      path.close();
      return path;
    } else {
      path.lineTo(right, h - r);
      path.quadraticBezierTo(right, h, right - r, h);
      path.lineTo(left + r, h);
    }

    path.quadraticBezierTo(left, h, left, h - r);
    path.lineTo(left, r);
    path.quadraticBezierTo(left, 0, left + r, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant ChatBubbleClipper oldClipper) {
    return oldClipper.isMine != isMine ||
        oldClipper.showTail != showTail ||
        oldClipper.radius != radius ||
        oldClipper.tailWidth != tailWidth;
  }
}
