import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
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
