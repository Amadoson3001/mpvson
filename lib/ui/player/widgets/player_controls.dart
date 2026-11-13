import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../app.dart' show AppPreferencesScope;
import '../../../domain/models/control_density.dart';
import '../../../domain/models/player_controls_preferences.dart';
import '../../../ui/core/app_motion.dart';
import '../../../ui/core/app_theme.dart';
import '../../../utils/format.dart';
import '../player_controller.dart';
import 'player_control_style.dart';
import 'controls/playback_rate_menu.dart';
import 'controls/seek_bar_section.dart';
import 'controls/transport_buttons.dart';
import 'controls/volume_section.dart';

export 'controls/seek_bar_section.dart';
export 'controls/seek_preview.dart';
export 'controls/transport_buttons.dart';
export 'controls/volume_section.dart';

class TimeReadout extends StatefulWidget {
  const TimeReadout({
    super.key,
    required this.position,
    required this.duration,
    this.initialShowRemaining = false,
  });

  final Duration position;
  final Duration duration;
  final bool initialShowRemaining;

  @override
  State<TimeReadout> createState() => _TimeReadoutState();
}

class _TimeReadoutState extends State<TimeReadout> {
  late bool _showRemaining = widget.initialShowRemaining;

  @override
  void didUpdateWidget(covariant TimeReadout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialShowRemaining != widget.initialShowRemaining) {
      _showRemaining = widget.initialShowRemaining;
    }
  }

  void _toggleDisplay() {
    setState(() => _showRemaining = !_showRemaining);
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.position;
    final duration = widget.duration;
    final elapsed = formatTime(position);
    final String label;

    if (_showRemaining && duration > Duration.zero) {
      final remaining = duration > position
          ? duration - position
          : Duration.zero;
      label = '$elapsed / -${formatTime(remaining)}';
    } else {
      final total = duration > Duration.zero ? formatTime(duration) : '--:--';
      label = '$elapsed / $total';
    }

    return InkWell(
      onTap: duration > Duration.zero ? _toggleDisplay : null,
      borderRadius: BorderRadius.circular(6),
      hoverColor: Colors.white.withValues(alpha: 0.08),
      child: Tooltip(
        message: _showRemaining ? 'Show total duration' : 'Show remaining time',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: SizedBox(
            width: duration.inHours > 0 ? 140 : 112,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.88),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.controller,
    this.preferences,
    this.onMenuVisibilityChanged,
    this.onInteractionChanged,
    this.onVolumeChanged,
    this.actions,
    this.showPlaybackControls = true,
  });

  final PlayerController controller;
  final PlayerControlsPreferences? preferences;
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
    final prefs =
        widget.preferences ??
        AppPreferencesScope.of(context)?.playerControls ??
        const PlayerControlsPreferences();

    final timeline = Listenable.merge(<Listenable>[
      controller.displayPositionListenable,
      controller.durationListenable,
    ]);

    if (!widget.showPlaybackControls) {
      if (actionWidget == null) return const SizedBox.shrink();
      return PlayerControlStyle(
        compact: dense,
        child: _ActionsFooter(actions: actionWidget, prefs: prefs),
      );
    }

    return PlayerControlStyle(
      compact: dense,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 1000;
          final sizing = PlayerControlStyle.of(context);

          final controlContent = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: timeline,
                  builder: (context, _) => SharedSeekBar(
                    controller: controller,
                    thickness: prefs.seekBarThickness,
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
                      showStop: prefs.showStopButton,
                    ),
                    if (prefs.showShuffleRepeat) ...[
                      SizedBox(width: dense ? 6 : 10),
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                              onPressed: () =>
                                  unawaited(controller.cycleRepeat()),
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(width: dense ? 6 : 10),
                    AnimatedBuilder(
                      animation: timeline,
                      builder: (context, _) => TimeReadout(
                        position: _scrubPosition ?? controller.displayPosition,
                        duration: controller.duration,
                        initialShowRemaining: prefs.showRemainingTime,
                      ),
                    ),
                    const Spacer(),
                    if (!prefs.showVolumeSlider || narrow)
                      VolumeMenu(
                        controller: controller,
                        onMenuVisibilityChanged: widget.onMenuVisibilityChanged,
                        onInteractionChanged: widget.onInteractionChanged,
                        onVolumeChanged: widget.onVolumeChanged,
                      )
                    else
                      InlineVolumeControl(
                        controller: controller,
                        onInteractionChanged: widget.onInteractionChanged,
                        onVolumeChanged: widget.onVolumeChanged,
                      ),
                    if (prefs.showSpeedButton)
                      PlaybackRateMenu(
                        controller: controller,
                        onMenuVisibilityChanged: widget.onMenuVisibilityChanged,
                      ),
                    if (actionWidget != null) ...[
                      const SizedBox(width: 4),
                      actionWidget,
                    ],
                  ],
                ),
              ),
            ],
          );

          return _buildStyledShell(
            context: context,
            dense: dense,
            narrow: narrow,
            prefs: prefs,
            child: controlContent,
          );
        },
      ),
    );
  }

  Widget _buildStyledShell({
    required BuildContext context,
    required bool dense,
    required bool narrow,
    required PlayerControlsPreferences prefs,
    required Widget child,
  }) {
    final barStyle = prefs.barStyle;
    final radius = BorderRadius.circular(dense ? 14 : 18);
    final isFloating = barStyle == PlayerControlBarStyle.floatingPill;
    final padding = EdgeInsets.fromLTRB(
      isFloating ? (dense ? 14 : 18) : (dense ? 10 : (narrow ? 14 : 22)),
      dense ? 4 : 8,
      isFloating ? (dense ? 14 : 18) : (dense ? 10 : (narrow ? 14 : 22)),
      dense ? 6 : 10,
    );

    Widget shell = DecoratedBox(
      key: const ValueKey('player-control-strip'),
      decoration: _buildDecoration(context, prefs),
      child: Padding(padding: padding, child: child),
    );

    final allowBlur =
        prefs.enableBlur &&
        !AppMotion.lowPower(context) &&
        !widget.controller.isPlaying;

    if (isFloating) {
      if (allowBlur) {
        shell = BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: shell,
        );
      }
      shell = ClipRRect(borderRadius: radius, child: shell);
    } else if (allowBlur && barStyle == PlayerControlBarStyle.frostedDocked) {
      shell = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: shell,
        ),
      );
    }

    if (isFloating) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          narrow ? 12 : 24,
          0,
          narrow ? 12 : 24,
          dense ? 10 : 16,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: shell,
          ),
        ),
      );
    }

    return shell;
  }

  static BoxDecoration _buildDecoration(
    BuildContext context,
    PlayerControlsPreferences prefs,
  ) {
    final opacity = prefs.backgroundOpacity;
    final barStyle = prefs.barStyle;

    return switch (barStyle) {
      PlayerControlBarStyle.floatingPill => BoxDecoration(
        color: const Color(0xFF0F1117).withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 24,
            offset: const Offset(0, 8),
            spreadRadius: -2,
          ),
        ],
      ),
      PlayerControlBarStyle.cinematicGradient => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: opacity * 0.40),
            Colors.black.withValues(alpha: opacity * 0.85),
            Colors.black.withValues(alpha: opacity),
          ],
          stops: const [0.0, 0.32, 0.72, 1.0],
        ),
      ),
      PlayerControlBarStyle.frostedDocked => BoxDecoration(
        color: const Color(0xFF0F1117).withValues(alpha: opacity),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      PlayerControlBarStyle.minimal => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: opacity * 0.72),
          ],
          stops: const [0.0, 1.0],
        ),
      ),
    };
  }
}

class _ActionsFooter extends StatelessWidget {
  const _ActionsFooter({required this.actions, required this.prefs});

  final Widget actions;
  final PlayerControlsPreferences prefs;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: _PlayerControlsState._buildDecoration(context, prefs),
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
