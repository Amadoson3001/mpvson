import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/models/control_density.dart';
import '../../../ui/core/app_theme.dart';
import '../../../utils/format.dart';
import '../player_controller.dart';
import 'player_control_style.dart';
import 'controls/seek_bar_section.dart';
import 'controls/transport_buttons.dart';
import 'controls/volume_section.dart';

export 'controls/seek_bar_section.dart';
export 'controls/seek_preview.dart';
export 'controls/transport_buttons.dart';
export 'controls/volume_section.dart';

class TimeReadout extends StatelessWidget {
  const TimeReadout({
    super.key,
    required this.position,
    required this.duration,
  });

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final elapsed = formatTime(position);
    final total = duration > Duration.zero ? formatTime(duration) : '--:--';
    return SizedBox(
      width: duration.inHours > 0 ? 132 : 104,
      child: Text(
        '$elapsed / $total',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: context.palette.secondaryText,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.controller,
    this.onMenuVisibilityChanged,
    this.onInteractionChanged,
    this.onVolumeChanged,
    this.actions,
    this.showPlaybackControls = true,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;
  final Widget? actions;
  final bool showPlaybackControls;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  Duration? _scrubPosition;

  void _updateScrubPosition(Duration? position) {
    if (!mounted || _scrubPosition == position) return;
    setState(() => _scrubPosition = position);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: 'Playback controls',
    child: _buildControls(context),
  );

  Widget _buildControls(BuildContext context) {
    final controller = widget.controller;
    final actionWidget = widget.actions;
    final dense = controller.controlDensity == ControlDensity.compact;
    final timeline = Listenable.merge(<Listenable>[
      controller.displayPositionListenable,
      controller.durationListenable,
    ]);
    if (!widget.showPlaybackControls) {
      if (actionWidget == null) return const SizedBox.shrink();
      return PlayerControlStyle(
        compact: dense,
        child: _ActionsFooter(actions: actionWidget),
      );
    }

    return PlayerControlStyle(
      compact: dense,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 1000;
          final sizing = PlayerControlStyle.of(context);
          return DecoratedBox(
            key: const ValueKey('player-control-strip'),
            decoration: _bottomGradient(context),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                dense ? 8 : (narrow ? 14 : 22),
                dense ? 0 : 8,
                dense ? 8 : (narrow ? 14 : 22),
                dense ? 4 : 8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: timeline,
                      builder: (context, _) => SharedSeekBar(
                        controller: controller,
                        onPreviewChanged: _updateScrubPosition,
                        onInteractionChanged: widget.onInteractionChanged,
                      ),
                    ),
                  ),
                  SizedBox(height: dense ? 0 : 4),
                  SizedBox(
                    height: sizing.buttonExtent,
                    child: Row(
                      children: [
                        TransportButtons(
                          controller: controller,
                          compact: dense,
                        ),
                        SizedBox(width: dense ? 6 : 10),
                        ControlToggleButton(
                          key: const ValueKey('shuffle-toggle'),
                          tooltip: controller.shuffle
                              ? 'Turn shuffle off'
                              : 'Turn shuffle on',
                          icon: Icons.shuffle_rounded,
                          active: controller.shuffle,
                          onPressed: () =>
                              unawaited(controller.toggleShuffle()),
                        ),
                        SizedBox(width: dense ? 2 : 4),
                        ControlToggleButton(
                          key: const ValueKey('repeat-toggle'),
                          tooltip: switch (controller.repeatMode) {
                            'one' => 'Repeat current video',
                            'all' => 'Repeat queue',
                            _ => 'Repeat off',
                          },
                          icon: controller.repeatMode == 'one'
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          active: controller.repeatMode != 'off',
                          onPressed: () => unawaited(controller.cycleRepeat()),
                        ),
                        SizedBox(width: dense ? 6 : 10),
                        AnimatedBuilder(
                          animation: timeline,
                          builder: (context, _) => TimeReadout(
                            position:
                                _scrubPosition ?? controller.displayPosition,
                            duration: controller.duration,
                          ),
                        ),
                        const Spacer(),
                        if (narrow)
                          VolumeMenu(
                            controller: controller,
                            onMenuVisibilityChanged:
                                widget.onMenuVisibilityChanged,
                            onInteractionChanged: widget.onInteractionChanged,
                            onVolumeChanged: widget.onVolumeChanged,
                          )
                        else
                          InlineVolumeControl(
                            controller: controller,
                            onInteractionChanged: widget.onInteractionChanged,
                            onVolumeChanged: widget.onVolumeChanged,
                          ),
                        PlaybackRateMenu(
                          controller: controller,
                          onMenuVisibilityChanged:
                              widget.onMenuVisibilityChanged,
                        ),
                        if (actionWidget != null) ...[
                          const SizedBox(width: 4),
                          actionWidget,
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static BoxDecoration _bottomGradient(BuildContext context) => BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        context.palette.background.withValues(alpha: 0),
        context.palette.background.withValues(alpha: 0.76),
        context.palette.background.withValues(alpha: 0.96),
      ],
      stops: const [0, 0.34, 1],
    ),
  );
}

class _ActionsFooter extends StatelessWidget {
  const _ActionsFooter({required this.actions});

  final Widget actions;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: _PlayerControlsState._bottomGradient(context),
    child: SizedBox(
      height: PlayerControlStyle.of(context).compact ? 44 : 60,
      child: Padding(
        padding: PlayerControlStyle.of(context).compact
            ? const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 6)
            : const EdgeInsets.fromLTRB(14, AppSpace.xs, 14, AppSpace.xs),
        child: Align(alignment: Alignment.centerRight, child: actions),
      ),
    ),
  );
}
