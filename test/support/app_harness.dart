import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import 'screenshot.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Playback engine stand-in that never loads libmpv.
class FakePlaybackService implements PlaybackService {
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _state = const PlaybackSnapshot();

  @override
  Player get player => throw UnimplementedError('No native player in tests');

  @override
  VideoController get videoController =>
      throw UnimplementedError('No native video controller in tests');

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  String get engineVersion => 'test-engine';

  VideoOutputPolicy _videoOutputPolicy = const VideoOutputPolicy();

  @override
  VideoOutputPolicy get videoOutputPolicy => _videoOutputPolicy;

  void emit(PlaybackSnapshot next) {
    _state = next;
    _states.add(next);
  }

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _videoOutputPolicy = policy;
  }
  @override
  Future<void> prepare() async {}
  @override
  Future<void> open(String path, {bool play = true}) async {
    emit(
      _state.copyWith(
        isPlaying: play,
        sourceLoaded: true,
        nativeSource: MediaEntry.canonicalSource(path),
        duration: const Duration(minutes: 4, seconds: 12),
        position: const Duration(seconds: 73),
        sourceStart: _state.sourceStart + 1,
      ),
    );
  }

  @override
  Future<void> stop() async => emit(const PlaybackSnapshot());
  @override
  Future<void> play() async => emit(_state.copyWith(isPlaying: true));
  @override
  Future<void> pause() async => emit(_state.copyWith(isPlaying: false));
  @override
  Future<void> seek(Duration position) async =>
      emit(_state.copyWith(position: position));
  @override
  Future<void> setVolume(double value) async =>
      emit(_state.copyWith(volume: value));
  @override
  Future<void> setRate(double value) async =>
      emit(_state.copyWith(rate: value));
  @override
  Future<void> setShuffle(bool value) async =>
      emit(_state.copyWith(shuffle: value));
  @override
  Future<void> setRepeatMode(String value) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> loadSubtitle(String path) async {}
  @override
  Future<void> dispose() async => _states.close();
}

/// Preferences that live in memory so tests never touch the file system.
class MemoryPreferences extends AppPreferencesRepository {
  MemoryPreferences([DesktopPreferences initial = const DesktopPreferences()])
    : _current = initial;

  DesktopPreferences _current;

  @override
  DesktopPreferences get preferences => _current;

  @override
  bool get isLoaded => true;

  @override
  Future<void> load() async {}

  @override
  Future<void> updatePreferences(DesktopPreferences preferences) async {
    _current = preferences;
    notifyListeners();
  }
}

final DateTime _epoch = DateTime(2025, 1, 1);

MediaItemRecord track(
  int n, {
  String? title,
  String? artist,
  String? album,
  MediaKind kind = MediaKind.audio,
  bool favorite = false,
  bool available = true,
  String ext = 'mp3',
}) {
  final path = 'C:\\Media\\file_$n.$ext';
  return MediaItemRecord(
    id: 'id$n',
    canonicalSource: path.toLowerCase(),
    path: path,
    kind: kind,
    metadata: MediaMetadata(
      title: title,
      artist: artist,
      album: album,
      duration: Duration(seconds: 90 + n * 7),
    ),
    fileSize: 4000000 + n * 1000,
    modifiedAt: _epoch,
    addedAt: _epoch.add(Duration(days: n)),
    isFavorite: favorite,
    isAvailable: available,
    lastPlayedAt: n.isEven ? _epoch.add(Duration(hours: n)) : null,
    playCount: n % 5,
  );
}

/// Library data that covers the awkward cases screens must survive.
List<MediaItemRecord> stressItems() => [
  track(
    1,
    title:
        'A Very Long Track Title That Keeps Going And Going Until It Cannot '
        'Possibly Fit In Any Row Or Tile In The Application',
    artist: 'An Artist With An Extremely Long Name That Also Overflows',
    album: 'An Album Whose Name Is Also Ridiculously Long For No Good Reason',
    favorite: true,
  ),
  track(2, title: '日本語のとても長いタイトルがここに入ります', artist: '歌手', album: 'アルバム'),
  track(3), // no metadata at all
  track(4, title: 'Unavailable file', available: false),
  track(5, title: 'W', artist: 'X', album: 'Y'),
  track(6, title: 'Concert Film', kind: MediaKind.video, ext: 'mkv'),
  track(
    7,
    title:
        'An Equally Verbose Video Title Describing Everything About The '
        'Footage In Needless Detail',
    kind: MediaKind.video,
    ext: 'mp4',
  ),
  for (var i = 8; i < 40; i++)
    track(
      i,
      title: 'Song $i',
      artist: 'Artist ${i % 6}',
      album: 'Album ${i % 9}',
      kind: i.isEven ? MediaKind.audio : MediaKind.video,
      ext: i.isEven ? 'flac' : 'mp4',
    ),
];

