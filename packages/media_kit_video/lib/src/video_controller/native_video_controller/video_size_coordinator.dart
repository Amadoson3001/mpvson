import 'dart:async';

typedef ApplyVideoSizeCallback = Future<void> Function(int? width, int? height);

/// Serializes video output resize requests and coalesces pending updates.
///
/// Tracks desired override/source dimensions separately from the last
/// native-acknowledged dimensions so rapid A -> B -> A transitions never skip
/// the final size and disposed controllers discard stale completions.
class VideoSizeCoordinator {
  VideoSizeCoordinator({
    required ApplyVideoSizeCallback applyNative,
    int? initialWidth,
    int? initialHeight,
  })  : _applyNative = applyNative,
        _overrideWidth = initialWidth,
        _overrideHeight = initialHeight,
        _hasDesired = initialWidth != null && initialHeight != null;

  final ApplyVideoSizeCallback _applyNative;

  int? _overrideWidth;
  int? _overrideHeight;
  int? _sourceWidth;
  int? _sourceHeight;
  bool _hasDesired;

  int? _appliedEffectiveWidth;
  int? _appliedEffectiveHeight;
  bool _hasApplied = false;

  bool _draining = false;
  bool _disposed = false;
  Completer<void>? _drainCompleter;

  int? get overrideWidth => _overrideWidth;
  int? get overrideHeight => _overrideHeight;
  int? get sourceWidth => _sourceWidth;
  int? get sourceHeight => _sourceHeight;
  int? get appliedWidth => _appliedEffectiveWidth;
  int? get appliedHeight => _appliedEffectiveHeight;
  bool get isDisposed => _disposed;

  int? get _effectiveDesiredWidth =>
      (_overrideWidth != null && _overrideHeight != null)
          ? _overrideWidth
          : _sourceWidth;

  int? get _effectiveDesiredHeight =>
      (_overrideWidth != null && _overrideHeight != null)
          ? _overrideHeight
          : _sourceHeight;

  /// Requests a fixed output size or clears the override when either is null.
  Future<void> setSize({int? width, int? height}) {
    if (_disposed) return Future<void>.value();
    if (width != null && height != null) {
      _overrideWidth = width;
      _overrideHeight = height;
    } else {
      _overrideWidth = null;
      _overrideHeight = null;
    }
    _hasDesired = true;
    if (!_draining &&
        _hasApplied &&
        _appliedEffectiveWidth == _effectiveDesiredWidth &&
        _appliedEffectiveHeight == _effectiveDesiredHeight) {
      return Future<void>.value();
    }
    return _ensureDraining();
  }

  /// Updates the latest source dimensions from `videoParams`.
  Future<void> updateSourceDimensions(int width, int height) {
    if (_disposed) return Future<void>.value();
    if (_sourceWidth == width && _sourceHeight == height) {
      return Future<void>.value();
    }
    _sourceWidth = width;
    _sourceHeight = height;
    if (_overrideWidth != null && _overrideHeight != null) {
      return Future<void>.value();
    }
    _hasDesired = true;
    if (!_draining &&
        _hasApplied &&
        _appliedEffectiveWidth == _effectiveDesiredWidth &&
        _appliedEffectiveHeight == _effectiveDesiredHeight) {
      return Future<void>.value();
    }
    return _ensureDraining();
  }

  Future<void> _ensureDraining() {
    if (_draining && _drainCompleter != null) {
      return _drainCompleter!.future;
    }
    _draining = true;
    final completer = Completer<void>();
    _drainCompleter = completer;
    unawaited(_drainLoop(completer));
    return completer.future;
  }

  Future<void> _drainLoop(Completer<void> completer) async {
    try {
      while (!_disposed && _hasDesired) {
        final targetWidth = _effectiveDesiredWidth;
        final targetHeight = _effectiveDesiredHeight;
        if (_hasApplied &&
            _appliedEffectiveWidth == targetWidth &&
            _appliedEffectiveHeight == targetHeight) {
          break;
        }
        await _applyNative(targetWidth, targetHeight);
        if (_disposed) {
          break;
        }
        _appliedEffectiveWidth = targetWidth;
        _appliedEffectiveHeight = targetHeight;
        _hasApplied = true;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    } catch (error, stackTrace) {
      if (_disposed) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      } else if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      _draining = false;
      if (identical(_drainCompleter, completer)) {
        _drainCompleter = null;
      }
    }
  }

  void dispose() {
    _disposed = true;
    final completer = _drainCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}
