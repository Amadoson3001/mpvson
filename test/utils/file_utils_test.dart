import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/utils/file_utils.dart';

void main() {
  group('showInFolder', () {
    test('empty string returns false immediately', () async {
      final result = await showInFolder('');
      expect(result, isFalse);
    });

    test('existing file on Windows executes and returns true', () async {
      // Use an existing file in the project
      final existingFile = File('pubspec.yaml').absolute.path;
      expect(File(existingFile).existsSync(), isTrue);

      final result = await showInFolder(existingFile);
      expect(result, isTrue);
    });

    test('forward-slash path is normalized and executes', () async {
      final forwardSlashPath = File(
        'pubspec.yaml',
      ).absolute.path.replaceAll(r'\', '/');
      expect(forwardSlashPath.contains('/'), isTrue);

      final result = await showInFolder(forwardSlashPath);
      expect(result, isTrue);
    });

    test('path with spaces does not throw error and executes', () async {
      // Create a temporary file in a directory with spaces
      final tempDir = Directory.systemTemp.createTempSync('mpvson test space ');
      final tempFile = File('${tempDir.path}\\test file.txt');
      tempFile.writeAsStringSync('sample content');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final result = await showInFolder(tempFile.path);
      expect(result, isTrue);
    });

    test('non-existent path does not throw exception', () async {
      final nonExistent =
          'Z:\\non_existent_folder_xyz_123\\non_existent_file.mkv';
      expect(() async => await showInFolder(nonExistent), returnsNormally);
      final result = await showInFolder(nonExistent);
      // Process should return exitCode (which explorer returns without throwing unhandled exception)
      expect(result, isA<bool>());
    });

    test('whitespace string does not throw exception', () async {
      expect(() async => await showInFolder('   '), returnsNormally);
      final result = await showInFolder('   ');
      expect(result, isA<bool>());
    });
  });
}
