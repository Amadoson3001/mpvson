import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/music_view.dart';
import 'package:mpvson/ui/library/views/playlists_view.dart';
import 'package:mpvson/ui/library/views/videos_view.dart';
import 'package:mpvson/ui/player/views/settings/settings_library_section.dart';

import '../../support/app_harness.dart';

class _UnavailableLibrary extends InMemoryMediaLibraryRepository {
  bool failQueries = true;

  Never _fail() => throw StateError('library database unavailable');

  @override
  Future<List<MediaItemRecord>> queryMedia({
    MediaKind? kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  }) {
    if (failQueries) _fail();
    return super.queryMedia(
      kind: kind,
      searchQuery: searchQuery,
      artist: artist,
      album: album,
      onlyFavorites: onlyFavorites,
      limit: limit,
      offset: offset,
      sortBy: sortBy,
      ascending: ascending,
    );
  }

  @override
  Future<List<PlaylistRecord>> getPlaylists() {
    if (failQueries) _fail();
    return super.getPlaylists();
  }
}

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.darkTheme(),
    home: Scaffold(body: child),
  );

  testWidgets('video query failure shows an error state, not an empty one', (
    tester,
  ) async {
    final h = Harness.create();
    final library = _UnavailableLibrary();
    await tester.pumpWidget(
      host(VideosView(repository: library, controller: h.controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load videos"), findsOneWidget);
    expect(find.text('No videos found'), findsNothing);

    library.failQueries = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    // A successful retry falls back to the honest empty state.
    expect(find.text('No videos found'), findsOneWidget);
    expect(find.text("Couldn't load videos"), findsNothing);

    await h.shutdown(tester);
    library.dispose();
  });

  testWidgets('music query failure shows an error state with retry', (
    tester,
  ) async {
    final h = Harness.create();
    final library = _UnavailableLibrary();
    await tester.pumpWidget(
      host(MusicView(repository: library, controller: h.controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load music"), findsOneWidget);
    expect(find.text('No music found'), findsNothing);

    await h.shutdown(tester);
    library.dispose();
  });

  testWidgets('playlist query failure shows an error state with retry', (
    tester,
  ) async {
    final h = Harness.create();
    final library = _UnavailableLibrary();
    await tester.pumpWidget(
      host(PlaylistsView(repository: library, controller: h.controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load playlists"), findsOneWidget);
    expect(find.text('No playlists created yet'), findsNothing);

    await h.shutdown(tester);
    library.dispose();
  });

  testWidgets('removing a library folder asks for confirmation', (
    tester,
  ) async {
    final library = InMemoryMediaLibraryRepository(
      initialFolders: [
        LibraryFolderRecord(
          path: 'D:\\Media',
          addedAt: DateTime(2025),
          fileCount: 12,
        ),
      ],
    );
    await tester.pumpWidget(
      host(MediaLibrarySettingsSection(libraryRepository: library)),
    );
    await tester.pumpAndSettle();
    expect(find.text('D:\\Media'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remove-folder-D:\\Media')));
    await tester.pumpAndSettle();
    expect(find.text('Remove folder'), findsOneWidget);
    expect(library.folders, hasLength(1));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.folders, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('remove-folder-D:\\Media')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(library.folders, isEmpty);
    library.dispose();
  });
}
