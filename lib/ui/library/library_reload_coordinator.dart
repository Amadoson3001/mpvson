import 'dart:async';

import '../../utils/debouncer.dart';
import 'library_browse_constants.dart';

/// Coordinates coalesced scan-driven reloads and serialized reload execution
/// for library views.
///
/// Only one reload runs at a time; requests arriving mid-flight schedule a
/// rerun for the latest state and advance [epoch] so obsolete results or errors
/// after a search, sort, selection, or repository change are discarded.
class LibraryReloadCoordinator {
  LibraryReloadCoordinator({
    required this.onReload,
    this.onError,
    this.onLoadingChanged,
    this.isDisposed,
    Duration scanThrottle = kLibraryScanReloadThrottle,
  }) : _scanReload = Coalescer(delay: scanThrottle);

  final Future<void> Function(int epoch) onReload;
  final void Function(Object error)? onError;
  final void Function(bool loading)? onLoadingChanged;
  final bool Function()? isDisposed;
  final Coalescer _scanReload;

  Future<void>? _activeFuture;
  bool _reloadAgain = false;
  bool _disposed = false;
  bool _isLoading = false;
  int _epoch = 0;

  int get epoch => _epoch;
  bool get isLoading => _isLoading;

  bool get _canRun => !_disposed && !(isDisposed?.call() ?? false);

  /// Handles repository change notifications, coalescing during active scans
  /// and reloading immediately once scanning finishes.
  void onRepositoryChanged({required bool isScanning}) {
    if (!_canRun) return;
    if (isScanning) {
      _scanReload.schedule(() {
        if (_canRun) unawaited(reload());
      });
      return;
    }
    _scanReload.cancel();
    unawaited(reload());
  }

  /// Requests a reload, serializing concurrent requests and rerunning if a
  /// newer request arrives while a reload is in flight.
  Future<void> reload() {
    if (!_canRun) return Future<void>.value();
    _epoch++;
    _reloadAgain = true;
    final active = _activeFuture;
    if (active != null) return active;

    final future = _drain();
    final tracked = future.whenComplete(() {
      _activeFuture = null;
      if (_reloadAgain && _canRun) unawaited(reload());
    });
    _activeFuture = tracked;
    return tracked;
  }

  Future<void> _drain() async {
    _isLoading = true;
    onLoadingChanged?.call(true);
    var runEpoch = _epoch;
    try {
      do {
        runEpoch = ++_epoch;
        _reloadAgain = false;
        await onReload(runEpoch);
      } while (_reloadAgain && _canRun);
    } catch (error) {
      if (_canRun && !_reloadAgain && runEpoch == _epoch) {
        onError?.call(error);
      }
    } finally {
      _isLoading = false;
      onLoadingChanged?.call(false);
    }
  }

  void dispose() {
    _disposed = true;
    _epoch++;
    _reloadAgain = false;
    _scanReload.dispose();
  }
}
