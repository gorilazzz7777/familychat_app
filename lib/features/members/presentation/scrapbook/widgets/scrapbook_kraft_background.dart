import 'package:flutter/material.dart';

/// Фон раскрытого альбома: стол + разворот бумаги со сгибом.
class ScrapbookKraftBackground extends StatelessWidget {
  const ScrapbookKraftBackground({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(10),
    this.showSpine = true,
    /// Лист внутри книжного разворота: без «стола» и внешней тени.
    this.leafOnly = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool showSpine;
  final bool leafOnly;

  static const deskColor = Color(0xFF4E3A2C);
  static const paperColor = Color(0xFFF0E4D0);
  static const paperEdge = Color(0xFFC9B08E);
  static const lineColor = Color(0xFFC9B9A2);

  @override
  Widget build(BuildContext context) {
    final paper = ClipRRect(
      borderRadius: BorderRadius.circular(leafOnly ? 2 : 3),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: paperColor),
          CustomPaint(painter: _AlbumPaperPainter(showSpine: showSpine)),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    if (leafOnly) {
      return SizedBox.expand(child: paper);
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.15,
          colors: [
            Color(0xFF6A5040),
            deskColor,
            Color(0xFF3A2A20),
          ],
        ),
      ),
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x88000000),
                  blurRadius: 22,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: paper,
          ),
        ),
      ),
    );
  }
}

class _AlbumPaperPainter extends CustomPainter {
  _AlbumPaperPainter({required this.showSpine});

  final bool showSpine;

  @override
  void paint(Canvas canvas, Size size) {
    // Soft fibre noise.
    final speck = Paint()..color = const Color(0x0F8B6B4A);
    for (var y = 0.0; y < size.height; y += 11) {
      for (var x = 0.0; x < size.width; x += 13) {
        if (((x + y * 3) ~/ 17) % 3 == 0) {
          canvas.drawCircle(Offset(x, y), 0.8, speck);
        }
      }
    }

    // Aged edge wash.
    final edge = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x33A67B5B),
          Colors.transparent,
          const Color(0x228B7355),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, edge);

    if (showSpine) {
      final mid = size.width / 2;
      final spine = Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            const Color(0x33000000),
            const Color(0x44000000),
            const Color(0x33000000),
            Colors.transparent,
          ],
          stops: const [0.0, 0.42, 0.5, 0.58, 1.0],
        ).createShader(Rect.fromLTWH(mid - 18, 0, 36, size.height));
      canvas.drawRect(Rect.fromLTWH(mid - 18, 0, 36, size.height), spine);

      final crease = Paint()
        ..color = const Color(0x55A8896A)
        ..strokeWidth = 1.1;
      canvas.drawLine(Offset(mid, 0), Offset(mid, size.height), crease);
    }

    // Soft paper border.
    final border = Paint()
      ..color = const Color(0x55C4A882)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
        const Radius.circular(2),
      ),
      border,
    );
  }

  @override
  bool shouldRepaint(covariant _AlbumPaperPainter oldDelegate) =>
      oldDelegate.showSpine != showSpine;
}

/// Lined notebook surface for handwritten notes.
class ScrapbookLinedPaperPainter extends CustomPainter {
  const ScrapbookLinedPaperPainter({
    this.lineHeight = 22,
    this.topPad = 8,
  });

  final double lineHeight;
  final double topPad;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ScrapbookKraftBackground.lineColor.withValues(alpha: 0.7)
      ..strokeWidth = 1;

    for (var y = topPad; y < size.height; y += lineHeight) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Faint left margin.
    final margin = Paint()
      ..color = const Color(0x55C9897A)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(12, 0),
      Offset(12, size.height),
      margin,
    );
  }

  @override
  bool shouldRepaint(covariant ScrapbookLinedPaperPainter oldDelegate) =>
      oldDelegate.lineHeight != lineHeight || oldDelegate.topPad != topPad;
}
