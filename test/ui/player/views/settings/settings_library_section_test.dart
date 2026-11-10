import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/player/views/settings/settings_library_section.dart';

void main() {
  final folder = LibraryFolderRecord(
    path: r'C:\Music',
    addedAt: DateTime(2025),
    fileCount: 3,
  );

  testWidgets('remove control re-arms only after the operation settles', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repository = BlockingRepository(folders: [folder], gate: gate);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibrarySettingsSection(libraryRepository: repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icon = find.byIcon(Icons.delete_outline_rounded);
    IconButton button() => tester.widget<IconButton>(
      find.ancestor(of: icon, matching: find.byType(IconButton)).first,
    );

    expect(button().onPressed, isNotNull);

    await tester.tap(icon);
    await tester.pump();

    // While the removal is in flight the control is disabled and cannot
    // start a second mutation.
    expect(button().onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();

    expect(button().onPressed, isNotNull);
  });

  testWidgets('remove failure shows an error toast', (tester) async {
    final repository = FailingRepository(folders: [folder]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibrarySettingsSection(libraryRepository: repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not remove that folder. Please check directory permissions.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('add and rescan controls share the pending-operation gate', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repository = BlockingRepository(folders: [folder], gate: gate);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibrarySettingsSection(libraryRepository: repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('add-folder-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('rescan-all-button')),
          )
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('add-folder-button')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'displays actual filesystem casing for existing directory on disk',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'Mpvson_UiCase_Test_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final lowercased = tempDir.path.toLowerCase();
      final expectedCasing = MediaEntry.formatDisplayPath(tempDir.path);

      final diskFolder = LibraryFolderRecord(
        path: lowercased,
        addedAt: DateTime(2026),
        fileCount: 5,
      );
      final repository = InMemoryMediaLibraryRepository(
        initialFolders: [diskFolder],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaLibrarySettingsSection(libraryRepository: repository),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(expectedCasing), findsOneWidget);
    },
  );

  testWidgets(
    'falls back to stored folder.path when directory is not on disk',
    (tester) async {
      const missing = r'X:\NonExistent\Music\Catalog';
      final mockFolder = LibraryFolderRecord(
        path: missing,
        addedAt: DateTime(2026),
        fileCount: 0,
        isAvailable: false,
      );
      final repository = InMemoryMediaLibraryRepository(
        initialFolders: [mockFolder],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaLibrarySettingsSection(libraryRepository: repository),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(missing), findsOneWidget);
    },
  );

  testWidgets('addFolder normalizes casing with actual filesystem casing', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'Mpvson_AddFolder_Test_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final lowercased = tempDir.path.toLowerCase();
    final expectedCasing = MediaEntry.formatDisplayPath(tempDir.path);

    final repository = InMemoryMediaLibraryRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibrarySettingsSection(
            libraryRepository: repository,
            pickDirectory: () async => lowercased,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-folder-button')));
    await tester.pumpAndSettle();

    expect(repository.folders.single.path, equals(expectedCasing));
    expect(find.text(expectedCasing), findsOneWidget);
  });
}

class BlockingRepository extends InMemoryMediaLibraryRepository {
  BlockingRepository({
    required List<LibraryFolderRecord> folders,
    required this.gate,
  }) : super(initialFolders: folders);

  final Completer<void> gate;

  @override
  Future<void> removeFolder(String path) => gate.future;
}

class FailingRepository extends InMemoryMediaLibraryRepository {
  FailingRepository({required List<LibraryFolderRecord> folders})
    : super(initialFolders: folders);

  @override
  Future<void> removeFolder(String path) async {
    throw StateError('simulated removal failure');
  }
}
