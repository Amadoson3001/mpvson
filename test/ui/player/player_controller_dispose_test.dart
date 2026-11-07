import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_thumbnail.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/app_harness.dart';

class _RecordingThumbnails implements ThumbnailService {
  int disposeCount = 0;

  @override
  Future<MediaThumbnail?> load(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) async => null;

  @override
  void suspend() {}

  @override
  void resume() {}

  @override
  void trimMemory() {}

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

void main() {
  test(
    'controller.dispose releases the native thumbnail extractor even without a close',
    () async {
      final thumbnails = _RecordingThumbnails();
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: SessionRepository(),
        thumbnails: thumbnails,
      );

      // Direct dispose (no closePlayer): the extractor used to leak.
      controller.dispose();
      // Let the unawaited teardown chain run its first steps.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(thumbnails.disposeCount, 1);
    },
  );
}
