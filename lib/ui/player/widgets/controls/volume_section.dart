import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../ui/core/app_motion.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../ui/core/components/app_dialog.dart';
import '../../../../ui/core/slider_overlay.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';
import 'seek_bar_track_shape.dart';

void _notifyInteractionOnDispose(ValueChanged<bool>? callback) {
  if (callback == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => callback(false));
}

class InlineVolumeControl extends StatefulWidget {
  const InlineVolumeControl({
    super.key,
    required this.controller,
    required this.onInteractionChanged,
    required this.onVolumeChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;

  @override
  State<InlineVolumeControl> createState() => _InlineVolumeControlState();
}

class _InlineVolumeControlState extends State<InlineVolumeControl> {
  static const _volumeDebounce = Duration(milliseconds: 90);

  final FocusNode _focusNode = FocusNode(debugLabel: 'Inline volume');
  Timer? _commitTimer;
  double? _pendingVolume;
  int _changeId = 0;
  bool _pointerIsDown = false;
  bool _interactionActive = false;

  @override
  void dispose() {
    _focusNode.dispose();
    _commitTimer?.cancel();
    if (_interactionActive) {
      _notifyInteractionOnDispose(widget.onInteractionChanged);
    }
    super.dispose();
  }

  void _setInteracting(bool interacting) {
    if (_interactionActive == interacting) return;
    _interactionActive = interacting;
    widget.onInteractionChanged?.call(interacting);
  }

  void _onChangeStart(double _) {
    _focusNode.requestFocus();
    if (_pointerIsDown) _setInteracting(true);
  }

  void _onChanged(double value) {
    final changeId = ++_changeId;
    setState(() => _pendingVolume = value);
    _commitTimer?.cancel();
    _commitTimer = Timer(
      _volumeDebounce,
      () => unawaited(_applyVolume(value, changeId)),
    );
  }

  void _onChangeEnd(double value) {
    final changeId = ++_changeId;
    _commitTimer?.cancel();
    setState(() => _pendingVolume = value);
    unawaited(_applyVolume(value, changeId));
  }

  Future<void> _applyVolume(double value, int changeId) async {
    final operation = widget.controller.setVolume(value);
    widget.onVolumeChanged?.call(widget.controller.volume);
    await operation;
    if (mounted && changeId == _changeId) {
      setState(() => _pendingVolume = null);
      if (widget.controller.volume != value) {
        widget.onVolumeChanged?.call(widget.controller.volume);
      }
    }
  }

  void _toggleMute() {
    final pendingVolume = _pendingVolume;
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    setState(() => _pendingVolume = null);
    unawaited(_toggleMuteInController(pendingVolume));
  }

  Future<void> _toggleMuteInController(double? pendingVolume) async {
    if (pendingVolume != null) {
      unawaited(widget.controller.setVolume(pendingVolume));
    }
    final operation = widget.controller.toggleMute();
    final requestedVolume = widget.controller.volume;
    widget.onVolumeChanged?.call(requestedVolume);
    await operation;
    if (mounted && widget.controller.volume != requestedVolume) {
      widget.onVolumeChanged?.call(widget.controller.volume);
    }
  }

  void _cancelPointerDrag() {
    if (!_interactionActive) return;
    _setInteracting(false);
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    if (mounted) setState(() => _pendingVolume = null);
  }

  void _handleWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final steps = (event.scrollDelta.dy / 20).truncate();
      final stepCount = steps != 0 ? steps : event.scrollDelta.dy.sign.toInt();
      final current = _pendingVolume ?? widget.controller.volume;
      final target = (current - stepCount * 5).clamp(0.0, 100.0).toDouble();
      _onChanged(target);
      _onChangeEnd(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final volume = (_pendingVolume ?? widget.controller.volume)
        .clamp(0.0, 100.0)
        .toDouble();
    final style = PlayerControlStyle.of(context);
    final buttonExtent = style.buttonExtent;
    final controlWidth = style.compact ? 116.0 : 144.0;
    final sliderWidth = controlWidth - buttonExtent;
    final icon = volume <= 0
        ? Icons.volume_off_rounded
        : volume < 50
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _handleWheel,
      onPointerDown: (_) => _pointerIsDown = true,
      onPointerUp: (_) => _pointerIsDown = false,
      onPointerCancel: (_) {
        _pointerIsDown = false;
        _cancelPointerDrag();
      },
      child: SizedBox(
        width: controlWidth,
        height: buttonExtent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: buttonExtent,
              child: IconButton(
                tooltip: volume <= 0 ? 'Unmute' : 'Mute',
                onPressed: _toggleMute,
                style: style.buttonStyle,
                icon: SizedBox.square(
                  dimension: style.iconSize,
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(context, AppMotion.quick),
                    switchInCurve: AppMotion.enter,
                    switchOutCurve: AppMotion.exit,
                    transitionBuilder: (child, animation) {
                      if (AppMotion.reduce(context)) return child;
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Icon(
                      icon,
                      key: ValueKey<IconData>(icon),
                      size: style.iconSize,
                    ),
                  ),
                ),
                padding: EdgeInsets.zero,
              ),
            ),
            SizedBox(
              width: sliderWidth,
              height: buttonExtent,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3.2,
                  trackShape: const UniformRoundedSliderTrackShape(),
                  trackGap: 0,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 4.5,
                    elevation: 1,
                    pressedElevation: 2.5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                  thumbColor: Colors.white,
                  overlayColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.16),
                  padding: EdgeInsets.zero,
                ),
                child: SliderOverlay(
                  child: Slider(
                    key: const ValueKey('volume-inline-slider'),
                    focusNode: _focusNode,
                    value: volume,
                    min: 0,
                    max: 100,
                    divisions: 100,
                    onChangeStart: _onChangeStart,
                    onChanged: _onChanged,
                    onChangeEnd: (value) {
                      _setInteracting(false);
                      _onChangeEnd(value);
                    },
                    semanticFormatterCallback: (value) =>
                        'Volume ${value.round()} percent',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VolumeMenu extends StatelessWidget {
  const VolumeMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
    required this.onInteractionChanged,
    required this.onVolumeChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final style = PlayerControlStyle.of(context);
    final icon = controller.volume <= 0
        ? Icons.volume_off_rounded
        : controller.volume < 50
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return IconButton(
      tooltip: 'Volume ${controller.volume.round()}%',
      style: style.buttonStyle,
      onPressed: () {
        onMenuVisibilityChanged?.call(true);
        unawaited(
          AppDialog.show<void>(
            context: context,
            builder: (_) => VolumeDialog(
              controller: controller,
              onInteractionChanged: onInteractionChanged,
              onVolumeChanged: onVolumeChanged,
            ),
          ).whenComplete(() => onMenuVisibilityChanged?.call(false)),
        );
      },
      icon: SizedBox.square(
        dimension: style.iconSize,
        child: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppMotion.quick),
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          transitionBuilder: (child, animation) {
            if (AppMotion.reduce(context)) return child;
            return FadeTransition(opacity: animation, child: child);
          },
          child: Icon(
            icon,
            key: ValueKey<IconData>(icon),
            size: style.iconSize,
          ),
        ),
      ),
      padding: EdgeInsets.zero,
    );
  }
}

class VolumeDialog extends StatefulWidget {
  const VolumeDialog({
    super.key,
    required this.controller,
    required this.onInteractionChanged,
    required this.onVolumeChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;

  @override
  State<VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<VolumeDialog> {
  static const _volumeDebounce = Duration(milliseconds: 90);

  Timer? _commitTimer;
  double? _pendingVolume;
  int _changeId = 0;
  bool _pointerIsDown = false;
  bool _interactionActive = false;

  @override
  void dispose() {
    _commitTimer?.cancel();
    if (_interactionActive) {
      _notifyInteractionOnDispose(widget.onInteractionChanged);
    }
    super.dispose();
  }

  void _setInteracting(bool interacting) {
    if (_interactionActive == interacting) return;
    _interactionActive = interacting;
    widget.onInteractionChanged?.call(interacting);
  }

  void _onChangeStart(double _) {
    if (_pointerIsDown) _setInteracting(true);
  }

  void _onChanged(double value) {
    final changeId = ++_changeId;
    setState(() => _pendingVolume = value);
    _commitTimer?.cancel();
    _commitTimer = Timer(
      _volumeDebounce,
      () => unawaited(_applyVolume(value, changeId)),
    );
  }

  void _onChangeEnd(double value) {
    final changeId = ++_changeId;
    _commitTimer?.cancel();
    setState(() => _pendingVolume = value);
    unawaited(_applyVolume(value, changeId));
  }

  Future<void> _applyVolume(double value, int changeId) async {
    final operation = widget.controller.setVolume(value);
    widget.onVolumeChanged?.call(widget.controller.volume);
    await operation;
    if (mounted && changeId == _changeId) {
      setState(() => _pendingVolume = null);
      if (widget.controller.volume != value) {
        widget.onVolumeChanged?.call(widget.controller.volume);
      }
    }
  }

  void _cancelPointerDrag() {
    if (!_interactionActive) return;
    _setInteracting(false);
    _commitTimer?.cancel();
    _commitTimer = null;
    _changeId++;
    if (mounted) setState(() => _pendingVolume = null);
  }

  void _handleWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final steps = (event.scrollDelta.dy / 20).truncate();
      final stepCount = steps != 0 ? steps : event.scrollDelta.dy.sign.toInt();
      final current = _pendingVolume ?? widget.controller.volume;
      final target = (current - stepCount * 5).clamp(0.0, 100.0).toDouble();
      _onChanged(target);
      _onChangeEnd(target);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final volume = (_pendingVolume ?? widget.controller.volume)
          .clamp(0.0, 100.0)
          .toDouble();
      return AppDialog(
        maxWidth: 360,
        title: Row(
          children: [
            const Expanded(child: Text('Volume')),
            Text(
              '${volume.round()}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: context.palette.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 310,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: _handleWheel,
            onPointerDown: (_) => _pointerIsDown = true,
            onPointerUp: (_) => _pointerIsDown = false,
            onPointerCancel: (_) {
              _pointerIsDown = false;
              _cancelPointerDrag();
            },
            child: SliderOverlay(
              child: Slider(
                key: const ValueKey('volume-slider'),
                value: volume,
                min: 0,
                max: 100,
                divisions: 100,
                onChangeStart: _onChangeStart,
                onChanged: _onChanged,
                onChangeEnd: (value) {
                  _setInteracting(false);
                  _onChangeEnd(value);
                },
                semanticFormatterCallback: (value) =>
                    'Volume ${value.round()} percent',
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}
