import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/controls/seek_bar_section.dart';
import 'package:mpvson/ui/player/widgets/controls/seek_preview.dart';

import '../../support/fake_playback_service.dart';

class _TrackingPreviewBackend implements SeekPreviewBackend {
  @override
  int? get liveTextureId => null;

  @override
  bool get supportsLiveTexture => false;

  @override
  Future<void> open(
    String source, {
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {}

  @override
  Future<void> seekLive(Duration target, {required bool exact}) async {}

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    return SeekPreviewFrame(
      bytes: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
      requestedTime: target,
      capturedTime: target,
      quality: SeekPreviewQuality.keyframe,
    );
  }

  @override
  void cancelExtraction() {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  int disposeCount = 0;

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

void main() {
  late Directory tempDir;
  late PlayerController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'mpvson_seek_preview_test_',
    );
    controller = PlayerController(
      playback: FakePlaybackService(),
      sessions: SessionRepository(
        directory: tempDir,
        encoder: (session) => jsonEncode(session.toJson()),
      ),
    );
  });

  tearDown(() async {
    await controller.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets(
    'local video preview never shows loading spinner and renders live Texture',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '01:23',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(minutes: 1, seconds: 23),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: false,
              liveTextureId: 12,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 12);
    },
  );

  testWidgets(
    'local video preview shows no spinner even before texture is ready',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '00:45',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(seconds: 45),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: false,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('00:45'), findsOneWidget);
    },
  );

  testWidgets(
    'remote video preview still shows loading indicator while loading',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '02:10',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(minutes: 2, seconds: 10),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: true,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  group('SharedSeekBar teardown', () {
    late Directory teardownDir;
    late _TrackingPreviewBackend backend;
    late SeekPreviewService preview;
    late PlayerController localController;

    setUp(() async {
      teardownDir = await Directory.systemTemp.createTemp(
        'mpvson_seekbar_teardown_',
      );
      backend = _TrackingPreviewBackend();
      preview = SeekPreviewService(backendFactory: () => backend);
      localController = PlayerController(
        playback: FakePlaybackService(),
        sessions: SessionRepository(directory: teardownDir),
        seekPreview: preview,
      );
    });

    tearDown(() async {
      localController.dispose();
      await preview.dispose();
      if (teardownDir.existsSync()) await teardownDir.delete(recursive: true);
    });

    testWidgets(
      'tearing down one seek-bar surface keeps another surface interaction',
      (tester) async {
        Widget twoBars({required bool includeFirst}) => MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Column(
              children: [
                if (includeFirst)
                  SizedBox(
                    key: const ValueKey<String>('first-slot'),
                    height: 120,
                    child: SharedSeekBar(
                      key: ValueKey<String>('first'),
                      controller: localController,
                      onPreviewChanged: (_) {},
                      onInteractionChanged: null,
                    ),
                  ),
                SizedBox(
                  key: const ValueKey<String>('second-slot'),
                  height: 120,
                  child: SharedSeekBar(
                    key: const ValueKey<String>('second'),
                    controller: localController,
                    onPreviewChanged: (_) {},
                    onInteractionChanged: null,
                  ),
                ),
              ],
            ),
          ),
        );

        await tester.pumpWidget(twoBars(includeFirst: true));
        final first = tester.state<SharedSeekBarState>(
          find.byKey(const ValueKey<String>('first')),
        );
        final second = tester.state<SharedSeekBarState>(
          find.byKey(const ValueKey<String>('second')),
        );

        await tester.runAsync(
          () => preview.setSource('https://example.com/live.m3u8'),
        );
        await tester.pump();

        preview.onPointerMove(const Duration(seconds: 5), owner: first);
        await tester.pump();
        // The second surface takes over the interaction from the first.
        preview.onPointerMove(const Duration(seconds: 7), owner: second);
        await tester.pump();
        expect(preview.hasActiveWorker, isTrue);

        // Removing the first surface runs its dispose(), which must not cancel
        // the interaction that the second surface now owns.
        await tester.pumpWidget(twoBars(includeFirst: false));
        await tester.pump();
        expect(backend.disposeCount, 0);
        expect(preview.state.targetTime, const Duration(seconds: 7));

        // The surviving surface still owns a live interaction.
        preview.onPointerMove(const Duration(seconds: 9), owner: second);
        await tester.pump();
        expect(preview.state.targetTime, const Duration(seconds: 9));

        // Disposing it releases the worker, with no pending idle timer.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
        expect(backend.disposeCount, 1);
      },
    );
  });
}
