import 'package:flutter/material.dart';

/// A film aperture with a play-shaped opening.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MarkPainter(Theme.of(context).colorScheme.primary),
  );
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 64;
    canvas.save();
    canvas.scale(scale);
    final outer = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(5, 8, 54, 48),
          const Radius.circular(5),
        ),
      );
    final cut = Path()
      ..moveTo(26, 20)
      ..lineTo(45, 32)
      ..lineTo(26, 44)
      ..close();
    final holes = Path();
    for (final y in [15.0, 26.0, 37.0, 48.0]) {
      holes.addRect(Rect.fromLTWH(10, y, 5, 4));
      holes.addRect(Rect.fromLTWH(49, y, 5, 4));
    }
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path.combine(PathOperation.difference, outer, cut),
        holes,
      ),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.color != color;
}
