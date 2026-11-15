import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/services/media_probe_service_impl.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

List<int> _be16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _mp4Box(String type, List<int> payload) => <int>[
  ..._be32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
];

Uint8List _buildMinimalMp4({
  int width = 1920,
  int height = 1080,
  int fps = 24,
  int durationSeconds = 12,
  int avgVideoBitrate = 8400000,
  int sampleRate = 48000,
  int channels = 2,
}) {
  final ftyp = _mp4Box('ftyp', <int>[
    ...ascii.encode('isom'),
    0,
    0,
    0,
    0,
    ...ascii.encode('isom'),
  ]);

  final mvhdPayload = <int>[
    0, 0, 0, 0, // version + flags
    0, 0, 0, 0, // creation_time
    0, 0, 0, 0, // modification_time
    ..._be32(1000), // timescale
    ..._be32(durationSeconds * 1000),
    ...List<int>.filled(80, 0),
  ];
  final mvhd = _mp4Box('mvhd', mvhdPayload);

  final vTimescale = 24000;
  final vDurationUnits = vTimescale * durationSeconds;
  final vMdhd = _mp4Box('mdhd', <int>[
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
    ..._be32(vTimescale),
    ..._be32(vDurationUnits),
    0,
    0,
    0,
    0,
  ]);
  final vHdlr = _mp4Box('hdlr', <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...ascii.encode('vide'),
    ...List<int>.filled(12, 0),
  ]);
  final btrt = _mp4Box('btrt', <int>[
    0,
    0,
    0,
    0,
    ..._be32(avgVideoBitrate),
    ..._be32(avgVideoBitrate),
  ]);
  final avc1Entry = <int>[
    ..._be32(86 + btrt.length),
    ...ascii.encode('avc1'),
    ...List<int>.filled(24, 0),
    ..._be16(width), // offset 32
    ..._be16(height), // offset 34
    ...List<int>.filled(50, 0),
    ...btrt,
  ];
  final vStsd = _mp4Box('stsd', <int>[0, 0, 0, 0, ..._be32(1), ...avc1Entry]);
  final vStts = _mp4Box('stts', <int>[
    0,
    0,
    0,
    0,
    ..._be32(1),
    ..._be32(fps * durationSeconds),
    ..._be32(1000),
  ]);
  final videoTrak = _mp4Box('trak', <int>[
    ..._mp4Box('mdia', <int>[
      ...vMdhd,
      ...vHdlr,
      ..._mp4Box('minf', _mp4Box('stbl', <int>[...vStsd, ...vStts])),
    ]),
  ]);

  final aHdlr = _mp4Box('hdlr', <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...ascii.encode('soun'),
    ...List<int>.filled(12, 0),
  ]);
  final mp4aEntry = <int>[
    ..._be32(36),
    ...ascii.encode('mp4a'),
    ...List<int>.filled(16, 0),
    ..._be16(channels), // offset 24
    ..._be16(16), // offset 26
    0, 0, 0, 0,
    ..._be32(sampleRate << 16), // offset 32
  ];
  final aStsd = _mp4Box('stsd', <int>[0, 0, 0, 0, ..._be32(1), ...mp4aEntry]);
  final audioTrak = _mp4Box(
    'trak',
    _mp4Box('mdia', <int>[
      ...aHdlr,
      ..._mp4Box('minf', _mp4Box('stbl', aStsd)),
    ]),
  );

  final moov = _mp4Box('moov', <int>[...mvhd, ...videoTrak, ...audioTrak]);
  return Uint8List.fromList(<int>[...ftyp, ...moov]);
}

