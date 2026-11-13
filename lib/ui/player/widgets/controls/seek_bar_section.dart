import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../domain/models/media_thumbnail.dart';
import '../../../../domain/models/playback_chapter.dart';
import '../../../../domain/models/player_controls_preferences.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../ui/core/components/player_slider_theme.dart';
import '../../../../ui/core/slider_overlay.dart';
import '../../../../utils/format.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';
import 'seek_bar_track_shape.dart';
import 'seek_preview.dart';
import 'seek_preview_layer.dart';

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
    this.thickness = SeekBarThickness.standard,
  });

  final PlayerController controller;
  final ValueChanged<Duration?> onPreviewChanged;
  final ValueChanged<bool>? onInteractionChanged;
  final SeekBarThickness thickness;

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
  double _lastBubbleLeft = 0;
  MediaThumbnail? _entryThumbnail;
  String? _thumbnailEntryId;
  List<PlaybackChapter>? _cachedChapters;
  int _cachedChaptersDurationMs = -1;
  List<double> _cachedChapterFractions = const <double>[];

  List<double> _chapterFractionsFor(
    List<PlaybackChapter> chapters,
    int durationMs,
  ) {
    if (durationMs <= 0 || chapters.isEmpty) {
      return const <double>[];
    }
    if (identical(chapters, _cachedChapters) &&
        durationMs == _cachedChaptersDurationMs) {
      return _cachedChapterFractions;
    }
    final fractions = <double>[];
    for (final chapter in chapters) {
      final startMs = chapter.start.inMilliseconds;
      if (startMs <= 0 || startMs >= durationMs) continue;
      fractions.add(startMs / durationMs);
    }
    _cachedChapters = chapters;
    _cachedChaptersDurationMs = durationMs;
    _cachedChapterFractions = List<double>.unmodifiable(fractions);
    return _cachedChapterFractions;
  }

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
        final showPreview =
            hasTimeline && (_pointerInside || _dragging || _keyboardSeeking);
        final thumbVisible =
            canSeek && (_pointerInside || _dragging || _focused);
        final chapters = controller.chaptersListenable.value;
        final chapterFractions = hasTimeline
            ? _chapterFractionsFor(chapters, durationMs)
            : const <double>[];

        var bubbleLeft = _lastBubbleLeft;
        final compact = PlayerControlStyle.of(context).compact;
        final preferredWidth = SeekPreviewMetrics.bubbleWidth(
          compact: compact,
          audio: controller.isAudio,
        );
        var actualBubbleWidth = width > 0 && preferredWidth > width
            ? width
            : preferredWidth;
        var previewLabel = '';
        var caretOffset = 0.0;
        var previewTime = Duration.zero;
        String? previewChapterTitle;

        if (showPreview) {
          final previewMs = _dragging || _keyboardSeeking
              ? (_scrubPositionMs ?? positionMs)
              : (_hoverPositionMs ?? positionMs);
          previewTime = Duration(milliseconds: previewMs.round());
          previewLabel = formatTime(previewTime);
          final previewX = _dragging || _keyboardSeeking
              ? _trackXForValue(previewMs, width, durationMs)
              : _hoverTrackX;
          bubbleLeft = (previewX - actualBubbleWidth / 2)
              .clamp(0.0, (width - actualBubbleWidth).clamp(0.0, width))
              .toDouble();
          _lastBubbleLeft = bubbleLeft;
          final maxCaret = (actualBubbleWidth - 14.0) > 14.0
              ? (actualBubbleWidth - 14.0)
              : 14.0;
          caretOffset = (previewX - bubbleLeft)
              .clamp(14.0, maxCaret)
              .toDouble();
          previewChapterTitle = chapters.isNotEmpty
              ? _chapterTitleAt(chapters, previewTime)
              : null;
        }

        final track = Listener(
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
                      data:
                          PlayerSliderTheme.seek(
                            context,
                            trackHeight:
                                (_pointerInside || _dragging || _focused)
                                ? widget.thickness.hoverHeight
                                : widget.thickness.restingHeight,
                            trackShape: const UniformRoundedSliderTrackShape(),
                            thumbShape: canSeek
                                ? RoundSliderThumbShape(
                                    enabledThumbRadius: thumbVisible
                                        ? ((_pointerInside ||
                                                  _dragging ||
                                                  _focused)
                                              ? widget
                                                    .thickness
                                                    .hoverThumbRadius
                                              : widget
                                                    .thickness
                                                    .restingThumbRadius)
                                        : 0,
                                    disabledThumbRadius: 3,
                                    elevation: 2,
                                    pressedElevation: 4,
                                  )
                                : SliderComponentShape.noThumb,
                          ).copyWith(
                            disabledActiveTrackColor: context.palette.muted,
                            disabledInactiveTrackColor: context.palette.border,
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
                ],
              ),
            ),
          ),
        );

        return SeekPreviewLayer(
          left: bubbleLeft,
          lift: SeekPreviewMetrics.gap(compact: compact),
          visible: showPreview,
          preview: RepaintBoundary(
            key: const ValueKey('seek-preview-content'),
            child: SeekPreview(
              label: previewLabel,
              width: actualBubbleWidth,
              caretOffset: caretOffset,
              previewTime: previewTime,
              currentPosition: controller.displayPosition,
              controller: controller,
              previewState: controller.seekPreview.state,
              thumbnail: _entryThumbnail,
              chapterTitle: previewChapterTitle,
              compact: compact,
            ),
          ),
          child: track,
        );
      },
    );
  }
}
