import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

class ScreenPlayMark extends StatelessWidget {
  const ScreenPlayMark({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(width, height), painter: _ScreenPlayPainter());
}

class _ScreenPlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final screen = Rect.fromLTWH(
      size.width * 0.06,
      size.height * 0.08,
      size.width * 0.88,
      size.height * 0.68,
    );
    final panel = RRect.fromRectAndRadius(screen, const Radius.circular(9));
    canvas.drawRRect(panel, Paint()..color = AppTheme.surface);
    canvas.drawRRect(
      panel,
      Paint()
        ..color = AppTheme.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );

    final accentLine = Paint()
      ..color = AppTheme.accent.withValues(alpha: 0.75)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(screen.left + 10, screen.top + 12),
      Offset(screen.left + 10, screen.bottom - 12),
      accentLine,
    );

    final center = Offset(screen.center.dx + 3, screen.center.dy);
    final play = Path()
      ..moveTo(center.dx - 7, center.dy - 11)
      ..lineTo(center.dx + 11, center.dy)
      ..lineTo(center.dx - 7, center.dy + 11)
      ..close();
    canvas.drawPath(play, Paint()..color = AppTheme.accent);

    final standPaint = Paint()
      ..color = AppTheme.border
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final standTop = screen.bottom + 5;
    canvas.drawLine(
      Offset(screen.center.dx, standTop),
      Offset(screen.center.dx, size.height - 15),
      standPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.34, size.height - 12),
      Offset(size.width * 0.66, size.height - 12),
      standPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScreenPlayPainter oldDelegate) => false;
}
