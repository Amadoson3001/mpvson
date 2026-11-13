import 'package:flutter/material.dart';

/// Sizes used by the hover bubble and the seek bar that positions it.
abstract final class SeekPreviewMetrics {
  static const double videoWidth = 240;
  static const double compactVideoWidth = 168;
  static const double audioWidth = 200;
  static const double compactAudioWidth = 184;
  static const double caretWidth = 12;
  static const double caretHeight = 6;
  static const double lift = 8;
  static const double compactLift = 6;

  static double bubbleWidth({required bool compact, required bool audio}) {
    if (audio) return compact ? compactAudioWidth : audioWidth;
    return compact ? compactVideoWidth : videoWidth;
  }

  static double gap({required bool compact}) => compact ? compactLift : lift;
}

class CaretPainter extends CustomPainter {
  const CaretPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0.5, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width - 0.5, 0),
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(CaretPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}
