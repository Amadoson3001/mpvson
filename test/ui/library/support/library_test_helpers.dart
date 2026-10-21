import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import '../../player/support/player_test_fakes.dart';

Future<PlayerController> createTestPlayerController({
  List<String> initialPaths = const [],
}) async {
  final playback = FakePlaybackService();
  final sessions = BlockingSessionRepository(
    blockDetailed: false,
    initialResult: const SessionLoadResult(),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  await controller.initialize();
  if (initialPaths.isNotEmpty) {
    await controller.openPaths(initialPaths);
  }
  return controller;
}

Future<void> disposeTestPlayerController(
  WidgetTester tester,
  PlayerController controller,
) async {
  if (controller.isPlaying) await controller.togglePlayPause();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => controller.close(discard: true));
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

InMemoryMediaLibraryRepository createTestMediaLibraryRepository() {
  final now = DateTime.now();
  final items = <MediaItemRecord>[
    MediaItemRecord(
      id: 'm1',
      canonicalSource: 'https://media.example/Track1.mp3',
      path: 'https://media.example/Track1.mp3',
      kind: MediaKind.audio,
      fileSize: 4500000,
      addedAt: now.subtract(const Duration(days: 2)),
      isFavorite: true,
      metadata: const MediaMetadata(
        title: 'Song Alpha',
        artist: 'Artist One',
        album: 'Album Great',
        discNumber: 1,
        trackNumber: 2,
        duration: Duration(minutes: 3, seconds: 30),
      ),
    ),
    MediaItemRecord(
      id: 'm2',
      canonicalSource: 'https://media.example/Track2.mp3',
      path: 'https://media.example/Track2.mp3',
      kind: MediaKind.audio,
      fileSize: 5200000,
      addedAt: now.subtract(const Duration(days: 1)),
      metadata: const MediaMetadata(
        title: 'Song Beta',
        artist: 'Artist One',
        album: 'Album Great',
        discNumber: 1,
        trackNumber: 1,
        duration: Duration(minutes: 4, seconds: 15),
      ),
    ),
    MediaItemRecord(
      id: 'm3',
      canonicalSource: 'https://media.example/Track3.mp3',
      path: 'https://media.example/Track3.mp3',
      kind: MediaKind.audio,
      fileSize: 3800000,
      addedAt: now.subtract(const Duration(days: 3)),
      metadata: const MediaMetadata(
        title: 'Song Gamma',
        artist: 'Artist Two',
        album: 'Solo Echoes',
        discNumber: 2,
        trackNumber: 1,
        duration: Duration(minutes: 2, seconds: 50),
      ),
    ),
    MediaItemRecord(
      id: 'v1',
      canonicalSource: 'https://media.example/Movie.mp4',
      path: 'https://media.example/Movie.mp4',
      kind: MediaKind.video,
      fileSize: 520000000,
      addedAt: now.subtract(const Duration(days: 4)),
      metadata: const MediaMetadata(
        title: 'Ocean Sunset',
        duration: Duration(minutes: 15, seconds: 40),
      ),
    ),
    MediaItemRecord(
      id: 'v2',
      canonicalSource: 'https://media.example/MissingClip.mkv',
      path: 'https://media.example/MissingClip.mkv',
      kind: MediaKind.video,
      fileSize: 310000000,
      isAvailable: false,
      addedAt: now.subtract(const Duration(days: 10)),
      metadata: const MediaMetadata(
        title: 'Missing Archive Clip',
        duration: Duration(minutes: 5, seconds: 10),
      ),
    ),
  ];

  final folders = <LibraryFolderRecord>[
    LibraryFolderRecord(
      path: 'C:/Music',
      addedAt: now.subtract(const Duration(days: 5)),
      isAvailable: true,
      fileCount: 3,
    ),
    LibraryFolderRecord(
      path: 'E:/Missing',
      addedAt: now.subtract(const Duration(days: 10)),
      isAvailable: false,
      fileCount: 1,
    ),
  ];

  final playlist = PlaylistRecord(
    id: 'pl_1',
    title: 'Workout Beats',
    createdAt: now.subtract(const Duration(days: 1)),
    updatedAt: now.subtract(const Duration(days: 1)),
    entryCount: 2,
  );

  final playlistEntries = <String, List<PlaylistEntryRecord>>{
    'pl_1': [
      PlaylistEntryRecord(
        id: 'pe_1',
        playlistId: 'pl_1',
        mediaId: 'm1',
        position: 0,
        addedAt: now,
        mediaItem: items[0],
      ),
      PlaylistEntryRecord(
        id: 'pe_2',
        playlistId: 'pl_1',
        mediaId: 'm2',
        position: 1,
        addedAt: now,
        mediaItem: items[1],
      ),
    ],
  };

  return InMemoryMediaLibraryRepository(
    initialFolders: folders,
    initialItems: items,
    initialPlaylists: [playlist],
    initialPlaylistEntries: playlistEntries,
  );
}

Widget wrapWithApp(Widget child, {Size? size}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: size != null
        ? MediaQuery(
            data: MediaQueryData(size: size),
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: child,
            ),
          )
        : child,
  );
}
