import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../player/player_controller.dart';
import '../tokens/motion.dart';

/// Single-ticker coordinator for rhythmic media indicators across the application.
///
/// Instead of allocating independent [AnimationController]s across dozens of
/// playlist items, queue entries, and player surfaces, [PlaybackPulseScope]
/// drives a single looping timeline. Elements subscribe to the pulse and apply
/// their own phase offset.
///
/// When playback pauses or the window minimizes, the controller halts entirely,
/// consuming 0% CPU at idle.
class PlaybackPulseScope extends StatefulWidget {
  const PlaybackPulseScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final PlayerController controller;
  final Widget child;

  @override
  State<PlaybackPulseScope> createState() => _PlaybackPulseScopeState();
}

class _PlaybackPulseScopeState extends State<PlaybackPulseScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  bool _isAdvancing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncPulseState);
    _syncPulseState();
  }

  @override
  void didUpdateWidget(PlaybackPulseScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncPulseState);
      widget.controller.addListener(_syncPulseState);
      _syncPulseState();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncPulseState);
    _pulseController.dispose();
    super.dispose();
  }

  void _syncPulseState() {
    final shouldAdvance =
        widget.controller.isPlaying && widget.controller.hasMedia;
    if (_isAdvancing == shouldAdvance) return;
    _isAdvancing = shouldAdvance;
    if (_isAdvancing) {
      if (!AppMotion.reduce(context)) {
        _pulseController.repeat();
      } else {
        _pulseController.stop();
      }
    } else {
      _pulseController.stop();
      _pulseController.value = 0.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlaybackPulse(animation: _pulseController, child: widget.child);
  }
}

/// Inherited notifier providing access to the shared playback pulse animation.
class PlaybackPulse extends InheritedNotifier<Animation<double>> {
  const PlaybackPulse({
    super.key,
    required Animation<double> animation,
    required super.child,
  }) : super(notifier: animation);

  static double valueOf(BuildContext context, {int phaseIndex = 0}) {
    if (AppMotion.reduce(context)) return 0.0;
    final pulse = context.dependOnInheritedWidgetOfExactType<PlaybackPulse>();
    final raw = pulse?.notifier?.value ?? 0.0;
    if (phaseIndex == 0) return raw;
    return (raw + (phaseIndex * 0.28)) % 1.0;
  }
}

/// Micro 3-bar animated equalizer glyph that paints directly to a Canvas.
///
/// Ticking occurs only when [isPlaying] is true and playback pulse is active.
class PlayingEqualizerGlyph extends StatelessWidget {
  const PlayingEqualizerGlyph({
    super.key,
    this.index = 0,
    this.size = 16,
    this.color,
    this.isPlaying = true,
  });

  final int index;
  final double size;
  final Color? color;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;

    if (!isPlaying || AppMotion.reduce(context)) {
      return RepaintBoundary(
        child: CustomPaint(
          size: Size(size, size),
          painter: _EqualizerPainter(
            color: effectiveColor,
            progress: 0.0,
            index: index,
            staticRest: true,
          ),
        ),
      );
    }

    final pulse = PlaybackPulse.valueOf(context, phaseIndex: index);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(size, size),
        painter: _EqualizerPainter(
          color: effectiveColor,
          progress: pulse,
          index: index,
          staticRest: false,
        ),
      ),
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  const _EqualizerPainter({
    required this.color,
    required this.progress,
    required this.index,
    required this.staticRest,
  });

  final Color color;
  final double progress;
  final int index;
  final bool staticRest;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.fill;

    final barWidth = size.width * 0.22;
    final gap = (size.width - (3 * barWidth)) / 2;
    final maxBarHeight = size.height * 0.9;
    final minBarHeight = size.height * 0.2;

    for (var i = 0; i < 3; i++) {
      double factor;
      if (staticRest) {
        factor = (i == 1) ? 0.6 : 0.35;
      } else {
        // Multi-frequency wave calculation with phase offset per bar
        final t = (progress * 2 * math.pi) + (i * 1.8) + (index * 0.5);
        final wave = (math.sin(t) + math.sin(t * 1.7)) / 2.0;
        factor = (wave.abs()).clamp(0.15, 1.0);
      }

      final h = minBarHeight + (maxBarHeight - minBarHeight) * factor;
      final x = i * (barWidth + gap);
      final y = size.height - h;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, h),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EqualizerPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.staticRest != staticRest;
}
