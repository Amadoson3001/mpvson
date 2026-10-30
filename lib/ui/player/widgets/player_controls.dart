import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../domain/models/control_density.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../domain/models/playback_chapter.dart';
import '../../../ui/core/app_motion.dart';
import '../../../ui/core/app_theme.dart';
import '../../../ui/core/slider_overlay.dart';
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
                            position:
                                _scrubPosition ?? controller.displayPosition,
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
          color: context.palette.secondaryText,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class SharedSeekBar extends StatefulWidget {
  const SharedSeekBar({
    super.key,
    required this.controller,
    required this.onPreviewChanged,
    required this.onInteractionChanged,
  });

  final PlayerController controller;
  final ValueChanged<Duration?> onPreviewChanged;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<SharedSeekBar> createState() => SharedSeekBarState();
}

class SharedSeekBarState extends State<SharedSeekBar> {
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
  MediaThumbnail? _entryThumbnail;
  String? _thumbnailEntryId;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    widget.controller.seekPreview.stateListenable.addListener(
      _handlePreviewStateChanged,
    );
    widget.controller.chaptersListenable.addListener(
      _handlePreviewStateChanged,
    );
  }

  void _handlePreviewStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant SharedSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.seekPreview.stateListenable.removeListener(
        _handlePreviewStateChanged,
      );
      oldWidget.controller.chaptersListenable.removeListener(
        _handlePreviewStateChanged,
      );
      final hoverPosition = _pointerInside ? _hoverPositionMs : null;
      oldWidget.controller.seekPreview.onPointerExit();
      widget.controller.seekPreview.stateListenable.addListener(
        _handlePreviewStateChanged,
      );
      widget.controller.chaptersListenable.addListener(
        _handlePreviewStateChanged,
      );
      if (hoverPosition != null &&
          !widget.controller.isAudio &&
          widget.controller.hasMedia) {
        widget.controller.seekPreview.onPointerMove(
          Duration(milliseconds: hoverPosition.round()),
        );
      }
    }
  }

  void _updateThumbnail() {
    final current = widget.controller.current;
    if (_thumbnailEntryId != current?.id) {
      _thumbnailEntryId = current?.id;
      _entryThumbnail = current == null
          ? null
          : widget.controller.peekThumbnail(current);
    }
  }

  @override
  void dispose() {
    _keyboardSeekTimer?.cancel();
    widget.controller.seekPreview.stateListenable.removeListener(
      _handlePreviewStateChanged,
    );
    widget.controller.chaptersListenable.removeListener(
      _handlePreviewStateChanged,
    );
    widget.controller.seekPreview.onPointerExit();
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

    final trackX = localX.clamp(0.0, trackWidth).toDouble();
    final physicalRatio = trackX / trackWidth;
    final ratio = Directionality.of(context) == TextDirection.rtl
        ? 1 - physicalRatio
        : physicalRatio;
    final hoverMs = (ratio * durationMs).roundToDouble();
    final hoverTime = Duration(milliseconds: hoverMs.round());
    setState(() {
      _pointerInside = true;
      _hoverTrackX = trackX;
      _hoverPositionMs = hoverMs;
    });

    if (!widget.controller.isAudio && widget.controller.hasMedia) {
      widget.controller.seekPreview.onPointerMove(hoverTime);
    }
  }

  void _onPointerExit() {
    widget.controller.seekPreview.onPointerExit();
    setState(() {
      _pointerInside = false;
      _hoverPositionMs = null;
    });
  }

  static String? _chapterTitleAt(
    List<PlaybackChapter> chapters,
    Duration time,
  ) {
    var activeIndex = -1;
    for (var index = 0; index < chapters.length; index++) {
      if (chapters[index].start > time) break;
      activeIndex = index;
    }
    if (activeIndex < 0) return null;
    final chapter = chapters[activeIndex];
    final title = chapter.title.trim();
    return title.isNotEmpty ? title : 'Chapter ${activeIndex + 1}';
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
    final scrubTime = Duration(milliseconds: value.round());
    widget.onPreviewChanged(scrubTime);
    setState(() {
      _dragging = true;
      _keyboardSeeking = false;
      _scrubPositionMs = value;
      _hoverPositionMs = value;
      _hoverTrackX = _trackXForValue(value, width, durationMs);
    });
    if (!widget.controller.isAudio && widget.controller.hasMedia) {
      widget.controller.seekPreview.onPointerMove(scrubTime);
    }
  }

  void _onChanged(double value, double width, int durationMs) {
    final scrubTime = Duration(milliseconds: value.round());
    widget.onPreviewChanged(scrubTime);
    setState(() {
      _scrubPositionMs = value;
      _keyboardSeeking = !_dragging;
      _hoverPositionMs = value;
      _hoverTrackX = _trackXForValue(value, width, durationMs);
    });
    if (!widget.controller.isAudio && widget.controller.hasMedia) {
      widget.controller.seekPreview.onPointerMove(scrubTime);
    }
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
    widget.controller.seekPreview.onPointerExit();
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
    widget.controller.seekPreview.onPointerExit();
    widget.onPreviewChanged(null);
    if (mounted) setState(() => _scrubPositionMs = null);
  }

  Future<void> _commitSeek(double value) async {
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = null;
    widget.controller.seekPreview.onPointerExit();
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
    _updateThumbnail();
    final controller = widget.controller;
    final durationMs = controller.duration.inMilliseconds;
    final canSeek = durationMs > 0 && controller.isSeekable;
    final hasTimeline = durationMs > 0;
    final positionMs =
        (_scrubPositionMs ?? controller.displayPosition.inMilliseconds)
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
        final isAudio = controller.isAudio;
        final bubbleWidth = isAudio ? 144.0 : 160.0;
        final actualBubbleWidth = width > 0
            ? (bubbleWidth > width ? width : bubbleWidth)
            : bubbleWidth;
        final previewRatio = durationMs > 0
            ? (previewMs / durationMs).clamp(0.0, 1.0)
            : 0.0;
        final previewX = _dragging || _keyboardSeeking
            ? _trackXForValue(previewMs, width, durationMs)
            : _hoverTrackX;
        final bubbleLeft = (previewX - actualBubbleWidth / 2)
            .clamp(0.0, (width - actualBubbleWidth).clamp(0.0, width))
            .toDouble();
        final maxCaret = (actualBubbleWidth - 14.0) > 14.0
            ? (actualBubbleWidth - 14.0)
            : 14.0;
        final caretOffset = (previewX - bubbleLeft)
            .clamp(14.0, maxCaret)
            .toDouble();
        final showPreview =
            hasTimeline && (_pointerInside || _dragging || _keyboardSeeking);
        final thumbVisible =
            canSeek && (_pointerInside || _dragging || _focused);
        final chapters = controller.chaptersListenable.value;
        final chapterFractions = <double>[];
        if (hasTimeline) {
          for (final chapter in chapters) {
            final startMs = chapter.start.inMilliseconds;
            if (startMs <= 0 || startMs >= durationMs) continue;
            chapterFractions.add(startMs / durationMs);
          }
        }
        final previewChapterTitle = showPreview && chapters.isNotEmpty
            ? _chapterTitleAt(chapters, previewTime)
            : null;

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
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        inactiveTrackColor: context.palette.border,
                        disabledActiveTrackColor: context.palette.muted,
                        disabledInactiveTrackColor: context.palette.border,
                        overlayColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.16),
                        thumbColor: Theme.of(context).colorScheme.primary,
                        padding: EdgeInsets.zero,
                      ),
                      child: SliderOverlay(
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
                  ),
                  if (chapterFractions.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const ValueKey('seek-chapter-ticks'),
                          painter: _ChapterTickPainter(
                            fractions: chapterFractions,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.62),
                            textDirection: Directionality.of(context),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('seek-preview'),
                    left: bubbleLeft,
                    bottom: PlayerControlStyle.of(context).seekHitHeight + 8,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: AppMotion.duration(context, AppMotion.quick),
                        switchInCurve: AppMotion.enter,
                        switchOutCurve: AppMotion.exit,
                        transitionBuilder: (child, animation) {
                          if (AppMotion.reduce(context)) return child;
                          final curved = CurvedAnimation(
                            parent: animation,
                            curve: AppMotion.enter,
                            reverseCurve: AppMotion.exit,
                          );
                          return FadeTransition(
                            opacity: curved,
                            child: ScaleTransition(
                              scale: Tween<double>(
                                begin: 0.88,
                                end: 1.0,
                              ).animate(curved),
                              alignment: Alignment.bottomCenter,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.08),
                                  end: Offset.zero,
                                ).animate(curved),
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: showPreview
                            ? RepaintBoundary(
                                key: const ValueKey('seek-preview-content'),
                                child: _SeekPreview(
                                  label: previewLabel,
                                  width: actualBubbleWidth,
                                  caretOffset: caretOffset,
                                  previewRatio: previewRatio,
                                  previewTime: previewTime,
                                  currentPosition: controller.displayPosition,
                                  controller: controller,
                                  previewState: controller.seekPreview.state,
                                  thumbnail: _entryThumbnail,
                                  chapterTitle: previewChapterTitle,
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

/// Draws subtle chapter boundary marks over the seek track.
class _ChapterTickPainter extends CustomPainter {
  const _ChapterTickPainter({
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
  bool shouldRepaint(_ChapterTickPainter oldDelegate) =>
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

class _CaretPainter extends CustomPainter {
  const _CaretPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );

    final strokePath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0);
    canvas.drawPath(
      strokePath,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_CaretPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}

class _SeekPreview extends StatelessWidget {
  const _SeekPreview({
    required this.label,
    required this.width,
    required this.caretOffset,
    required this.previewRatio,
    required this.previewTime,
    required this.currentPosition,
    required this.controller,
    required this.previewState,
    required this.thumbnail,
    this.chapterTitle,
  });

  final String label;
  final double width;
  final double caretOffset;
  final double previewRatio;
  final Duration previewTime;
  final Duration currentPosition;
  final PlayerController controller;
  final SeekPreviewState? previewState;
  final MediaThumbnail? thumbnail;
  final String? chapterTitle;

  @override
  Widget build(BuildContext context) {
    final isAudio = controller.isAudio;
    final diff = previewTime - currentPosition;
    final isAhead = diff > Duration.zero;
    final absDiff = diff.abs();
    final diffText = absDiff >= const Duration(seconds: 1)
        ? '${isAhead ? '+' : '-'}${_PlayerControlsState._formatTime(absDiff)}'
        : '';
    final entry = controller.current;
    final title = entry?.title ?? controller.currentMetadata.title;

    final borderColor = context.palette.border.withValues(alpha: 0.85);

    final cardContent = isAudio
        ? _buildAudioContent(context, title, diffText, isAhead)
        : _buildVideoContent(context, title, diffText, isAhead);

    final clampedCaret = (caretOffset - 5).clamp(
      8.0,
      (width - 18.0) > 8.0 ? (width - 18.0) : 8.0,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.palette.card,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 14,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: cardContent,
        ),
        Transform.translate(
          offset: const Offset(0, -1),
          child: Padding(
            padding: EdgeInsets.only(left: clampedCaret),
            child: CustomPaint(
              size: const Size(10, 5),
              painter: _CaretPainter(
                color: context.palette.card,
                borderColor: borderColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoContent(
    BuildContext context,
    String? title,
    String diffText,
    bool isAhead,
  ) {
    final frameHeight = ((width - 2) * 9 / 16).clamp(54.0, 96.0);
    final frame = previewState?.currentFrame;
    final isFailed = previewState?.status == SeekPreviewStatus.failed;
    final isLoading = previewState?.status == SeekPreviewStatus.loading;
    final isUpdating = previewState?.isUpdating == true;
    final showLoadingIndicator = isUpdating || (isLoading && frame == null);

    Widget imageSurface;
    if (frame != null && frame.bytes.isNotEmpty) {
      imageSurface = ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.control),
        ),
        child: Image.memory(
          frame.bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              const _PreviewPlaceholderFrame(),
        ),
      );
    } else if (isFailed) {
      imageSurface = const ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.control),
        ),
        child: _PreviewUnavailableFrame(),
      );
    } else if (thumbnail != null && thumbnail!.bytes.isNotEmpty) {
      imageSurface = ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.control),
        ),
        child: Image.memory(
          thumbnail!.bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              const _PreviewPlaceholderFrame(),
        ),
      );
    } else {
      imageSurface = const ClipRRect(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.control),
        ),
        child: _PreviewPlaceholderFrame(),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: frameHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              imageSurface,
              if (isFailed && frame != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.68),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.hide_image_outlined,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Preview unavailable',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (showLoadingIndicator)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 2.5,
                  color: Colors.black.withValues(alpha: 0.5),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: previewRatio,
                      child: Container(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: 5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.text,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (diffText.isNotEmpty)
                    Text(
                      diffText,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isAhead
                            ? Theme.of(context).colorScheme.primary
                            : context.palette.muted,
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
              if (chapterTitle case final title? when title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAudioContent(
    BuildContext context,
    String? title,
    String diffText,
    bool isAhead,
  ) {
    final bytes = thumbnail?.bytes;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: context.palette.surface,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: context.palette.border),
            ),
            child: (bytes != null && bytes.isNotEmpty)
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.music_note_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  )
                : Icon(
                    Icons.music_note_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title.trim().isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.palette.text,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (diffText.isNotEmpty)
                      Text(
                        diffText,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isAhead
                              ? Theme.of(context).colorScheme.primary
                              : context.palette.muted,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
                if (chapterTitle case final chapter? when chapter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.palette.secondaryText,
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewPlaceholderFrame extends StatelessWidget {
  const _PreviewPlaceholderFrame();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [context.palette.surface, context.palette.card],
      ),
    ),
    child: Center(
      child: Icon(
        Icons.play_circle_fill_rounded,
        size: 26,
        color: context.palette.secondaryText.withValues(alpha: 0.35),
      ),
    ),
  );
}

class _PreviewUnavailableFrame extends StatelessWidget {
  const _PreviewUnavailableFrame();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [context.palette.surface, context.palette.card],
      ),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_off_rounded,
            size: 20,
            color: context.palette.secondaryText.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 4),
          Text(
            'Preview unavailable',
            style: TextStyle(
              color: context.palette.secondaryText.withValues(alpha: 0.7),
              fontSize: AppType.caption,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Previous, play/pause and next controls used by both shell and overlay.
class TransportButtons extends StatelessWidget {
  const TransportButtons({
    super.key,
    required this.controller,
    this.compact = false,
  });

  /// Width of the control row, measured from the same extents the buttons are
  /// built with so surrounding layout can reserve the right amount of space.
  static double preferredWidth({required bool compact}) {
    final extent = compact
        ? PlayerControlStyle.compactControlExtent
        : PlayerControlStyle.controlExtent;
    final gap = compact ? 2.0 : 4.0;
    return 4 * extent + 3 * gap;
  }

  /// Shift that puts the play/pause button on the row's center line.
  ///
  /// Three secondary buttons flank the play button, so the row's midpoint
  /// falls between the play and next buttons. Nudging the row by half that
  /// difference centers the play button — the anchor of the control band —
  /// instead of the gap between two buttons.
  static double playButtonCenterOffset({required bool compact}) {
    final extent = compact
        ? PlayerControlStyle.compactControlExtent
        : PlayerControlStyle.controlExtent;
    final gap = compact ? 2.0 : 4.0;
    return preferredWidth(compact: compact) / 2 - (extent + gap + extent / 2);
  }

  final PlayerController controller;
  final bool compact;
  @override
  Widget build(BuildContext context) => PlayerControlStyle(
    compact: compact,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TransportButton(
          tooltip: 'Previous',
          icon: Icons.skip_previous_rounded,
          onPressed: controller.current == null ? null : controller.previous,
        ),
        SizedBox(width: compact ? 2 : 4),
        _PlayPauseButton(
          isPlaying: controller.isPlaying,
          isBuffering: controller.isBuffering,
          onPressed: controller.current == null
              ? null
              : controller.togglePlayPause,
        ),
        SizedBox(width: compact ? 2 : 4),
        _TransportButton(
          tooltip: 'Next',
          icon: Icons.skip_next_rounded,
          onPressed: controller.current == null ? null : controller.next,
        ),
        SizedBox(width: compact ? 2 : 4),
        _TransportButton(
          tooltip: 'Stop',
          icon: Icons.stop_rounded,
          onPressed: controller.current == null ? null : controller.stop,
        ),
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
            style: style.buttonStyle,
            icon: Icon(widget.icon, size: style.compact ? 18 : 22),
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
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
  final VoidCallback? onPressed;

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
  bool _pressed = false;

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
                  duration: AppMotion.duration(context, AppMotion.quick),
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  transitionBuilder: (child, animation) {
                    if (AppMotion.reduce(context)) return child;
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: widget.isBuffering
                      ? Center(
                          key: ValueKey('playback-buffering'),
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
                            key: ValueKey<bool>(widget.isPlaying),
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
      return AlertDialog(
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