class Harness {
  Harness({
    required this.controller,
    required this.playback,
    required this.library,
    required this.prefs,
    required this.updates,
    required this.engineUpdates,
  });

  final PlayerController controller;
  final FakePlaybackService playback;
  final InMemoryMediaLibraryRepository library;
  final MemoryPreferences prefs;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;

  static Harness create({
    List<MediaItemRecord>? items,
    List<PlaylistRecord>? playlists,
    List<LibraryFolderRecord>? folders,
    LibraryScanStatus? scanStatus,
    DesktopPreferences prefs = const DesktopPreferences(),
  }) {
    final playback = FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: SessionRepository(),
    );
    final now = _epoch;
    return Harness(
      controller: controller,
      playback: playback,
      library: InMemoryMediaLibraryRepository(
        initialItems: items ?? const [],
        initialFolders: folders,
        initialPlaylists: playlists,
        initialScanStatus: scanStatus,
      ),
      prefs: MemoryPreferences(prefs),
      updates: UpdateService(currentVersion: '0.1.0'),
      engineUpdates: EngineUpdateService(
        appVersion: '0.1.0',
        supportedMediaKitVersion: '1.2.6',
      ),
    )..touch(now);
  }

  void touch(DateTime _) {}

  /// Tears the tree down and lets controller timers drain.
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(seconds: 10));
  }

  Widget app() => RepaintBoundary(
    key: screenshotKey,
    child: MpvsonApp(
      controller: controller,
      updates: updates,
      engineUpdates: engineUpdates,
      appPreferences: prefs,
      libraryRepository: library,
      enableNativeDrop: false,
      videoBuilder: (context, _) => const ColoredBox(color: Color(0xFF223344)),
    ),
  );
}

/// Creates empty files with [names] in a fresh temp directory and returns
/// their paths. Real I/O, so it runs inside `runAsync`.
Future<List<String>> makeMediaFiles(
  WidgetTester tester,
  List<String> names,
) async {
  final paths = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('mpvson_audit_');
    addTearDown(() => dir.delete(recursive: true));
    final out = <String>[];
    for (final name in names) {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(const [0, 0, 0, 0]);
      out.add(file.path);
    }
    return out;
  });
  return paths!;
}

/// Sets the window to [size] with [textScale] for the rest of the test.
void configureView(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Runs [body] and returns every distinct framework error it reported.
///
/// Overflow errors fire many times per frame, so errors are keyed by their
/// first line, which names the widget and overflow amount.
Future<List<String>> collectErrors(Future<void> Function() body) async {
  final original = FlutterError.onError;
  final seen = <String>{};
  FlutterError.onError = (details) {
    final text = details.exceptionAsString().split('\n').first;
    final where = details.context?.toDescription() ?? '';
    seen.add('$text $where'.trim());
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
  return seen.toList();
}

/// Pumps [harness] at [size] and returns layout errors.
Future<List<String>> pumpAudit(
  WidgetTester tester,
  Harness harness, {
  required Size size,
  double textScale = 1,
}) {
  configureView(tester, size: size, textScale: textScale);
  return collectErrors(() async {
    await tester.pumpWidget(harness.app());
    await settle(tester);
  });
}

/// Text on screen whose style does not resolve to the app font.
///
/// `ButtonStyle.textStyle` and similar overrides replace the theme style, so a
/// bare `TextStyle(fontSize: 13)` there silently drops the Onest family.
Set<String> fontIssues(WidgetTester tester) {
  const allowed = {'Onest', 'monospace', 'MaterialIcons'};
  final out = <String>{};
  void visit(RenderObject node) {
    if (node is RenderParagraph) {
      final span = node.text;
      final family = span.style?.fontFamily;
      final plain = span.toPlainText();
      final isIcon =
          plain.isNotEmpty &&
          plain.runes.every((r) => r >= 0xE000 && r <= 0xF8FF);
      if (!isIcon &&
          plain.trim().isNotEmpty &&
          !allowed.contains(family) &&
          !(family?.startsWith('packages/') ?? false)) {
        out.add(
          '"${plain.length > 40 ? plain.substring(0, 40) : plain}" '
          'family=$family',
        );
      }
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.renderViews.first);
  return out;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}
