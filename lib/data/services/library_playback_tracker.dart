import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ui/player/player_controller.dart';
import '../repositories/media_library_repository.dart';

/// Records a library item once it has played for a meaningful amount of time.
class LibraryPlaybackTracker {
  LibraryPlaybackTracker({required this.controller, required this.repository}) {
    controller.addListener(_update);
    controller.positionListenable.addListener(_update);
    repository.addListener(_update);
    _update();
  }

  final PlayerController controller;
  final MediaLibraryRepository repository;
  String? _entryId;
  bool _recorded = false;
  bool _wasLoaded = false;
  bool _disposed = false;

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
        if (kDebugMode) debugPrint('Could not record library playback: $error');
      }),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_update);
    controller.positionListenable.removeListener(_update);
    repository.removeListener(_update);
  }
}
