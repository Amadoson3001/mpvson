import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/services/open_request_coordinator.dart';
import 'package:mpvson/domain/models/open_request.dart';
import 'package:path/path.dart' as p;

class _Harness {
  _Harness({FolderExpander? expandFolder}) {
    coordinator = OpenRequestCoordinator(
      preferences: AppPreferencesRepository(),
      isPlaybackActive: () => isPlaybackActive,
      executePlaybackCommand:
          ({required List<String> paths, required bool playNow}) async {
            executed.add((paths: paths, playNow: playNow));
          },
      showPreferenceDialog: () async => null,
      expandFolder: expandFolder,
    );
  }

  late final OpenRequestCoordinator coordinator;
  final executed = <({List<String> paths, bool playNow})>[];
  bool isPlaybackActive = false;

  Future<OpenResult> open(List<String> sources) =>
      coordinator.handleOpenRequest(
        OpenRequest(
          id: 'test',
          sources: sources,
          origin: OpenOrigin.dragAndDrop,
        ),
      );
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mpvson-open-folder-test-');
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // Temp cleanup is best-effort.
    }
  });

  File _file(String relativePath) {
    final file = File(p.join(root.path, relativePath));
    file.createSync(recursive: true);
    file.writeAsStringSync('data');
    return file;
  }

  group('dropped folder expansion', () {
    test('expands a folder into its supported media files', () async {
      final a = _file('a.mp3');
      _file('notes.txt');
      final c = _file(p.join('nested', 'c.mkv'));
      final harness = _Harness();

      final result = await harness.open([root.path]);

      expect(result.status, OpenStatus.accepted);
      expect(result.rejectedCount, 0);
      expect(result.message, isNull);
      expect(harness.executed, hasLength(1));
      expect(harness.executed.single.playNow, isTrue);
      expect(harness.executed.single.paths, <String>[a.path, c.path]);
    });

    test(
      'reports the settings guidance when a folder holds no media',
      () async {
        _file('only-a-document.txt');
        final harness = _Harness();

        final result = await harness.open([root.path]);

        expect(result.status, OpenStatus.rejected);
        expect(result.message, OpenRequestCoordinator.folderNotPlayableMessage);
        expect(harness.executed, isEmpty);
      },
    );

    test(
      'mixing an empty folder with valid files still plays the files',
      () async {
        final media = _file('song.flac');
        final emptyFolder = Directory(
          '${root.path}${Platform.pathSeparator}empty',
        )..createSync(recursive: true);
        final harness = _Harness();

        final result = await harness.open([emptyFolder.path, media.path]);

        expect(result.status, OpenStatus.accepted);
        expect(result.rejectedCount, 1);
        expect(result.message, OpenRequestCoordinator.folderNotPlayableMessage);
        expect(harness.executed.single.paths, <String>[media.path]);
      },
    );

    test(
      'does not queue a file twice when dropped next to its folder',
      () async {
        final media = _file('song.flac');
        final harness = _Harness();

        final result = await harness.open([media.path, root.path]);

        expect(result.status, OpenStatus.accepted);
        expect(harness.executed.single.paths, <String>[media.path]);
      },
    );

    test('uses the injected folder expander when provided', () async {
      final expanded = <String>['/virtual/one.mp4', '/virtual/two.mp4'];
      final harness = _Harness(expandFolder: (folderPath) async => expanded);

      final result = await harness.open(['/some/dropped-folder']);

      expect(result.status, OpenStatus.accepted);
      expect(harness.executed.single.paths, expanded);
    });

    test(
      'still rejects plain missing files without a folder message',
      () async {
        final harness = _Harness();

        final result = await harness.open([
          '${root.path}${Platform.pathSeparator}missing.mkv',
        ]);

        expect(result.status, OpenStatus.rejected);
        expect(result.rejectedCount, 1);
        expect(result.message, isNull);
        expect(harness.executed, isEmpty);
      },
    );
  });
}
