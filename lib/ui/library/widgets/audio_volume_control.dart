import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../player/player_controller.dart';

/// Compact mute button and slider shared by Now Playing and the library mini player.
class AudioVolumeControl extends StatelessWidget {
  const AudioVolumeControl({
    super.key,
    required this.controller,
    this.compact = false,
    this.showPercent = false,
  });

  final PlayerController controller;
  final bool compact;
  final bool showPercent;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final volume = controller.volume.clamp(0.0, 100.0);
        final icon = volume <= 0
            ? Icons.volume_off_rounded
            : volume < 50
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(icon, size: compact ? 17 : 20),
              tooltip: volume <= 0 ? 'Unmute' : 'Mute',
              visualDensity: VisualDensity.compact,
              color: AppTheme.secondaryText,
              onPressed: () => unawaited(controller.toggleMute()),
            ),
            SizedBox(
              width: compact ? 84 : 150,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: compact ? 4 : 5,
                  ),
                  overlayShape: RoundSliderOverlayShape(
                    overlayRadius: compact ? 10 : 14,
                  ),
                  activeTrackColor: AppTheme.accent,
                  inactiveTrackColor: AppTheme.border,
                  thumbColor: AppTheme.accent,
                  overlayColor: AppTheme.accent.withValues(alpha: 0.14),
                ),
                child: Slider(
                  value: volume,
                  min: 0,
                  max: 100,
                  onChanged: (value) => unawaited(controller.setVolume(value)),
                ),
              ),
            ),
            if (showPercent)
              SizedBox(
                width: 40,
                child: Text(
                  '${volume.round()}%',
                  textAlign: TextAlign.right,
                  style: AppTheme.metadata.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Turns vertical wheel input over an audio surface into 5% volume steps.
class AudioVolumeWheel extends StatefulWidget {
  const AudioVolumeWheel({
    super.key,
    required this.controller,
    required this.child,
  });

  final PlayerController controller;
  final Widget child;

  @override
  State<AudioVolumeWheel> createState() => _AudioVolumeWheelState();
}

class _AudioVolumeWheelState extends State<AudioVolumeWheel> {
  double _remainder = 0;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _handleSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !widget.controller.hasMedia ||
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _remainder += event.scrollDelta.dy.clamp(-20.0, 20.0);
      _reset?.cancel();
      _reset = Timer(const Duration(milliseconds: 250), () => _remainder = 0);
      final steps = (_remainder / 20).truncate();
      if (steps == 0) return;
      _remainder -= steps * 20;
      unawaited(widget.controller.adjustVolume(-steps * 5));
    });
  }

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerSignal: _handleSignal, child: widget.child);
}
