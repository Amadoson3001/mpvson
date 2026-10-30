import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../player/player_controller.dart';

/// Compact mute button and responsive slider shared by Now Playing and the library mini player.
///
/// Supports direct pointer wheel scrolling over the entire widget (slider, icon, label),
/// debounced volume changes to prevent engine thrashing during drag, and tactile cursors.
class AudioVolumeControl extends StatefulWidget {
  const AudioVolumeControl({
    super.key,
    required this.controller,
    this.compact = false,
    this.showPercent = false,
  });

  /// Extent of the mute button, matching the theme's compact icon button.
  ///
  /// The control's rows are built from the extents below instead of the
  /// theme's touch target, so layout that reserves room for this widget
  /// measures the same numbers it is laid out with.
  static const double muteExtent = 40;

  /// Slider length in the full-size presentation.
  ///
  /// Sized so the whole control still fits beside the transport on the Now
  /// Playing stage without crowding the play button's center line.
  static const double sliderWidth = 128;

  /// Slider length in the compact presentation.
  static const double compactSliderWidth = 84;

  /// Readout width for the percent label, sized for three digits.
  static const double percentWidth = 44;

  /// Height of the control, set by the mute button.
  static const double extent = 40;

  /// Width of the whole control so surrounding layout can reserve it exactly.
  static double preferredWidth({
    required bool compact,
    required bool showPercent,
  }) {
    final slider = compact ? compactSliderWidth : sliderWidth;
    final percent = showPercent ? percentWidth : 0;
    return muteExtent + slider + percent;
  }

  final PlayerController controller;
  final bool compact;
  final bool showPercent;

  @override
  State<AudioVolumeControl> createState() => _AudioVolumeControlState();
}

class _AudioVolumeControlState extends State<AudioVolumeControl> {
  static const _volumeDebounce = Duration(milliseconds: 60);

  double? _pendingVolume;
  Timer? _commitTimer;
  int _changeId = 0;
  double _wheelRemainder = 0;
  Timer? _wheelReset;

  @override
  void dispose() {
    _commitTimer?.cancel();
    _wheelReset?.cancel();
    super.dispose();
  }

  void _onDragStart(double value) {
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    setState(() => _pendingVolume = value);
  }

  void _onDragChanged(double value) {
    _changeId++;
    final changeId = _changeId;
    setState(() => _pendingVolume = value);
    _commitTimer?.cancel();
    _commitTimer = Timer(_volumeDebounce, () {
      if (mounted && changeId == _changeId) {
        unawaited(_applyVolume(value, changeId));
      }
    });
  }

  void _onDragEnd(double value) {
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    final changeId = _changeId;
    setState(() => _pendingVolume = value);
    unawaited(_applyVolume(value, changeId));
  }

  Future<void> _applyVolume(double value, int changeId) async {
    await widget.controller.setVolume(value);
    if (mounted && changeId == _changeId) {
      setState(() => _pendingVolume = null);
    }
  }

  void _toggleMute() {
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    setState(() => _pendingVolume = null);
    unawaited(widget.controller.toggleMute());
  }

  void _handleWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final dy = event.scrollDelta.dy;
      _wheelRemainder += dy;
      _wheelReset?.cancel();
      _wheelReset = Timer(
        const Duration(milliseconds: 250),
        () => _wheelRemainder = 0,
      );
      final steps = (_wheelRemainder / 20).truncate();
      if (steps == 0) return;
      _wheelRemainder -= steps * 20;
      final current = _pendingVolume ?? widget.controller.volume;
      final target = (current - steps * 5).clamp(0.0, 100.0).toDouble();
      _onDragChanged(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final volume = (_pendingVolume ?? widget.controller.volume).clamp(
          0.0,
          100.0,
        );
        final icon = volume <= 0
            ? Icons.volume_off_rounded
            : volume < 50
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _handleWheel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: AudioVolumeControl.muteExtent,
                height: AudioVolumeControl.muteExtent,
                child: IconButton(
                  icon: Icon(icon, size: widget.compact ? 17 : 20),
                  tooltip: volume <= 0 ? 'Unmute' : 'Mute (${volume.round()}%)',
                  visualDensity: VisualDensity.compact,
                  color: context.palette.secondaryText,
                  onPressed: _toggleMute,
                ),
              ),
              SizedBox(
                width: widget.compact
                    ? AudioVolumeControl.compactSliderWidth
                    : AudioVolumeControl.sliderWidth,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Tooltip(
                    message: 'Volume ${volume.round()}% (scroll to adjust)',
                    waitDuration: const Duration(milliseconds: 600),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: widget.compact ? 4 : 5,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: widget.compact ? 10 : 14,
                        ),
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        inactiveTrackColor: Theme.of(
                          context,
                        ).colorScheme.outlineVariant,
                        thumbColor: Theme.of(context).colorScheme.primary,
                        overlayColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.14),
                      ),
                      child: Slider(
                        value: volume,
                        min: 0,
                        max: 100,
                        onChangeStart: _onDragStart,
                        onChanged: _onDragChanged,
                        onChangeEnd: _onDragEnd,
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.showPercent)
                SizedBox(
                  width: AudioVolumeControl.percentWidth,
                  child: Text(
                    '${volume.round()}%',
                    textAlign: TextAlign.right,
                    style: context.palette.metadata.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
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
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _remainder += event.scrollDelta.dy;
      _reset?.cancel();
      _reset = Timer(const Duration(milliseconds: 250), () => _remainder = 0);
      final steps = (_remainder / 20).truncate();
      if (steps == 0) return;
      _remainder -= steps * 20;
      unawaited(widget.controller.adjustVolume(-steps * 5));
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerSignal: _handleSignal,
    child: widget.child,
  );
}
