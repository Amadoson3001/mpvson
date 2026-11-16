import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/home_view.dart';
import 'package:mpvson/ui/library/views/music_view.dart';
import 'package:mpvson/ui/library/views/playlists_view.dart';
import 'package:mpvson/ui/library/views/videos_view.dart';
import 'package:mpvson/ui/library/widgets/library_item_action_menu.dart';
import 'package:mpvson/ui/library/widgets/media_context_menu.dart';
import 'package:mpvson/ui/library/widgets/library_item_actions.dart';
import 'package:mpvson/ui/library/widgets/media_properties_dialog.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/empty_library.dart';
import 'package:mpvson/ui/player/widgets/queue_panel.dart';
import '../../support/library_view_fixtures.dart';

void main() {
  late Directory tempDir;
  late File videoFileA;
  late File videoFileB;
  late File audioFileA;
  late FakePlaybackService playback;
  late SessionRepository sessions;
  late PlayerController controller;
  late FakeMediaLibraryRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson_ctx_menu_test_');
    videoFileA = await File(
      '${tempDir.path}${Platform.pathSeparator}sample_a.mp4',
    ).writeAsBytes(const <int>[0, 1, 2, 3]);
    videoFileB = await File(
      '${tempDir.path}${Platform.pathSeparator}sample_b.mp4',
    ).writeAsBytes(const <int>[4, 5, 6, 7]);
    audioFileA = await File(
      '${tempDir.path}${Platform.pathSeparator}track_a.mp3',
    ).writeAsBytes(const <int>[8, 9, 10, 11]);

    playback = FakePlaybackService();
    sessions = SessionRepository(directory: tempDir);
    controller = PlayerController(playback: playback, sessions: sessions);

    final playlistId = 'pl-1';
    final videoRecordA = makeLibraryRecord(
      id: 'vid-a',
      path: videoFileA.path,
      kind: MediaKind.video,
      title: 'Sample Video A',
    );
    final videoRecordB = makeLibraryRecord(
      id: 'vid-b',
      path: videoFileB.path,
      kind: MediaKind.video,
      title: 'Sample Video B',
    );
    final audioRecordA = makeLibraryRecord(
      id: 'aud-a',
      path: audioFileA.path,
      kind: MediaKind.audio,
      title: 'Sample Audio A',
    );

    repository = FakeMediaLibraryRepository(
      items: [videoRecordA, videoRecordB, audioRecordA],
      playlists: [
        PlaylistRecord(
          id: playlistId,
          title: 'Favorites Mix',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          entryCount: 1,
        ),
      ],
      playlistEntries: {
        playlistId: [
          PlaylistEntryRecord(
            id: 'entry-1',
            playlistId: playlistId,
            mediaId: audioRecordA.id,
            position: 0,
            addedAt: DateTime(2026, 1, 1),
            mediaItem: audioRecordA,
          ),
        ],
      },
    );
  });

  tearDown(() async {
    await controller.close(discard: true, force: true);
    await repository.dispose();
    await playback.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('MediaContextMenu & Properties', () {
    testWidgets(
      'Properties opens MediaPropertiesDialog even when AppToastHost mounts Overlay.wrap above Navigator',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
          duration: const Duration(minutes: 3, seconds: 15),
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            includeToastHost: true,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    unawaited(
                      showMediaContextMenu(
                        context: context,
                        globalPosition: const Offset(200, 200),
                        target: target,
                        repository: repository,
                        controller: controller,
                      ),
                    );
                  },
                  child: const Text('Open Menu'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Menu'));
        await tester.pumpAndSettle();

        expect(find.text('Properties'), findsOneWidget);
        await tester.tap(find.text('Properties'));
        await pumpAfterIo(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        expect(find.text('Sample Video A'), findsOneWidget);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaPropertiesDialog), findsNothing);
      },
    );

    testWidgets(
      'Properties and New playlist guard missing Navigator without throwing',
      (tester) async {
        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
        );

        // Overlay.wrap directly without any Navigator ancestor.
        await tester.pumpWidget(
          Theme(
            data: AppTheme.darkTheme(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay.wrap(
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () {
                      unawaited(
                        showMediaContextMenu(
                          context: context,
                          globalPosition: const Offset(100, 100),
                          target: target,
                          repository: repository,
                          controller: controller,
                        ),
                      );
                    },
                    child: const Text('Open Bare'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Bare'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Properties'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsNothing);
      },
    );

    testWidgets('Add to queue and Play next work without crashing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final targetA = LibraryItemTarget(
        id: 'vid-a',
        path: videoFileA.path,
        title: 'Sample Video A',
        kind: MediaKind.video,
      );
      final targetB = LibraryItemTarget(
        id: 'vid-b',
        path: videoFileB.path,
        title: 'Sample Video B',
        kind: MediaKind.video,
      );
      final targetAudio = LibraryItemTarget(
        id: 'aud-a',
        path: audioFileA.path,
        title: 'Sample Audio A',
        kind: MediaKind.audio,
      );

      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: Row(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetA,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu A'),
                      ),
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetB,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu B'),
                      ),
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetAudio,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu Audio'),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 320,
                child: QueuePanel(
                  controller: controller,
                  onClose: () {},
                  onQueueFocus: (_) {},
                  onAddFiles: () {},
                ),
              ),
            ],
          ),
        ),
      );

      // 1) Add to queue when queue is initially empty.
      await tester.tap(find.text('Menu A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to queue'));
      await pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [videoFileA.path]);
      expect(find.textContaining('Added to queue:'), findsOneWidget);

      // 2) Add to queue when queue already has an active item.
      await tester.tap(find.text('Menu B'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Add to queue'));
      await pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [
        videoFileA.path,
        videoFileB.path,
      ]);

      // 3) Play next inserts right after currentIndex (0 -> index 1).
      await tester.tap(find.text('Menu Audio'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Play next'));
      await pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [
        videoFileA.path,
        audioFileA.path,
        videoFileB.path,
      ]);
      expect(find.textContaining('Playing next:'), findsOneWidget);

      // 4) Force session save with isolate serialization to verify snapshot immutability.
      await tester.runAsync(() => controller.saveSession());
      await tester.runAsync(() => controller.close(discard: true, force: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Open in File Explorer passes missing local path directly and supports F3',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}deleted_item.mp4';
        final revealedPaths = <String>[];
        final missingTarget = LibraryItemTarget(
          id: 'vid-missing',
          path: missingPath,
          title: 'Deleted Item',
          kind: MediaKind.video,
          isAvailable: false,
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => unawaited(
                    showMediaContextMenu(
                      context: context,
                      globalPosition: const Offset(150, 150),
                      target: missingTarget,
                      repository: repository,
                      controller: controller,
                      onShowInFolder: revealedPaths.add,
                    ),
                  ),
                  child: const Text('Open Missing Menu'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Missing Menu'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open in File Explorer'));
        await tester.pumpAndSettle();
        expect(revealedPaths, [missingPath]);

        // Re-open menu and trigger via F3 keyboard shortcut.
        await tester.tap(find.text('Open Missing Menu'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.f3);
        await tester.pumpAndSettle();
        expect(revealedPaths, [missingPath, missingPath]);
      },
    );

    testWidgets(
      'Play, Add to playlist (existing & New playlist...), Remove, and Select work',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var played = false;
        var removed = false;
        var selected = false;

        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => unawaited(
                    showMediaContextMenu(
                      context: context,
                      globalPosition: const Offset(180, 180),
                      target: target,
                      repository: repository,
                      controller: controller,
                      onPlay: () => played = true,
                      onRemove: () => removed = true,
                      onSelect: () => selected = true,
                    ),
                  ),
                  child: const Text('Trigger'),
                ),
              ),
            ),
          ),
        );

        // Play
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();
        expect(played, isTrue);

        // Remove
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(removed, isTrue);

        // Select
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        expect(selected, isTrue);

        // Add to existing playlist via submenu
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist'));
        await tester.pumpAndSettle();
        expect(find.text('Favorites Mix'), findsOneWidget);
        await tester.tap(find.text('Favorites Mix'));
        await tester.pumpAndSettle();
        expect(repository.addedPathsToPlaylists, hasLength(1));
        expect(repository.addedPathsToPlaylists.first.$1, 'pl-1');

        // Create new playlist via submenu inside AppToastHost
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New playlist...'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Weekend Watch');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(repository.addedPathsToPlaylists, hasLength(2));
        expect(
          repository.addedPathsToPlaylists.last.$2,
          equals([videoFileA.path]),
        );
      },
    );

    testWidgets(
      'LibraryItemActionMenu handles Add to queue, Play next, Open in File Explorer, and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final revealed = <String>[];
        final record = makeLibraryRecord(
          id: 'aud-a',
          path: audioFileA.path,
          kind: MediaKind.audio,
          title: 'Sample Audio A',
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: LibraryItemActionMenu(
                  item: record,
                  repository: repository,
                  controller: controller,
                  libraryContext: context,
                  onShowInFolder: revealed.add,
                ),
              ),
            ),
          ),
        );

        // Add to queue
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to queue'));
        await pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(controller.queue.map((e) => e.path), [audioFileA.path]);

        // Open in File Explorer
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open in File Explorer'));
        await tester.pumpAndSettle();
        expect(revealed, [audioFileA.path]);

        // Properties
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Properties'));
        await pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpAndSettle();
      },
    );
  });

  group('Right-click across library views & EmptyLibrary', () {
    testWidgets(
      'HomeView recent tile right-click opens context menu and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final recentEntry = MediaEntry.fromPath(
          videoFileA.path,
          id: 'rec-home-1',
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: HomeView(
              recent: [recentEntry],
              repository: repository,
              controller: controller,
              onOpenFiles: () {},
              onOpenUrl: () {},
              onOpenRecent: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final tile = find.text(recentEntry.title).first;
        await tester.tap(tile, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Properties'), findsOneWidget);
        await tester.tap(find.text('Properties'));
        await pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('VideosView right-click opens context menu and adds to queue', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: VideosView(repository: repository, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final itemTitle = find.text('Sample Video A').first;
      await tester.tap(itemTitle, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      expect(find.text('Add to queue'), findsOneWidget);
      await tester.tap(find.text('Add to queue'));
      await pumpAfterIo(tester);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [videoFileA.path]);
      await tester.runAsync(() => controller.close(discard: true, force: true));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'MusicView song row right-click opens context menu and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: MusicView(repository: repository, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final songTitle = find.text('Sample Audio A').first;
        await tester.tap(songTitle, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Add to queue'), findsOneWidget);
        expect(find.text('Properties'), findsOneWidget);

        await tester.tap(find.text('Properties'));
        await pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'PlaylistsView track row right-click opens context menu and adds to queue',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: PlaylistsView(repository: repository, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // Open the playlist detail view.
        await tester.tap(find.text('Favorites Mix'));
        await tester.pumpAndSettle();

        final trackTitle = find.text('Sample Audio A').first;
        await tester.tap(trackTitle, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Add to queue'), findsOneWidget);
        await tester.tap(find.text('Add to queue'));
        await pumpAfterIo(tester);

        expect(tester.takeException(), isNull);
        expect(controller.queue.map((e) => e.path), [audioFileA.path]);
        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets('EmptyLibrary recent tile right-click triggers menu actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var removedCalled = false;
      final recentEntry = MediaEntry.fromPath(
        videoFileA.path,
        id: 'rec-home-1',
      );

      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: EmptyLibrary(
            recent: [recentEntry],
            onOpenFiles: () {},
            onOpenUrl: () {},
            onOpenRecent: (_) {},
            onRemoveRecent: (_) => removedCalled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.text(recentEntry.title).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove from recently played'), findsOneWidget);
      await tester.tap(find.text('Remove from recently played'));
      await tester.pumpAndSettle();
      expect(removedCalled, isTrue);
    });
  });
}