List<int> _ebmlId(int id) {
  if (id <= 0xFF) return [id];
  if (id <= 0xFFFF) return [(id >> 8) & 0xFF, id & 0xFF];
  if (id <= 0xFFFFFF) {
    return [(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF];
  }
  return _be32(id);
}

List<int> _ebmlSize(int length) {
  if (length < 0x7F) return [0x80 | length];
  return [0x40 | ((length >> 8) & 0x3F), length & 0xFF];
}

List<int> _ebmlElem(int id, List<int> data) => <int>[
  ..._ebmlId(id),
  ..._ebmlSize(data.length),
  ...data,
];

List<int> _ebmlFloat64(double v) {
  final bd = ByteData(8)..setFloat64(0, v, Endian.big);
  return bd.buffer.asUint8List();
}

Uint8List _buildMinimalMkv({
  int width = 3840,
  int height = 2160,
  int fps = 60,
  double durationMs = 45000.0,
  String title = 'Sample MKV',
}) {
  final ebml = _ebmlElem(0x1A45DFA3, _ebmlElem(0x4286, [1]));
  final info = _ebmlElem(0x1549A966, <int>[
    ..._ebmlElem(0x2AD7B1, [0x0F, 0x42, 0x40]), // TimecodeScale = 1_000_000 ns
    ..._ebmlElem(0x4489, _ebmlFloat64(durationMs)),
    ..._ebmlElem(0x7BA9, utf8.encode(title)),
  ]);
  final defaultDurNs = (1000000000 / fps).round();
  final videoEntry = _ebmlElem(0xAE, <int>[
    ..._ebmlElem(0x83, [1]),
    ..._ebmlElem(0x86, ascii.encode('V_MPEGH/ISO/HEVC')),
    ..._ebmlElem(0x23E383, _be32(defaultDurNs)),
    ..._ebmlElem(0xE0, <int>[
      ..._ebmlElem(0xB0, _be16(width)),
      ..._ebmlElem(0xBA, _be16(height)),
    ]),
  ]);
  final audioEntry = _ebmlElem(0xAE, <int>[
    ..._ebmlElem(0x83, [2]),
    ..._ebmlElem(0x86, ascii.encode('A_OPUS')),
    ..._ebmlElem(0xE1, <int>[
      ..._ebmlElem(0xB5, _ebmlFloat64(48000.0)),
      ..._ebmlElem(0x9F, [2]),
    ]),
  ]);
  final tracks = _ebmlElem(0x1654AE6B, <int>[...videoEntry, ...audioEntry]);
  final segment = _ebmlElem(0x18538067, <int>[...info, ...tracks]);
  return Uint8List.fromList(<int>[...ebml, ...segment]);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson_video_meta_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('VideoTechnicalInfo JSON round-trip and resolutionLabel', () {
    const original = VideoTechnicalInfo(
      codec: 'h264',
      width: 1920,
      height: 1080,
      fps: 23.976,
      bitrate: 8500000,
    );
    expect(original.isEmpty, isFalse);
    expect(original.resolutionLabel, '1920 \u00d7 1080');

    final decoded = VideoTechnicalInfo.fromJson(original.toJson());
    expect(decoded, original);

    const meta = MediaMetadata(title: 'Clip', videoInfo: original);
    final decodedMeta = MediaMetadata.fromJson(meta.toJson());
    expect(decodedMeta.videoInfo, original);
  });

  test(
    'PureDartMediaParser & MediaProbeServiceImpl extract MP4 video metadata without booting libmpv',
    () async {
      final mp4File = File('${tempDir.path}${Platform.pathSeparator}clip.mp4');
      await mp4File.writeAsBytes(
        _buildMinimalMp4(
          width: 1920,
          height: 1080,
          fps: 24,
          durationSeconds: 12,
          avgVideoBitrate: 8400000,
        ),
        flush: true,
      );

      final engine = MediaKitProbeEngine(
        playerFactory: () =>
            throw StateError('Native player should not boot for MP4 fast path'),
      );
      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: tempDir,
      );
      addTearDown(service.dispose);

      final result = await service.probe(mp4File.path);
      expect(result.kind, MediaKind.video);
      expect(result.metadata.duration, const Duration(seconds: 12));
      expect(result.metadata.videoInfo, isNotNull);
      expect(result.metadata.videoInfo!.codec, 'h264');
      expect(result.metadata.videoInfo!.width, 1920);
      expect(result.metadata.videoInfo!.height, 1080);
      expect(result.metadata.videoInfo!.fps, closeTo(24.0, 0.01));
      expect(result.metadata.videoInfo!.bitrate, 8400000);
      expect(result.metadata.audioInfo?.codec, 'aac');
      expect(result.metadata.audioInfo?.sampleRate, 48000);
      expect(result.metadata.audioInfo?.channels, 2);
    },
  );

  test(
    'PureDartMediaParser & MediaProbeServiceImpl extract MKV video metadata without booting libmpv',
    () async {
      final mkvFile = File('${tempDir.path}${Platform.pathSeparator}movie.mkv');
      await mkvFile.writeAsBytes(
        _buildMinimalMkv(
          width: 3840,
          height: 2160,
          fps: 60,
          durationMs: 45000.0,
          title: 'Ultra HD Demo',
        ),
        flush: true,
      );

      final engine = MediaKitProbeEngine(
        playerFactory: () =>
            throw StateError('Native player should not boot for MKV fast path'),
      );
      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: tempDir,
      );
      addTearDown(service.dispose);

      final result = await service.probe(mkvFile.path);
      expect(result.kind, MediaKind.video);
      expect(result.metadata.title, 'Ultra HD Demo');
      expect(result.metadata.duration, const Duration(seconds: 45));
      expect(result.metadata.videoInfo?.codec, 'hevc');
      expect(result.metadata.videoInfo?.width, 3840);
      expect(result.metadata.videoInfo?.height, 2160);
      expect(result.metadata.videoInfo?.fps, closeTo(60.0, 0.05));
      expect(result.metadata.audioInfo?.codec, 'opus');
      expect(result.metadata.audioInfo?.sampleRate, 48000);
      expect(result.metadata.audioInfo?.channels, 2);
    },
  );

  test(
    'LibraryDatabase migrates v2 to v3 and persists VideoTechnicalInfo',
    () async {
      final dbPath = '${tempDir.path}${Platform.pathSeparator}library.db';
      final legacyDb = sqlite.sqlite3.open(dbPath);
      legacyDb.execute('''
      CREATE TABLE folders (
        path TEXT PRIMARY KEY,
        added_at INTEGER NOT NULL,
        last_scanned_at INTEGER,
        is_available INTEGER NOT NULL DEFAULT 1,
        file_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE media (
        id TEXT PRIMARY KEY,
        canonical_source TEXT NOT NULL UNIQUE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT,
        artist TEXT,
        album_artist TEXT,
        album TEXT,
        genre TEXT,
        year INTEGER,
        track_number INTEGER,
        disc_number INTEGER,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        artwork_uri TEXT,
        audio_codec TEXT,
        sample_rate INTEGER,
        channels INTEGER,
        bitrate INTEGER,
        bits_per_sample INTEGER,
        file_size INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER,
        is_available INTEGER NOT NULL DEFAULT 1,
        is_in_library INTEGER NOT NULL DEFAULT 1,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        last_played_at INTEGER,
        play_count INTEGER NOT NULL DEFAULT 0
      );
      PRAGMA user_version = 2;
    ''');
      legacyDb.execute('''
      INSERT INTO media (
        id, canonical_source, path, kind, title, duration_ms, file_size, added_at
      ) VALUES (
        'v1', 'c:\\videos\\legacy.mp4', 'C:\\Videos\\legacy.mp4', 'video',
        'Legacy Clip', 15000, 1024, 1700000000000
      );
    ''');
      legacyDb.close();

      final db = await LibraryDatabase.open(path: dbPath);
      try {
        const videoInfo = VideoTechnicalInfo(
          codec: 'hevc',
          width: 2560,
          height: 1440,
          fps: 59.94,
          bitrate: 12000000,
        );
        await db.updateMediaMetadata(
          'C:\\Videos\\legacy.mp4',
          kind: MediaKind.video,
          metadata: const MediaMetadata(
            title: 'Legacy Clip',
            duration: Duration(seconds: 15),
            videoInfo: videoInfo,
            audioInfo: AudioTechnicalInfo(
              codec: 'aac',
              sampleRate: 48000,
              channels: 2,
            ),
          ),
          fileSize: 2048,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000005000),
        );

        final loaded = await db.getMediaByCanonicalSource(
          'C:\\Videos\\legacy.mp4',
        );
        expect(loaded, isNotNull);
        expect(loaded!.metadata.videoInfo, videoInfo);
        expect(loaded.metadata.audioInfo?.codec, 'aac');

        final playlist = await db.createPlaylist('Videos');
        await db.addEntriesToPlaylist(playlist.id, [loaded.id]);
        final entries = await db.getPlaylistEntries(playlist.id);
        expect(entries, hasLength(1));
        expect(entries.single.mediaItem?.metadata.videoInfo, videoInfo);
      } finally {
        await db.close();
      }
    },
  );
}
