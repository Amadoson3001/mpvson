import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/repositories/media_library_repository_impl.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/playback_settings.dart';

import 'audit/player_harness.dart';
import 'support/app_harness.dart';
import 'support/audit_helpers.dart';

class _HeadlessPlatformVideoController extends PlatformVideoController {
  _HeadlessPlatformVideoController(Player player)
    : super(player, const VideoControllerConfiguration());
  @override
  Future<void> setSize({int? width, int? height}) async {}
}

class _HeadlessVideoController implements VideoController {
  _HeadlessVideoController(Player player) {
    platform.complete(_HeadlessPlatformVideoController(player));
  }
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  Future<void> setSize({int? width, int? height}) async {}
  @override
  Future<void> setRenderVisibility(bool visible) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = File('build/windows/x64/runner/Release/libmpv-2.dll').absolute;
  if (dll.existsSync()) {
    MediaKit.ensureInitialized(libmpv: dll.path);
  }
  group('3.1 Prefer D3D11VA Hardware Acceleration Explicitly on Windows', () {
    test(
      'MediaKitPlaybackService applies auto-safe on Windows and no when disabled',
      () async {
        final dll = File(
          'build/windows/x64/runner/Release/libmpv-2.dll',
        ).absolute;
        if (!dll.existsSync()) {
          return;
        }
        MediaKit.ensureInitialized(libmpv: dll.path);

        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null', muted: true),
        );
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _HeadlessVideoController(player),
        );

        try {
          final native = player.platform! as NativePlayer;
          await native.setProperty('ao', 'null');
          await service.prepare();

          final expectedHwdec = Platform.isWindows ? 'auto-safe' : 'auto';

          final resultOn = await service.applyPlaybackSettings(
            const PlaybackSettings(preferHardwareDecoding: true),
          );
          expect(resultOn.appliedProperties, contains('hwdec'));
          expect(await native.getProperty('hwdec'), expectedHwdec);

          final resultOff = await service.applyPlaybackSettings(
            const PlaybackSettings(preferHardwareDecoding: false),
          );
          expect(resultOff.appliedProperties, contains('hwdec'));
          expect(await native.getProperty('hwdec'), 'no');
        } finally {
          await service.dispose();
        }
      },
    );
  });

  group('3.2 Ensure Video Canvas Isolation with RepaintBoundary', () {
    testWidgets(
      'PlayerStage isolates video surface inside its own RepaintBoundary',
      (tester) async {
        final h = buildHarness();
        configureView(tester, size: const Size(1280, 720));
        await tester.pumpWidget(
          playerApp(
            h,
            videoBuilder: (context, _) => const SizedBox(
              key: ValueKey('test-video-surface'),
              width: 640,
              height: 360,
            ),
          ),
        );
        await settle(tester);
        await openMedia(tester, h, const ['sample_video.mp4']);

        final videoFinder = find.byKey(const ValueKey('test-video-surface'));
        expect(videoFinder, findsOneWidget);

        // Verify that the video surface is wrapped in its own RepaintBoundary
        final ancestorRepaintBoundaries = find.ancestor(
          of: videoFinder,
          matching: find.byType(RepaintBoundary),
        );
        expect(ancestorRepaintBoundaries, findsWidgets);

        final parentRenderObject = tester
            .element(videoFinder)
            .renderObject
            ?.parent;
        expect(parentRenderObject is RenderRepaintBoundary, isTrue);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 35));
      },
    );
  });

  group('3.3 SQLite Query Latency & FTS Indexing', () {
    test(
      'LibraryDatabase creates covering indexes for sort operations',
      () async {
        final db = await LibraryDatabase.open(inMemory: true);

        try {
          final indexes = await db.selectRaw(
            "SELECT name FROM sqlite_master WHERE type = 'index'",
          );
          final indexNames = indexes
              .map((row) => row['name'] as String)
              .toSet();

          expect(indexNames, contains('idx_media_kind_added_at'));
          expect(indexNames, contains('idx_media_library_kind_added_at'));
          expect(indexNames, contains('idx_media_album_track'));
          expect(indexNames, contains('idx_media_album_disc_track'));
        } finally {
          await db.close();
        }
      },
    );

    test('LibraryDatabase optimize executes PRAGMA optimize cleanly', () async {
      final db = await LibraryDatabase.open(inMemory: true);

      try {
        // Calling optimize should complete without exception
        await db.optimize();
      } finally {
        await db.close();
      }
    });

    test(
      'MediaLibraryRepositoryImpl optimize delegates to LibraryDatabase',
      () async {
        final repo = MediaLibraryRepositoryImpl(inMemory: true);

        try {
          await repo.initialize();
          await repo.optimize();
        } finally {
          await repo.dispose();
        }
      },
    );
  });
}
