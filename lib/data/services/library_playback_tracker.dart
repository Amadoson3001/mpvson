import 'dart:async';

import '../../ui/player/player_controller.dart';
import '../repositories/media_library_repository.dart';
import 'diagnostic_log.dart';

/// Records a library item once it has played for a meaningful amount of time.
class LibraryPlaybackTracker {
  LibraryPlaybackTracker({required this.controller, required this.repository}) {
    controller.structureListenable.addListener(_onStateChanged);
    controller.transportListenable.addListener(_onStateChanged);
    repository.addListener(_onStateChanged);
    _onStateChanged();
  }

  final PlayerController controller;
  final MediaLibraryRepository repository;
  String? _entryId;
  bool _recorded = false;
  bool _wasLoaded = false;
  bool _disposed = false;
  Timer? _poll;

  void _onStateChanged() {
    _syncPoll();
    _update();
  }

  void _syncPoll() {
    if (_disposed) return;
    final playing = controller.isPlaying && controller.hasMedia && !_recorded;
    if (playing) {
      _poll ??= Timer.periodic(const Duration(seconds: 2), (_) => _update());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _update() {
    if (_disposed) return;
    final entry = controller.current;
    if (entry?.id != _entryId) {
      _entryId = entry?.id;
      _recorded = false;
      _wasLoaded = false;
    }
    if (_wasLoaded && !controller.hasMedia) _recorded = false;
    _wasLoaded = controller.hasMedia;
    if (entry == null ||
        _recorded ||
        !repository.isReady ||
        !controller.hasMedia ||
        !controller.isPlaying) {
      return;
    }
    final duration = controller.duration;
    final threshold =
        duration > Duration.zero && duration < const Duration(minutes: 1)
        ? Duration(milliseconds: duration.inMilliseconds ~/ 2)
        : const Duration(seconds: 30);
    if (controller.position < threshold) return;
    _recorded = true;
    unawaited(
      repository.recordPlayback(entry.path).catchError((Object error) {
        diagnosticDebug('library.recordPlayback', error: error);
      }),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    controller.structureListenable.removeListener(_onStateChanged);
    controller.transportListenable.removeListener(_onStateChanged);
    repository.removeListener(_onStateChanged);
  }
}
