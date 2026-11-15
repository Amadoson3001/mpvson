import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/widgets/media_properties_dialog.dart';
import 'package:mpvson/ui/player/views/settings/settings_empty_fallbacks.dart';
import 'package:path/path.dart' as p;

class _FakeLibraryRepository extends EmptyMediaLibraryRepository {
  _FakeLibraryRepository({this.onLookup});

  final Future<MediaItemRecord?> Function(String canonicalSource)? onLookup;
  final List<String> lookupKeys = <String>[];

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async {
    lookupKeys.add(canonicalSource);
    if (onLookup != null) {
      return onLookup!(canonicalSource);
    }
    return null;
  }
}

Widget _wrapWithApp(Widget child) {
  return MaterialApp(
    theme: AppTheme.darkTheme(),
    home: Scaffold(body: child),
  );
}

Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 40; i++) {
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mpvson_props_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('loads file stat and library metadata and canonicalizes lookup', (
    tester,
  ) async {
    final file = File(p.join(tempDir.path, 'Track, 01.flac'))
      ..writeAsBytesSync(List<int>.filled(2048, 7));

    final record = MediaItemRecord(
      id: 'rec-1',
      canonicalSource: MediaEntry.canonicalSource(file.path),
      path: file.path,
      kind: MediaKind.audio,
      fileSize: 1024,
      addedAt: DateTime(2026, 1, 1),
      lastPlayedAt: DateTime(2026, 5, 10, 14, 30),
      playCount: 4,
      metadata: const MediaMetadata(
        title: 'Midnight Signal',
        artist: 'The Testers',
        album: 'Test Waves',
        genre: 'Electronic',
        year: 2026,
        duration: Duration(minutes: 3, seconds: 42),
        audioInfo: AudioTechnicalInfo(
          codec: 'flac',
          sampleRate: 48000,
          bitrate: 960000,
          bitsPerSample: 24,
          channels: 2,
        ),
      ),
    );

    final repo = _FakeLibraryRepository(onLookup: (_) async => record);
    final fileUri = Uri.file(file.path).toString();

    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: fileUri,
          title: 'Midnight Signal',
          kind: MediaKind.audio,
          repository: repo,
          position: const Duration(minutes: 1, seconds: 5),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    expect(repo.lookupKeys, [MediaEntry.canonicalSource(fileUri)]);
    expect(find.text('Midnight Signal'), findsOneWidget);
    expect(find.text('Audio  •  FLAC'), findsOneWidget);
    expect(find.text('Track, 01.flac'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('3:42'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('The Testers'), findsOneWidget);
    expect(find.text('Test Waves'), findsOneWidget);
    expect(find.text('Electronic'), findsOneWidget);
    expect(find.text('2026'), findsOneWidget);
    expect(
      find.text('FLAC  •  48.0 kHz  •  960 kbps  •  24-bit  •  2 ch'),
      findsOneWidget,
    );
    expect(find.text('4'), findsOneWidget);
    expect(
      find.text('This file is currently missing from disk.'),
      findsNothing,
    );
    expect(find.text('Open in File Explorer'), findsOneWidget);
  });

  testWidgets('detects missing file on disk even without library record', (
    tester,
  ) async {
    final missingPath = p.join(tempDir.path, 'missing_video.mp4');
    final repo = _FakeLibraryRepository();

    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: missingPath,
          title: 'Missing Video',
          kind: MediaKind.video,
          repository: repo,
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    expect(
      find.text('This file is currently missing from disk.'),
      findsOneWidget,
    );
    // Open in File Explorer remains available so parent folder fallback works.
    expect(find.text('Open in File Explorer'), findsOneWidget);
  });

  testWidgets('hides File Explorer actions for network/stream URLs', (
    tester,
  ) async {
    final repo = _FakeLibraryRepository();
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: 'rtsp://192.168.1.20:554/stream1',
          title: 'Lobby Camera',
          kind: MediaKind.unknown,
          repository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stream'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Folder'), findsNothing);
    expect(find.text('Open in File Explorer'), findsNothing);
    expect(
      find.text('This file is currently missing from disk.'),
      findsNothing,
    );

    await tester.tap(find.byTooltip('Copy source URL'));
    await tester.pump();
    expect(copiedText, 'rtsp://192.168.1.20:554/stream1');
  });

  testWidgets(
    'Open in File Explorer calls callback and shows warning toast on failure',
    (tester) async {
      final file = File(p.join(tempDir.path, 'clip.mp4'))
        ..writeAsStringSync('data');
      final repo = _FakeLibraryRepository();

      String? revealedPath;
      await tester.pumpWidget(
        _wrapWithApp(
          MediaPropertiesDialog(
            path: file.path,
            title: 'Clip',
            kind: MediaKind.video,
            repository: repo,
            onShowInFolder: (path) => revealedPath = path,
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      await tester.tap(find.text('Open in File Explorer'));
      await tester.pump();
      expect(revealedPath, p.windows.normalize(file.path));

      // Default showInFolder path when revealInFolder returns false shows toast.
      await tester.pumpWidget(
        _wrapWithApp(
          MediaPropertiesDialog(
            path: file.path,
            title: 'Clip',
            kind: MediaKind.video,
            repository: repo,
            revealInFolder: (_) async => false,
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      await tester.tap(find.text('Open in File Explorer'));
      await tester.pumpAndSettle();
      expect(find.text('Could not open File Explorer'), findsOneWidget);
    },
  );

  testWidgets('handles async unmount and repository errors safely', (
    tester,
  ) async {
    final completer = Completer<MediaItemRecord?>();
    final slowRepo = _FakeLibraryRepository(onLookup: (_) => completer.future);

    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: p.join(tempDir.path, 'async.mp4'),
          title: 'Async Test',
          kind: MediaKind.video,
          repository: slowRepo,
        ),
      ),
    );
    await tester.pump();

    // Unmount dialog before repository lookup resolves.
    await tester.pumpWidget(_wrapWithApp(const SizedBox.shrink()));
    completer.complete(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Repository throwing should not crash the dialog.
    final errorRepo = _FakeLibraryRepository(
      onLookup: (_) async => throw StateError('db locked'),
    );
    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: p.join(tempDir.path, 'err.mp4'),
          title: 'Error Test',
          kind: MediaKind.video,
          repository: errorRepo,
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Error Test'), findsOneWidget);
  });

  testWidgets(
    'MediaPropertiesDialog.show opens and closes via Navigator and guards missing Navigator',
    (tester) async {
      final file = File(p.join(tempDir.path, 'dialog_show.mp4'))
        ..writeAsStringSync('data');
      final repo = _FakeLibraryRepository();

      // Context with no Navigator ancestor should safely return without throwing.
      late BuildContext rootlessContext;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            rootlessContext = context;
            return const SizedBox.shrink();
          },
        ),
      );
      await MediaPropertiesDialog.show(
        rootlessContext,
        path: file.path,
        title: 'No Nav',
        kind: MediaKind.video,
        repository: repo,
      );
      expect(tester.takeException(), isNull);

      // Normal Navigator context opens and Close button dismisses.
      late BuildContext appContext;
      await tester.pumpWidget(
        _wrapWithApp(
          Builder(
            builder: (context) {
              appContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final showFuture = MediaPropertiesDialog.show(
        appContext,
        path: file.path,
        title: 'Shown Via Static Show',
        kind: MediaKind.video,
        repository: repo,
      );
      await _pumpUntilLoaded(tester);
      expect(find.text('Shown Via Static Show'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await showFuture;
      expect(find.text('Shown Via Static Show'), findsNothing);
    },
  );

  testWidgets('displays VideoTechnicalInfo row for video items', (
    tester,
  ) async {
    final repo = _FakeLibraryRepository(onLookup: (_) async => null);
    final videoFile = File(p.join(tempDir.path, 'trailer.mp4'))
      ..writeAsBytesSync(const [1, 2, 3]);

    final record = MediaItemRecord(
      id: 'vid-1',
      canonicalSource: MediaEntry.canonicalSource(videoFile.path),
      path: videoFile.path,
      kind: MediaKind.video,
      metadata: const MediaMetadata(
        title: 'Trailer',
        duration: Duration(minutes: 2, seconds: 10),
        videoInfo: VideoTechnicalInfo(
          codec: 'h264',
          width: 1920,
          height: 1080,
          fps: 23.976,
          bitrate: 8400000,
        ),
        audioInfo: AudioTechnicalInfo(
          codec: 'aac',
          sampleRate: 48000,
          channels: 2,
        ),
      ),
      fileSize: 1024 * 1024,
      addedAt: DateTime(2025, 1, 1),
    );

    await tester.pumpWidget(
      _wrapWithApp(
        MediaPropertiesDialog(
          path: videoFile.path,
          title: 'Trailer',
          kind: MediaKind.video,
          repository: repo,
          initialRecord: record,
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    expect(find.text('Video  •  MP4'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(
      find.text('H.264  •  1920 × 1080  •  23.98 fps  •  8.4 Mbps'),
      findsOneWidget,
    );
    expect(find.text('AAC  •  48.0 kHz  •  2 ch'), findsOneWidget);
  });

  testWidgets(
    'probes real MP4 video on demand when opening Properties without videoInfo',
    (tester) async {
      final repo = _FakeLibraryRepository(onLookup: (_) async => null);
      final videoFile = File(p.join(tempDir.path, 'on_demand.mp4'))
        ..writeAsBytesSync(_buildMinimalMp4Bytes());

      await tester.pumpWidget(
        _wrapWithApp(
          MediaPropertiesDialog(
            path: videoFile.path,
            title: 'On Demand',
            kind: MediaKind.video,
            repository: repo,
          ),
        ),
      );

      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find
            .text('H.264  •  1280 × 720  •  30 fps  •  5.0 Mbps')
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }

      expect(
        find.text('H.264  •  1280 × 720  •  30 fps  •  5.0 Mbps'),
        findsOneWidget,
      );
      expect(find.text('0:10'), findsOneWidget);
    },
  );
}

List<int> _buildMinimalMp4Bytes() {
  List<int> be16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  List<int> be32(int v) => [
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];
  List<int> box(String type, List<int> payload) => <int>[
    ...be32(8 + payload.length),
    ...type.codeUnits,
    ...payload,
  ];

  final ftyp = box('ftyp', <int>[
    ...'isom'.codeUnits,
    0,
    0,
    0,
    0,
    ...'isom'.codeUnits,
  ]);
  final mvhd = box('mvhd', <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...be32(1000),
    ...be32(10000),
    ...List<int>.filled(80, 0),
  ]);
  final vMdhd = box('mdhd', <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...be32(30000),
    ...be32(300000),
    0,
    0,
    0,
    0,
  ]);
  final vHdlr = box('hdlr', <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...'vide'.codeUnits,
    ...List<int>.filled(12, 0),
  ]);
  final btrt = box('btrt', <int>[
    0,
    0,
    0,
    0,
    ...be32(5000000),
    ...be32(5000000),
  ]);
  final avc1 = <int>[
    ...be32(86 + btrt.length),
    ...'avc1'.codeUnits,
    ...List<int>.filled(24, 0),
    ...be16(1280),
    ...be16(720),
    ...List<int>.filled(50, 0),
    ...btrt,
  ];
  final stsd = box('stsd', <int>[0, 0, 0, 0, ...be32(1), ...avc1]);
  final stts = box('stts', <int>[
    0,
    0,
    0,
    0,
    ...be32(1),
    ...be32(300),
    ...be32(1000),
  ]);
  final trak = box(
    'trak',
    box('mdia', <int>[
      ...vMdhd,
      ...vHdlr,
      ...box('minf', box('stbl', <int>[...stsd, ...stts])),
    ]),
  );
  return <int>[
    ...ftyp,
    ...box('moov', <int>[...mvhd, ...trak]),
  ];
}
