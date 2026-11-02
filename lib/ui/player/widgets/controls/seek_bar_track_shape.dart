import 'package:flutter/material.dart';

class UniformRoundedSliderTrackShape extends RoundedRectSliderTrackShape {
  const UniformRoundedSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: 0,
    );
  }
}

/// Draws subtle chapter boundary marks over the seek track.
class ChapterTickPainter extends CustomPainter {
  const ChapterTickPainter({
    required this.fractions,
    required this.color,
    required this.textDirection,
  });

  final List<double> fractions;
  final Color color;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const tickWidth = 2.0;
    const tickHeight = 9.0;
    final paint = Paint()..color = color;
    final top = (size.height - tickHeight) / 2;
    final rtl = textDirection == TextDirection.rtl;
    for (final fraction in fractions) {
      final clamped = fraction.clamp(0.0, 1.0).toDouble();
      final centerX = (rtl ? 1 - clamped : clamped) * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(centerX - tickWidth / 2, top, tickWidth, tickHeight),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(ChapterTickPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection ||
      !_sameFractions(oldDelegate.fractions, fractions);

  static bool _sameFractions(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
