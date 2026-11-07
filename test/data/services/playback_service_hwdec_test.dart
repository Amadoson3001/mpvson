import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/diagnostic_log.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/graphics_settings.dart';

/// Engine stand-in so the service can be built without libmpv.
class _RecordingEnginePlayer extends PlatformPlayer {
  _RecordingEnginePlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<void> open(Playable playable, {bool play = true}) async {}

  @override
  Future<void> stop({bool open = false, bool notify = true}) async {}
}

void main() {
  testWidgets(
    'a hwdec readback disagreement is surfaced through the diagnostics stream',
    (tester) async {
      final diagnostics = MemoryDiagnosticLog();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: _RecordingEnginePlayer()),
        diagnostics: diagnostics,
        propertyWriterForTesting: (_, _) async {},
        // The engine reports a software decoder although a hardware one was
        // requested: the fallback must be visible in the diagnostics log.
        propertyReaderForTesting: (_) async => 'no',
      );
      addTearDown(service.dispose);

      service.applyGraphicsSettings(
        const GraphicsSettings(videoMemoryMode: VideoMemoryMode.ramStaged),
      );
      await tester.pump(const Duration(milliseconds: 10));

      final log = diagnostics.records.join('\n');
      expect(log, contains('playback.hwdec'));
      expect(log, contains('instead of'));
    },
  );

  testWidgets(
    'a failed hwdec runtime write is surfaced through the diagnostics stream',
    (tester) async {
      final diagnostics = MemoryDiagnosticLog();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: _RecordingEnginePlayer()),
        diagnostics: diagnostics,
        propertyWriterForTesting: (_, _) =>
            Future<void>.error(StateError('engine gone')),
        propertyReaderForTesting: (_) async => 'auto',
      );
      addTearDown(service.dispose);

      service.applyGraphicsSettings(
        const GraphicsSettings(videoMemoryMode: VideoMemoryMode.ramStaged),
      );
      await tester.pump(const Duration(milliseconds: 10));

      final log = diagnostics.records.join('\n');
      expect(log, contains('playback.hwdec'));
      expect(log, contains('runtime write failed'));
    },
  );
}
