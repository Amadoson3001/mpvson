import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Policy governing video output presentation and sizing.
@immutable
class VideoOutputPolicy {
  const VideoOutputPolicy({
    this.visible = true,
    this.physicalWidth,
    this.physicalHeight,
    this.deferResize = false,
  });

  /// Whether video frames should be presented.
  ///
  /// When `false` (e.g. while minimized), video presentation is suspended
  /// and frames are acknowledged using mpv's skip-rendering mechanism without
  /// updating textures, while audio continues playing uninterrupted.
  final bool visible;

  /// Physical video viewport width in pixels.
  final int? physicalWidth;

  /// Physical video viewport height in pixels.
  final int? physicalHeight;

  /// Holds native surface reallocation while an active UI layout transition
  /// (such as sliding the queue or docking the stage) is in flight.
  final bool deferResize;

  /// Maximum rendered texture edge when upscaling to fit the viewport.
  static const int _maxUpscaledWidth = 3840;
  static const int _maxUpscaledHeight = 2160;

  /// Fits mpv's display-corrected dimensions inside the physical viewport.
  ///
  /// Allows mpv's GPU scalers (and libass subtitle rendering) to render at the
  /// native physical viewport resolution up to 4K instead of locking to source
  /// resolution, and snaps each edge to an even pixel count so D3D/YUV
  /// surfaces do not recreate on odd-pixel jitter.
  ({int width, int height})? fitVideo({
    required int? width,
    required int? height,
  }) {
    final viewportWidth = physicalWidth;
    final viewportHeight = physicalHeight;
    if (width == null ||
        height == null ||
        width <= 0 ||
        height <= 0 ||
        viewportWidth == null ||
        viewportHeight == null ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      return null;
    }
    final cappedWidth = math.min(
      viewportWidth,
      math.max(width, _maxUpscaledWidth),
    );
    final cappedHeight = math.min(
      viewportHeight,
      math.max(height, _maxUpscaledHeight),
    );
    final scale = math.min(cappedWidth / width, cappedHeight / height);
    return (
      width: _evenPixelSize((width * scale).round()),
      height: _evenPixelSize((height * scale).round()),
    );
  }

  /// True when the fitted size moved enough to recreate GPU surfaces.
  ///
  /// One-pixel LayoutBuilder jitter and even-pixel rounding stay on the
  /// current texture; larger viewport changes reallocate so mpv renders at
  /// native physical resolution.
  static bool significantSizeChange({
    required int? previousWidth,
    required int? previousHeight,
    required int width,
    required int height,
    int slack = 2,
  }) {
    if (previousWidth == null || previousHeight == null) return true;
    return (width - previousWidth).abs() >= slack ||
        (height - previousHeight).abs() >= slack;
  }

  VideoOutputPolicy copyWith({
    bool? visible,
    int? physicalWidth,
    int? physicalHeight,
    bool? deferResize,
  }) {
    return VideoOutputPolicy(
      visible: visible ?? this.visible,
      physicalWidth: physicalWidth ?? this.physicalWidth,
      physicalHeight: physicalHeight ?? this.physicalHeight,
      deferResize: deferResize ?? this.deferResize,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoOutputPolicy &&
          runtimeType == other.runtimeType &&
          visible == other.visible &&
          physicalWidth == other.physicalWidth &&
          physicalHeight == other.physicalHeight &&
          deferResize == other.deferResize;

  @override
  int get hashCode =>
      Object.hash(visible, physicalWidth, physicalHeight, deferResize);

  @override
  String toString() =>
      'VideoOutputPolicy(visible: $visible, physicalWidth: $physicalWidth, physicalHeight: $physicalHeight, deferResize: $deferResize)';
}

int _evenPixelSize(int value) {
  if (value <= 2) return math.max(1, value);
  return value & ~1;
}
