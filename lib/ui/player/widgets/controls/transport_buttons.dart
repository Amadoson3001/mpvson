import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../ui/core/app_motion.dart';
import '../../../../ui/core/app_theme.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';

/// Previous, play/pause and next controls used by both shell and overlay.
class TransportButtons extends StatelessWidget {
  const TransportButtons({
    super.key,
    required this.controller,
    this.compact = false,
    this.showStop = true,
    this.showShuffleRepeat = false,
  });

  /// Width of the control row, measured from the same extents the buttons are
  /// built with so surrounding layout can reserve the right amount of space.
  static double preferredWidth({
    required bool compact,
    bool showStop = true,
    bool showShuffleRepeat = false,
  }) {
    final extent = compact
        ? PlayerControlStyle.compactControlExtent
        : PlayerControlStyle.controlExtent;
    final gap = compact ? 2.0 : 4.0;
    var count = 3;
    if (showStop) count++;
    if (showShuffleRepeat) count += 2;
    return count * extent + (count - 1) * gap;
  }

  /// Shift that puts the play/pause button on the row's center line.
  ///
  /// Three secondary buttons flank the play button, so the row's midpoint
  /// falls between the play and next buttons. Nudging the row by half that
  /// difference centers the play button — the anchor of the control band —
  /// instead of the gap between two buttons.
  static double playButtonCenterOffset({
    required bool compact,
    bool showStop = true,
    bool showShuffleRepeat = false,
  }) {
    if ((showShuffleRepeat && !showStop) || (!showStop && !showShuffleRepeat)) {
      return 0.0;
    }
    final extent = compact
        ? PlayerControlStyle.compactControlExtent
        : PlayerControlStyle.controlExtent;
    final gap = compact ? 2.0 : 4.0;
    return preferredWidth(
              compact: compact,
              showStop: showStop,
              showShuffleRepeat: showShuffleRepeat,
            ) /
            2 -
        (extent + gap + extent / 2);
  }

  final PlayerController controller;
  final bool compact;
  final bool showStop;
  final bool showShuffleRepeat;

  @override
  Widget build(BuildContext context) => PlayerControlStyle(
    compact: compact,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showShuffleRepeat) ...[
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ControlToggleButton(
              tooltip: controller.shuffle
                  ? 'Turn shuffle off'
                  : 'Turn shuffle on',
              icon: Icons.shuffle_rounded,
              active: controller.shuffle,
              onPressed: controller.toggleShuffle,
            ),
          ),
          SizedBox(width: compact ? 4 : 8),
        ],
        _TransportButton(
          tooltip: 'Previous',
          icon: Icons.skip_previous_rounded,
          onPressed: controller.current == null ? null : controller.previous,
        ),
        SizedBox(width: compact ? 4 : 8),
        // The glyph follows the transport listenable rather than this widget's
        // own rebuilds: views that deliberately skip rebuilds while a track
        // plays (Now Playing) would otherwise strand it on a stale shape.
        ValueListenableBuilder<TransportState>(
          valueListenable: controller.transportListenable,
          builder: (context, transport, _) => _PlayPauseButton(
            isPlaying: transport.isPlaying,
            isBuffering: transport.isBuffering,
            onPressed: controller.current == null
                ? null
                : controller.togglePlayPause,
          ),
        ),
        SizedBox(width: compact ? 4 : 8),
        _TransportButton(
          tooltip: 'Next',
          icon: Icons.skip_next_rounded,
          onPressed: controller.current == null ? null : controller.next,
        ),
        if (showShuffleRepeat) ...[
          SizedBox(width: compact ? 4 : 8),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final mode = controller.repeatMode;
              final icon = mode == 'one'
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded;
              final tip = mode == 'off'
                  ? 'Enable repeat'
                  : mode == 'all'
                  ? 'Repeat current'
                  : 'Disable repeat';
              return ControlToggleButton(
                tooltip: tip,
                icon: icon,
                active: mode != 'off',
                onPressed: controller.cycleRepeat,
              );
            },
          ),
        ],
        if (showStop) ...[
          SizedBox(width: compact ? 4 : 8),
          _TransportButton(
            tooltip: 'Stop',
            icon: Icons.stop_rounded,
            onPressed: controller.current == null ? null : controller.stop,
          ),
        ],
      ],
    ),
  );
}

