import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_kind.dart';
import 'package:mpvson/domain/models/media_metadata.dart';

void main() {
  group('Path Edge-Cases Normalization and Canonical Source Mapping', () {
    test('filenames with spaces are normalized and canonicalized', () {
      final path = Platform.isWindows
          ? r'C:\Music\My Cool Song (Remix 2024).mp3'
          : '/media/Music/My Cool Song (Remix 2024).mp3';

      final normalized = MediaEntry.normalizeSourcePath(path);
      final canonical = MediaEntry.canonicalSource(path);
      final title = MediaEntry.titleFromPath(path);

      expect(normalized, contains('My Cool Song (Remix 2024).mp3'));
      if (Platform.isWindows) {
        expect(canonical, equals(r'c:\music\my cool song (remix 2024).mp3'));
      } else {
        expect(canonical, equals(path));
      }
      expect(title, equals('My Cool Song (Remix 2024).mp3'));
    });

    test(
      'filenames with Arabic text are normalized, canonicalized, and preserve characters',
      () {
        final path = Platform.isWindows
            ? r'C:\Music\موسيقى عربية.mp3'
            : '/music/موسيقى عربية.mp3';

        final normalized = MediaEntry.normalizeSourcePath(path);
        final canonical = MediaEntry.canonicalSource(path);
        final title = MediaEntry.titleFromPath(path);

        expect(normalized, contains('موسيقى عربية.mp3'));
        if (Platform.isWindows) {
          expect(canonical, equals(r'c:\music\موسيقى عربية.mp3'));
        } else {
          expect(canonical, equals(path));
        }
        expect(title, equals('موسيقى عربية.mp3'));
      },
    );

    test(
      'filenames with emoji symbols are preserved without corrupting surrogate pairs',
      () {
        final path = Platform.isWindows
            ? r'C:\Music\🎵 Song ✨.flac'
            : '/music/🎵 Song ✨.flac';

        final normalized = MediaEntry.normalizeSourcePath(path);
        final canonical = MediaEntry.canonicalSource(path);
        final title = MediaEntry.titleFromPath(path);

        expect(normalized, contains('🎵 Song ✨.flac'));
        if (Platform.isWindows) {
          expect(canonical, equals(r'c:\music\🎵 song ✨.flac'));
        } else {
          expect(canonical, equals(path));
        }
        expect(title, equals('🎵 Song ✨.flac'));
      },
    );

    test(
      'filenames with reserved URI characters ([, ], #, ?, %, &) are normalized safely',
      () {
        final path = Platform.isWindows
            ? r'C:\Music\[2024] Rock #1 ? 100% & More.mp3'
            : '/music/[2024] Rock #1 ? 100% & More.mp3';

        final normalized = MediaEntry.normalizeSourcePath(path);
        final canonical = MediaEntry.canonicalSource(path);
        final title = MediaEntry.titleFromPath(path);

        expect(normalized, contains(r'[2024] Rock #1 ? 100% & More.mp3'));
        if (Platform.isWindows) {
          expect(
            canonical,
            equals(r'c:\music\[2024] rock #1 ? 100% & more.mp3'),
          );
        } else {
          expect(canonical, equals(path));
        }
        expect(title, equals(r'[2024] Rock #1 ? 100% & More.mp3'));
      },
    );

    test('file URIs map to the same canonical source as local file paths', () {
      final local = r'C:\path\file.mp3';
      final fileUri = 'file:///C:/path/file.mp3';

      final normUri = MediaEntry.normalizeSourcePath(fileUri);
      final canonUri = MediaEntry.canonicalSource(fileUri);
      final canonLocal = MediaEntry.canonicalSource(local);

      if (Platform.isWindows) {
        expect(normUri, equals(r'C:\path\file.mp3'));
        expect(canonUri, equals(r'c:\path\file.mp3'));
        expect(canonUri, equals(canonLocal));
      }
    });

    test(
      'percent-encoded file URIs decode Arabic and emojis to match canonical representation',
      () {
        if (!Platform.isWindows) return;

        const rawArabicUri =
            'file:///C:/Music/%D9%85%D9%88%D8%B3%D9%8A%D9%82%D9%89%20%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9.mp3';
        const rawEmojiUri =
            'file:///C:/Music/%F0%9F%8E%B5%20Song%20%E2%9C%A8.flac';

        final canonArabicUri = MediaEntry.canonicalSource(rawArabicUri);
        final canonArabicPath = MediaEntry.canonicalSource(
          r'C:\Music\موسيقى عربية.mp3',
        );
        expect(canonArabicUri, equals(canonArabicPath));

        final canonEmojiUri = MediaEntry.canonicalSource(rawEmojiUri);
        final canonEmojiPath = MediaEntry.canonicalSource(
          r'C:\Music\🎵 Song ✨.flac',
        );
        expect(canonEmojiUri, equals(canonEmojiPath));
      },
    );

    test('Windows UNC paths are preserved and canonicalized', () {
      const uncPath = r'\\server\share\file.mp4';
      final norm = MediaEntry.normalizeSourcePath(uncPath);
      final canon = MediaEntry.canonicalSource(uncPath);
      final title = MediaEntry.titleFromPath(uncPath);

      expect(norm, equals(r'\\server\share\file.mp4'));
      expect(canon, equals(r'\\server\share\file.mp4'));
      expect(title, equals('file.mp4'));
    });

    test(
      'Windows long path prefix (\\\\?\\) is stripped during normalization and canonicalization',
      () {
        const longPath = r'\\?\C:\long\nested\folder\file.mp3';
        final norm = MediaEntry.normalizeSourcePath(longPath);
        final canon = MediaEntry.canonicalSource(longPath);
        final title = MediaEntry.titleFromPath(longPath);

        if (Platform.isWindows) {
          expect(norm, equals(r'C:\long\nested\folder\file.mp3'));
          expect(canon, equals(r'c:\long\nested\folder\file.mp3'));
          expect(
            canon,
            equals(
              MediaEntry.canonicalSource(r'C:\long\nested\folder\file.mp3'),
            ),
          );
        }
        expect(title, equals('file.mp3'));
      },
    );

    test(
      'Windows UNC long path prefix (\\\\?\\UNC\\) is stripped to standard UNC',
      () {
        const longUnc = r'\\?\UNC\server\share\sub\file.mp4';
        final norm = MediaEntry.normalizeSourcePath(longUnc);
        final canon = MediaEntry.canonicalSource(longUnc);
        final title = MediaEntry.titleFromPath(longUnc);

        expect(norm, equals(r'\\server\share\sub\file.mp4'));
        expect(canon, equals(r'\\server\share\sub\file.mp4'));
        expect(title, equals('file.mp4'));
      },
    );
  });

  group('Database Retrieval with Path Edge-Cases', () {
    late LibraryDatabase db;

    setUp(() async {
      db = await LibraryDatabase.open(inMemory: true);
    });

    tearDown(() async {
      await db.close();
    });

    test('batch upsert and retrieval of edge-case paths', () async {
      final edgePaths = <String>[
        if (Platform.isWindows) ...[
          r'C:\Music\Spaces In Title.mp3',
          r'C:\Music\موسيقى عربية.mp3',
          r'C:\Music\🎵 Song ✨.flac',
          r'C:\Music\[2024] Rock #1 ? 100% & More.mp3',
          r'file:///C:/path/file.mp3',
          r'\\server\share\file.mp4',
          r'\\?\C:\long\prefixed\track.mp3',
          r'\\?\UNC\server\share\video.mp4',
        ] else ...[
          '/music/Spaces In Title.mp3',
          '/music/موسيقى عربية.mp3',
          '/music/🎵 Song ✨.flac',
          '/music/[2024] Rock #1 ? 100% & More.mp3',
          'file:///music/file.mp3',
          '/server/share/file.mp4',
        ],
      ];

      // Batch upsert discovered paths
      await db.batchUpsertDiscoveredFiles(edgePaths);

      // Verify each edge case can be retrieved via canonical source or path
      for (final rawPath in edgePaths) {
        final canonical = MediaEntry.canonicalSource(rawPath);
        final itemByCanon = await db.getMediaByCanonicalSource(canonical);
        expect(
          itemByCanon,
          isNotNull,
          reason: 'Failed to retrieve by canonical source for "$rawPath"',
        );

        final itemByRawCanon = await db.getMediaByCanonicalSource(rawPath);
        expect(
          itemByRawCanon,
          isNotNull,
          reason: 'Failed to retrieve by raw source for "$rawPath"',
        );

        final itemByPath = await db.getMediaByPath(rawPath);
        expect(
          itemByPath,
          isNotNull,
          reason: 'Failed to retrieve by path for "$rawPath"',
        );

        expect(itemByCanon!.id, equals(itemByRawCanon!.id));
        expect(itemByCanon.id, equals(itemByPath!.id));
      }
    });

    test(
      'metadata enrichment and FTS search across Arabic, emoji, and reserved chars',
      () async {
        final arabicPath = Platform.isWindows
            ? r'C:\Music\arabic_track.mp3'
            : '/music/arabic_track.mp3';
        final emojiPath = Platform.isWindows
            ? r'C:\Music\emoji_track.flac'
            : '/music/emoji_track.flac';
        final reservedPath = Platform.isWindows
            ? r'C:\Music\special_track.mp3'
            : '/music/special_track.mp3';

        await db.batchUpsertDiscoveredFiles([
          arabicPath,
          emojiPath,
          reservedPath,
        ]);

        // Enrich metadata
        await db.updateMediaMetadata(
          arabicPath,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'موسيقى عربية أصيلة',
            artist: 'فيروز',
            album: 'أجمل الأغاني',
          ),
          fileSize: 4096000,
          modifiedAt: DateTime(2025, 1, 1),
        );

        await db.updateMediaMetadata(
          emojiPath,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: '🎵 Starlight Symphony ✨',
            artist: '🎧 DJ Cosmos',
            album: 'Galaxy Beats 🚀',
          ),
          fileSize: 8192000,
          modifiedAt: DateTime(2025, 1, 2),
        );

        await db.updateMediaMetadata(
          reservedPath,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Track #1: 100% [Best] & Live?',
            artist: 'Band & Co.',
            album: 'The [Special] Album',
          ),
          fileSize: 5120000,
          modifiedAt: DateTime(2025, 1, 3),
        );

        // Verify retrieval by Arabic search query
        final arabicResults = await db.queryMedia(searchQuery: 'فيروز');
        expect(arabicResults, hasLength(1));
        expect(
          arabicResults.first.metadata.title,
          equals('موسيقى عربية أصيلة'),
        );

        final arabicTitleResults = await db.queryMedia(searchQuery: 'موسيقى');
        expect(arabicTitleResults, isNotEmpty);
        expect(
          arabicTitleResults.any((i) => i.metadata.artist == 'فيروز'),
          isTrue,
        );

        // Verify retrieval by emoji / text search query
        final emojiResults = await db.queryMedia(searchQuery: 'Starlight');
        expect(emojiResults, hasLength(1));
        expect(
          emojiResults.first.metadata.title,
          equals('🎵 Starlight Symphony ✨'),
        );

        final djResults = await db.queryMedia(searchQuery: 'Cosmos');
        expect(djResults, hasLength(1));
        expect(djResults.first.metadata.artist, equals('🎧 DJ Cosmos'));

        // Verify retrieval by query containing reserved URI / punctuation characters
        final reservedResults = await db.queryMedia(searchQuery: '[Best] #1');
        expect(reservedResults, hasLength(1));
        expect(
          reservedResults.first.metadata.title,
          equals('Track #1: 100% [Best] & Live?'),
        );

        // Verify exact canonical source retrieval after enrichment
        final enrichedArabic = await db.getMediaByCanonicalSource(arabicPath);
        expect(enrichedArabic?.metadata.title, equals('موسيقى عربية أصيلة'));
        expect(enrichedArabic?.metadata.artist, equals('فيروز'));
        expect(enrichedArabic?.fileSize, equals(4096000));
      },
    );

    test(
      'equivalence: file URI and local path refer to the same database row',
      () async {
        if (!Platform.isWindows) return;

        const localPath = r'C:\Library\Music\Song.mp3';
        const fileUri = 'file:///C:/Library/Music/Song.mp3';
        const longPath = r'\\?\C:\Library\Music\Song.mp3';

        // Insert via local path
        await db.batchUpsertDiscoveredFiles([localPath]);

        final initial = await db.getMediaByPath(localPath);
        expect(initial, isNotNull);

        // Re-upserting via file URI or long path updates the same row instead of creating duplicate
        await db.batchUpsertDiscoveredFiles([fileUri]);
        await db.batchUpsertDiscoveredFiles([longPath]);

        final allItems = await db.queryMedia();
        expect(allItems, hasLength(1));
        expect(allItems.first.id, equals(initial!.id));

        // Can be retrieved using any of the three representations
        expect(await db.getMediaByCanonicalSource(localPath), isNotNull);
        expect(await db.getMediaByCanonicalSource(fileUri), isNotNull);
        expect(await db.getMediaByCanonicalSource(longPath), isNotNull);

        // Record play history via file URI
        await db.recordPlayHistoryByCanonicalSource(fileUri);
        final playedItem = await db.getMediaByCanonicalSource(localPath);
        expect(playedItem?.playCount, equals(1));
      },
    );
  });
}
