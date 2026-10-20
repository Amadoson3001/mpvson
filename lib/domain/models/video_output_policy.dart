import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Policy governing video output presentation and sizing.
@immutable
class VideoOutputPolicy {
  const VideoOutputPolicy({
    this.visible = true,
    this.physicalWidth,
    this.physicalHeight,
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

  /// Fits mpv's display-corrected dimensions inside the physical viewport.
  /// Never allocates an upscaled texture or rounds a narrow edge down to zero.
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
    final scale = math.min(
      1.0,
      math.min(viewportWidth / width, viewportHeight / height),
    );
    return (
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  VideoOutputPolicy copyWith({
    bool? visible,
    int? physicalWidth,
    int? physicalHeight,
  }) {
    return VideoOutputPolicy(
      visible: visible ?? this.visible,
      physicalWidth: physicalWidth ?? this.physicalWidth,
      physicalHeight: physicalHeight ?? this.physicalHeight,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoOutputPolicy &&
          runtimeType == other.runtimeType &&
          visible == other.visible &&
          physicalWidth == other.physicalWidth &&
          physicalHeight == other.physicalHeight;

  @override
  int get hashCode => Object.hash(visible, physicalWidth, physicalHeight);

  @override
  String toString() =>
      'VideoOutputPolicy(visible: $visible, physicalWidth: $physicalWidth, physicalHeight: $physicalHeight)';
}
