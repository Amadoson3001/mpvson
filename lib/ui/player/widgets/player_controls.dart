import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/models/control_density.dart';
import '../../../ui/core/app_motion.dart';
import '../../../ui/core/app_theme.dart';
import '../player_controller.dart';
import 'player_control_style.dart';

void _notifyInteractionOnDispose(ValueChanged<bool>? callback) {
  if (callback == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => callback(false));
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
      controller.positionListenable,
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
            decoration: _bottomGradient,
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
                  AnimatedBuilder(
                    animation: timeline,
                    builder: (context, _) => _SeekBar(
                      controller: controller,
                      onPreviewChanged: _updateScrubPosition,
                      onInteractionChanged: widget.onInteractionChanged,
                    ),
                  ),
                  SizedBox(height: dense ? 0 : 4),
                  SizedBox(
                    height: sizing.buttonExtent,
                    child: Row(
                      children: [
                        _TransportButton(
                          tooltip: 'Previous',
                          icon: Icons.skip_previous_rounded,
                          onPressed: controller.previous,
                        ),
                        SizedBox(width: dense ? 2 : 4),
                        _PlayPauseButton(
                          isPlaying: controller.isPlaying,
                          isBuffering: controller.isBuffering,
                          onPressed: controller.togglePlayPause,
                        ),
                        SizedBox(width: dense ? 2 : 4),
                        _TransportButton(
                          tooltip: 'Next',
                          icon: Icons.skip_next_rounded,
                          onPressed: controller.next,
                        ),
                        SizedBox(width: dense ? 6 : 10),
                        _ToggleButton(
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
                        _ToggleButton(
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
                          builder: (context, _) => _TimeReadout(
                            position: _scrubPosition ?? controller.position,
                            duration: controller.duration,
                          ),
                        ),
                        const Spacer(),
                        if (narrow)
                          _VolumeMenu(
                            controller: controller,
                            onMenuVisibilityChanged:
                                widget.onMenuVisibilityChanged,
                            onInteractionChanged: widget.onInteractionChanged,
                            onVolumeChanged: widget.onVolumeChanged,
                          )
                        else
                          _InlineVolumeControl(
                            controller: controller,
                            onInteractionChanged: widget.onInteractionChanged,
                            onVolumeChanged: widget.onVolumeChanged,
                          ),
                        _RateMenu(
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

  static final BoxDecoration _bottomGradient = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        AppTheme.background.withValues(alpha: 0),
        AppTheme.background.withValues(alpha: 0.76),
        AppTheme.background.withValues(alpha: 0.96),
      ],
      stops: const [0, 0.34, 1],
    ),
  );

  static String _formatTime(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _ActionsFooter extends StatelessWidget {
  const _ActionsFooter({required this.actions});

  final Widget actions;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: _PlayerControlsState._bottomGradient,
    child: SizedBox(
      height: PlayerControlStyle.of(context).compact ? 44 : 60,
      child: Padding(
        padding: PlayerControlStyle.of(context).compact
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
            : const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Align(alignment: Alignment.centerRight, child: actions),
      ),
    ),
  );
}

class _TimeReadout extends StatelessWidget {
  const _TimeReadout({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final elapsed = _PlayerControlsState._formatTime(position);
    final total = duration > Duration.zero
        ? _PlayerControlsState._formatTime(duration)
        : '--:--';
    return SizedBox(
      width: duration.inHours > 0 ? 132 : 104,
      child: Text(
        '$elapsed / $total',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppTheme.secondaryText,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.controller,
    required this.onPreviewChanged,
    required this.onInteractionChanged,
  });

  final PlayerController controller;
  final ValueChanged<Duration?> onPreviewChanged;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  static const _keyboardSeekDelay = Duration(milliseconds: 140);

  final FocusNode _focusNode = FocusNode(debugLabel: 'Seek video');
  Timer? _keyboardSeekTimer;
  double? _scrubPositionMs;
  double? _hoverPositionMs;
  double _hoverTrackX = 0;
  bool _dragging = false;
  bool _pointerInside = false;
  bool _keyboardSeeking = false;
  bool _focused = false;
  bool _pointerIsDown = false;
  bool _interactionActive = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _keyboardSeekTimer?.cancel();
    if (_interactionActive) {
      _notifyInteractionOnDispose(widget.onInteractionChanged);
    }
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    final focused = _focusNode.hasFocus;
    if (!mounted) return;
    setState(() => _focused = focused);
    final position = _scrubPositionMs;
    if (!focused && _keyboardSeeking && !_dragging && position != null) {
      unawaited(_commitSeek(position));
    }
  }

  void _onPointerMove(double localX, double trackWidth, int durationMs) {
    if (trackWidth <= 0 || durationMs <= 0) return;

    // The slider and its theme both set zero padding. The stock rounded track
    // therefore spans this full render box, so local x maps directly to time.
    final trackX = localX.clamp(0.0, trackWidth).toDouble();
    final physicalRatio = trackX / trackWidth;
    final ratio = Directionality.of(context) == TextDirection.rtl
        ? 1 - physicalRatio
        : physicalRatio;
    setState(() {
      _pointerInside = true;
      _hoverTrackX = trackX;
      _hoverPositionMs = (ratio * durationMs).roundToDouble();
    });
  }

  void _onPointerExit() {
    setState(() {
      _pointerInside = false;
      _hoverPositionMs = null;
    });
  }

  double _trackXForValue(double value, double trackWidth, int durationMs) {
    if (durationMs <= 0 || trackWidth <= 0) return 0;
    final ratio = (value / durationMs).clamp(0.0, 1.0).toDouble();
    final physicalRatio = Directionality.of(context) == TextDirection.rtl
        ? 1 - ratio
        : ratio;
    return physicalRatio * trackWidth;
  }

  void _onChangeStart(double value, double width, int durationMs) {
    _focusNode.requestFocus();
    _keyboardSeekTimer?.cancel();
    if (_pointerIsDown) _setInteracting(true);
    widget.onPreviewChanged(Duration(milliseconds: value.round()));
    setState(() {
      _dragging = true;
      _keyboardSeeking = false;
      _scrubPositionMs = value;
      _hoverPositionMs = value;
      _hoverTrackX = _trackXForValue(value, width, durationMs);
    });
  }

  void _onChanged(double value, double width, int durationMs) {
    widget.onPreviewChanged(Duration(milliseconds: value.round()));
    setState(() {
      _scrubPositionMs = value;
      _keyboardSeeking = !_dragging;
      _hoverPositionMs = value;
      _hoverTrackX = _trackXForValue(value, width, durationMs);
    });
    if (_dragging) return;

    // Keyboard slider actions have no drag-end callback on every platform.
    // Commit after a short idle period while pointer drags commit on release.
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = Timer(
      _keyboardSeekDelay,
      () => unawaited(_commitSeek(value)),
    );
  }

  void _onChangeEnd(double value) {
    _dragging = false;
    _setInteracting(false);
    unawaited(_commitSeek(value));
  }

  void _setInteracting(bool interacting) {
    if (_interactionActive == interacting) return;
    _interactionActive = interacting;
    widget.onInteractionChanged?.call(interacting);
  }

  void _cancelPointerDrag() {
    if (!_interactionActive) return;
    _dragging = false;
    _setInteracting(false);
    widget.onPreviewChanged(null);
    if (mounted) setState(() => _scrubPositionMs = null);
  }

  Future<void> _commitSeek(double value) async {
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = null;
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _keyboardSeeking = false;
      _scrubPositionMs = value;
      _hoverPositionMs = value;
    });
    try {
      await widget.controller.seek(Duration(milliseconds: value.round()));
    } finally {
      widget.onPreviewChanged(null);
      if (mounted) setState(() => _scrubPositionMs = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final durationMs = controller.duration.inMilliseconds;
    final canSeek = durationMs > 0;
    final positionMs = (_scrubPositionMs ?? controller.position.inMilliseconds)
        .clamp(0, canSeek ? durationMs : 0)
        .toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final previewMs = _dragging || _keyboardSeeking
            ? (_scrubPositionMs ?? positionMs)
            : (_hoverPositionMs ?? positionMs);
        final previewTime = Duration(milliseconds: previewMs.round());
        final previewLabel = _PlayerControlsState._formatTime(previewTime);
        final bubbleWidth = previewLabel.length > 5 ? 72.0 : 58.0;
        final previewX = _dragging || _keyboardSeeking
            ? _trackXForValue(previewMs, width, durationMs)
            : _hoverTrackX;
        final bubbleLeft = (previewX - bubbleWidth / 2)
            .clamp(0.0, (width - bubbleWidth).clamp(0.0, width))
            .toDouble();
        final showPreview =
            canSeek && (_pointerInside || _dragging || _keyboardSeeking);
        final thumbVisible =
            canSeek && (_pointerInside || _dragging || _focused);

        return Listener(
          onPointerDown: (_) => _pointerIsDown = true,
          onPointerUp: (_) => _pointerIsDown = false,
          onPointerCancel: (_) {
            _pointerIsDown = false;
            _cancelPointerDrag();
          },
          child: MouseRegion(
            onEnter: (event) =>
                _onPointerMove(event.localPosition.dx, width, durationMs),
            onHover: (event) =>
                _onPointerMove(event.localPosition.dx, width, durationMs),
            onExit: (_) => _onPointerExit(),
            child: SizedBox(
              width: width,
              height: PlayerControlStyle.of(context).seekHitHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: PlayerControlStyle.of(context).compact
                            ? 4
                            : 3,
                        trackShape: const _UniformRoundedSliderTrackShape(),
                        trackGap: 0,
                        thumbShape: thumbVisible
                            ? const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                                disabledThumbRadius: 5,
                                elevation: 0,
                                pressedElevation: 0,
                              )
                            : SliderComponentShape.noThumb,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: AppTheme.accent,
                        inactiveTrackColor: AppTheme.border,
                        disabledActiveTrackColor: AppTheme.muted,
                        disabledInactiveTrackColor: AppTheme.border,
                        overlayColor: AppTheme.accent.withValues(alpha: 0.16),
                        thumbColor: AppTheme.accent,
                        padding: EdgeInsets.zero,
                      ),
                      child: Slider(
                        key: const ValueKey('seek-slider'),
                        focusNode: _focusNode,
                        value: positionMs,
                        min: 0,
                        max: canSeek ? durationMs.toDouble() : 1,
                        onChangeStart: canSeek
                            ? (value) =>
                                  _onChangeStart(value, width, durationMs)
                            : null,
                        onChanged: canSeek
                            ? (value) => _onChanged(value, width, durationMs)
                            : null,
                        onChangeEnd: canSeek ? _onChangeEnd : null,
                        padding: EdgeInsets.zero,
                        semanticFormatterCallback: (value) =>
                            'Seek to ${_PlayerControlsState._formatTime(Duration(milliseconds: value.round()))}',
                      ),
                    ),
                  ),
                  Positioned(
                    key: const ValueKey('seek-preview'),
                    left: bubbleLeft,
                    top: -26,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: AppMotion.duration(context, AppMotion.quick),
                        switchInCurve: AppMotion.enter,
                        switchOutCurve: AppMotion.exit,
                        transitionBuilder: (child, animation) {
                          if (AppMotion.reduce(context)) return child;
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.16),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: showPreview
                            ? RepaintBoundary(
                                key: const ValueKey('seek-preview-content'),
                                child: _SeekPreview(
                                  label: previewLabel,
                                  width: bubbleWidth,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UniformRoundedSliderTrackShape extends RoundedRectSliderTrackShape {
  const _UniformRoundedSliderTrackShape();

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

class _SeekPreview extends StatelessWidget {
  const _SeekPreview({required this.label, required this.width});

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppTheme.border),
    ),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AppTheme.text,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: PlayerControlStyle.of(context).buttonExtent,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: PlayerControlStyle.of(context).buttonStyle,
      icon: Icon(icon, size: PlayerControlStyle.of(context).compact ? 18 : 22),
      padding: EdgeInsets.zero,
    ),
  );
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
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
  final VoidCallback onPressed;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _playPauseController = AnimationController(
    vsync: this,
    duration: AppMotion.quick,
    value: widget.isPlaying ? 1 : 0,
  );
  late final Animation<double> _playPauseProgress = CurvedAnimation(
    parent: _playPauseController,
    curve: AppMotion.standardCurve,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = AppMotion.reduce(context);
    _playPauseController.duration = AppMotion.duration(
      context,
      AppMotion.quick,
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
    _playPauseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = PlayerControlStyle.of(context);
    final iconSize = style.compact ? 21.0 : 27.0;
    return SizedBox.square(
      dimension: style.buttonExtent,
      child: IconButton.filled(
        tooltip: widget.isPlaying ? 'Pause' : 'Play',
        onPressed: widget.onPressed,
        style: style.buttonStyle.copyWith(
          backgroundColor: const WidgetStatePropertyAll(AppTheme.accent),
          foregroundColor: const WidgetStatePropertyAll(
            AppTheme.accentForeground,
          ),
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
        icon: RepaintBoundary(
          child: SizedBox.square(
            dimension: iconSize,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              transitionBuilder: (child, animation) {
                if (AppMotion.reduce(context)) return child;
                return FadeTransition(opacity: animation, child: child);
              },
              child: widget.isBuffering
                  ? const Center(
                      key: ValueKey('playback-buffering'),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.accentForeground,
                        ),
                      ),
                    )
                  : KeyedSubtree(
                      key: const ValueKey('playback-morph'),
                      child: AnimatedIcon(
                        key: ValueKey<bool>(widget.isPlaying),
                        icon: AnimatedIcons.play_pause,
                        progress: _playPauseProgress,
                        size: iconSize,
                        color: AppTheme.accentForeground,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RateMenu extends StatelessWidget {
  const _RateMenu({
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
                color: AppTheme.secondaryText,
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

class _InlineVolumeControl extends StatefulWidget {
  const _InlineVolumeControl({
    required this.controller,
    required this.onInteractionChanged,
    required this.onVolumeChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;

  @override
  State<_InlineVolumeControl> createState() => _InlineVolumeControlState();
}

class _InlineVolumeControlState extends State<_InlineVolumeControl> {
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
      // Update the controller's remembered audible level before toggling. Both
      // writes share the controller's serialized volume queue.
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
          ],
        ),
      ),
    );
  }
}

class _VolumeMenu extends StatelessWidget {
  const _VolumeMenu({
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
          showDialog<void>(
            context: context,
            builder: (_) => _VolumeDialog(
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

class _VolumeDialog extends StatefulWidget {
  const _VolumeDialog({
    required this.controller,
    required this.onInteractionChanged,
    required this.onVolumeChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onInteractionChanged;
  final ValueChanged<double>? onVolumeChanged;

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final volume = (_pendingVolume ?? widget.controller.volume)
          .clamp(0.0, 100.0)
          .toDouble();
      return AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('Volume')),
            Text(
              '${volume.round()}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppTheme.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 310,
          child: Listener(
            onPointerDown: (_) => _pointerIsDown = true,
            onPointerUp: (_) => _pointerIsDown = false,
            onPointerCancel: (_) {
              _pointerIsDown = false;
              _cancelPointerDrag();
            },
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
