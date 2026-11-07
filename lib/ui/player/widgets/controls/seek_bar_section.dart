import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../domain/models/media_thumbnail.dart';
import '../../../../domain/models/playback_chapter.dart';
import '../../../../ui/core/app_motion.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../ui/core/slider_overlay.dart';
import '../../../../utils/format.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';
import 'seek_bar_track_shape.dart';
import 'seek_preview.dart';

void _notifyInteractionOnDispose(ValueChanged<bool>? callback) {
  if (callback == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => callback(false));
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
        final previewLabel = formatTime(previewTime);
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
                        trackHeight: 4,
                        trackShape: const UniformRoundedSliderTrackShape(),
                        trackGap: 0,
                        thumbShape: canSeek
                            ? RoundSliderThumbShape(
                                enabledThumbRadius: thumbVisible ? 7 : 5,
                                disabledThumbRadius: 3,
                                elevation: 2,
                                pressedElevation: 4,
                              )
                            : SliderComponentShape.noThumb,
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        inactiveTrackColor: context.palette.borderStrong
                            .withValues(alpha: 0.65),
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
                              ? (v) => _onChangeStart(v, width, durationMs)
                              : null,
                          onChanged: canSeek
                              ? (v) => _onChanged(v, width, durationMs)
                              : null,
                          onChangeEnd: canSeek ? _onChangeEnd : null,
                          padding: EdgeInsets.zero,
                          semanticFormatterCallback: (value) =>
                              'Seek to ${formatTime(Duration(milliseconds: value.round()))}',
                        ),
                      ),
                    ),
                  ),
                  if (chapterFractions.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const ValueKey('seek-chapter-ticks'),
                          painter: ChapterTickPainter(
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
                          // CurveTween keeps this transient: no
                          // CurvedAnimation to outlive the switcher.
                          final curved = animation.drive(
                            CurveTween(curve: AppMotion.enter),
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
                                child: SeekPreview(
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