class _TransportButton extends StatefulWidget {
  const _TransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final style = PlayerControlStyle.of(context);
    final reduced = AppMotion.reduce(context);
    return SizedBox.square(
      dimension: style.buttonExtent,
      child: AnimatedScale(
        scale: (reduced || !_pressed) ? 1.0 : 0.92,
        duration: AppMotion.duration(context, AppMotion.press),
        curve: AppMotion.enter,
        child: Listener(
          onPointerDown: (_) {
            if (widget.onPressed != null && !_pressed) {
              setState(() => _pressed = true);
            }
          },
          onPointerUp: (_) {
            if (_pressed) setState(() => _pressed = false);
          },
          onPointerCancel: (_) {
            if (_pressed) setState(() => _pressed = false);
          },
          child: IconButton(
            tooltip: widget.tooltip,
            onPressed: widget.onPressed,
            style: style.buttonStyle.copyWith(
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return context.palette.faint;
                }
                return context.palette.primaryText.withValues(alpha: 0.88);
              }),
            ),
            icon: Icon(
              widget.icon,
              size: style.compact ? 18 : 22,
              color: widget.onPressed == null
                  ? context.palette.faint
                  : context.palette.primaryText.withValues(alpha: 0.9),
            ),
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}

class ControlToggleButton extends StatelessWidget {
  const ControlToggleButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = PlayerControlStyle.of(context);
    return SizedBox.square(
      dimension: style.buttonExtent,
      child: IconButton(
        tooltip: tooltip,
        isSelected: active,
        onPressed: onPressed,
        style: style.buttonStyle.copyWith(
          animationDuration: AppMotion.duration(context, AppMotion.quick),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Theme.of(context).colorScheme.primary;
            }
            if (states.contains(WidgetState.disabled)) {
              return context.palette.faint;
            }
            return context.palette.primaryText.withValues(alpha: 0.88);
          }),
        ),
        icon: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppMotion.quick),
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          transitionBuilder: (child, animation) {
            if (AppMotion.reduce(context)) return child;
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                child: child,
              ),
            );
          },
          child: Icon(
            icon,
            key: ValueKey<IconData>(icon),
            size: style.iconSize,
            color: active
                ? Theme.of(context).colorScheme.primary
                : context.palette.primaryText.withValues(alpha: 0.9),
          ),
        ),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({
    required this.isPlaying,
    required this.isBuffering,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback? onPressed;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _playPauseController = AnimationController(
    vsync: this,
    duration: AppMotion.standard,
    value: widget.isPlaying ? 1 : 0,
  );
  late final CurvedAnimation _playPauseProgress = CurvedAnimation(
    parent: _playPauseController,
    curve: AppMotion.standardCurve,
  );
  bool _reduceMotion = false;
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = AppMotion.reduce(context);
    _playPauseController.duration = AppMotion.duration(
      context,
      AppMotion.standard,
    );
    if (_reduceMotion) {
      _playPauseController
        ..stop()
        ..value = widget.isPlaying ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant _PlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying == widget.isPlaying) return;

    if (_reduceMotion) {
      _playPauseController.value = widget.isPlaying ? 1 : 0;
    } else if (widget.isPlaying) {
      unawaited(_playPauseController.forward());
    } else {
      unawaited(_playPauseController.reverse());
    }
  }

  @override
  void dispose() {
    _playPauseProgress.dispose();
    _playPauseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = PlayerControlStyle.of(context);
    final iconSize = style.compact ? 21.0 : 27.0;
    return SizedBox.square(
      dimension: style.buttonExtent,
      child: AnimatedScale(
        scale: (_reduceMotion || !_pressed) ? 1.0 : 0.92,
        duration: AppMotion.duration(context, AppMotion.press),
        curve: AppMotion.enter,
        child: Listener(
          onPointerDown: (_) {
            if (widget.onPressed != null && !_pressed) {
              setState(() => _pressed = true);
            }
          },
          onPointerUp: (_) {
            if (_pressed) setState(() => _pressed = false);
          },
          onPointerCancel: (_) {
            if (_pressed) setState(() => _pressed = false);
          },
          child: IconButton.filled(
            tooltip: widget.isPlaying ? 'Pause' : 'Play',
            onPressed: widget.onPressed,
            style: style.buttonStyle.copyWith(
              backgroundColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.primary,
              ),
              foregroundColor: WidgetStatePropertyAll(
                context.palette.accentForeground,
              ),
              shape: const WidgetStatePropertyAll(CircleBorder()),
            ),
            icon: RepaintBoundary(
              child: SizedBox.square(
                dimension: iconSize,
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(context, AppMotion.standard),
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  transitionBuilder: (child, animation) {
                    if (AppMotion.reduce(context)) return child;
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.9,
                          end: 1,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: widget.isBuffering
                      ? Center(
                          key: const ValueKey('playback-buffering'),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.palette.accentForeground,
                            ),
                          ),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('playback-morph'),
                          child: AnimatedIcon(
                            icon: AnimatedIcons.play_pause,
                            progress: _playPauseProgress,
                            size: iconSize,
                            color: context.palette.accentForeground,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlaybackRateMenu extends StatelessWidget {
  const PlaybackRateMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    final speedText =
        '${controller.rate.toStringAsFixed(controller.rate == controller.rate.roundToDouble() ? 0 : 2)}×';
    return Semantics(
      label: 'Playback speed, selected $speedText',
      button: true,
      child: PopupMenuButton<double>(
        tooltip: 'Playback speed',
        initialValue: _nearestRate(controller.rate),
        onOpened: () => onMenuVisibilityChanged?.call(true),
        onCanceled: () => onMenuVisibilityChanged?.call(false),
        onSelected: (rate) {
          onMenuVisibilityChanged?.call(false);
          unawaited(controller.setRate(rate));
        },
        itemBuilder: (context) =>
            const <double>[0.5, 0.75, 1, 1.25, 1.5, 2].map((rate) {
              final isSelected = (controller.rate - rate).abs() < 0.01;
              final label = rate == 1 ? 'Normal speed' : '$rate×';
              return PopupMenuItem<double>(
                value: rate,
                child: Semantics(
                  selected: isSelected,
                  label: isSelected ? '$label, selected' : label,
                  child: Text(label),
                ),
              );
            }).toList(),
        child: SizedBox(
          width: PlayerControlStyle.of(context).compact ? 40 : 52,
          height: PlayerControlStyle.of(context).buttonExtent,
          child: Center(
            child: Text(
              speedText,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: context.palette.secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static double _nearestRate(double rate) => const [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);
}
