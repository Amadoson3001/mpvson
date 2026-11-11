import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;

void main() {
  group('MediaEntry.formatDisplayPath & canonicalCase', () {
    test('resolves actual filesystem casing for existing directory', () {
      final tempDir = Directory.systemTemp.createTempSync('Mpvson_Case_Test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      // Lowercased path representing how Windows database stores normalized path
      final lowercasedPath = tempDir.path.toLowerCase();
      final expectedCasing = p.normalize(
        MediaEntry.stripLongPathPrefix(tempDir.resolveSymbolicLinksSync()),
      );

      final result = MediaEntry.formatDisplayPath(lowercasedPath);
      expect(result, equals(expectedCasing));
      expect(MediaEntry.canonicalCase(lowercasedPath), equals(expectedCasing));
    });

    test('resolves actual filesystem casing for existing file', () {
      final tempDir = Directory.systemTemp.createTempSync('Mpvson_File_Test_');
      final tempFile = File(p.join(tempDir.path, 'TestSong_Sample.mp3'))
        ..writeAsStringSync('sample content');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final lowercasedPath = tempFile.path.toLowerCase();
      final expectedCasing = p.normalize(
        MediaEntry.stripLongPathPrefix(tempFile.resolveSymbolicLinksSync()),
      );

      final result = MediaEntry.formatDisplayPath(lowercasedPath);
      expect(result, equals(expectedCasing));
    });

    test('falls back to input string when path does not exist on disk', () {
      const missingPath = r'C:\Mock\NonExistent\Folder\Library';
      expect(MediaEntry.formatDisplayPath(missingPath), equals(missingPath));
      expect(MediaEntry.canonicalCase(missingPath), equals(missingPath));
    });

    test('preserves empty string and network URLs untouched', () {
      expect(MediaEntry.formatDisplayPath(''), equals(''));
      expect(
        MediaEntry.formatDisplayPath('http://example.com/stream.m3u8'),
        equals('http://example.com/stream.m3u8'),
      );
      expect(
        MediaEntry.formatDisplayPath('https://radio.example.org/live'),
        equals('https://radio.example.org/live'),
      );
    });

    test(
      'LibraryFolderRecord.displayPath retrieves canonical case on disk',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'Mpvson_Record_Test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        final lowercasedPath = tempDir.path.toLowerCase();
        final expectedCasing = p.normalize(
          MediaEntry.stripLongPathPrefix(tempDir.resolveSymbolicLinksSync()),
        );

        final record = LibraryFolderRecord(
          path: lowercasedPath,
          addedAt: DateTime.now(),
        );

        expect(record.path, equals(lowercasedPath));
        expect(record.displayPath, equals(expectedCasing));
      },
    );

    test('LibraryFolderRecord.displayPath falls back to path when missing', () {
      const missing = r'D:\Archived\Music';
      final record = LibraryFolderRecord(
        path: missing,
        addedAt: DateTime.now(),
      );
      expect(record.displayPath, equals(missing));
    });
  });
}
