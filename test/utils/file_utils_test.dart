import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/utils/file_utils.dart';
import 'package:path/path.dart' as p;

void main() {
  group('stripWindowsLongPathPrefix', () {
    test('strips \\\\?\\ prefix for drive paths', () {
      expect(
        stripWindowsLongPathPrefix(r'\\?\C:\Media\Movie.mp4'),
        r'C:\Media\Movie.mp4',
      );
    });

    test('converts \\\\?\\UNC\\ prefix to \\\\', () {
      expect(
        stripWindowsLongPathPrefix(r'\\?\UNC\nas\share\Music\song.flac'),
        r'\\nas\share\Music\song.flac',
      );
    });

    test('leaves standard paths untouched', () {
      expect(
        stripWindowsLongPathPrefix(r'C:\Media\Movie.mp4'),
        r'C:\Media\Movie.mp4',
      );
      expect(
        stripWindowsLongPathPrefix('/home/user/movie.mp4'),
        '/home/user/movie.mp4',
      );
    });
  });

  group('normalizeLocalPath', () {
    test('returns null for empty, whitespace, and network URLs', () {
      expect(normalizeLocalPath(''), isNull);
      expect(normalizeLocalPath('   \t\n '), isNull);
      expect(normalizeLocalPath('https://example.com/video.mp4'), isNull);
      expect(normalizeLocalPath('http://localhost:8080/stream'), isNull);
      expect(normalizeLocalPath('rtsp://192.168.1.10/live'), isNull);
      expect(normalizeLocalPath('rtmp://cdn.example.com/app/stream'), isNull);
      expect(normalizeLocalPath('udp://239.0.0.1:1234'), isNull);
      expect(normalizeLocalPath('mms://media.example.com/live'), isNull);
    });

    test('decodes file:// URIs on Windows and POSIX', () {
      expect(
        normalizeLocalPath(
          'file:///C:/My%20Videos/Hello%2C%20World.mp4',
          isWindows: true,
        ),
        r'C:\My Videos\Hello, World.mp4',
      );
      expect(
        normalizeLocalPath(
          'file://server/share/My%20Music/track%201.flac',
          isWindows: true,
        ),
        r'\\server\share\My Music\track 1.flac',
      );
      expect(
        normalizeLocalPath(
          'file:///home/alice/My%20Videos/clip%2C1.mkv',
          isWindows: false,
        ),
        '/home/alice/My Videos/clip,1.mkv',
      );
    });

    test('normalizes Windows slashes, dot segments, long-path, and UNC', () {
      expect(
        normalizeLocalPath(
          'C:/Media/Videos/../Audio/song, 1 & 2.mp3',
          isWindows: true,
        ),
        r'C:\Media\Audio\song, 1 & 2.mp3',
      );
      expect(
        normalizeLocalPath(
          '//server/share/Folder/Sub/../clip.mp4',
          isWindows: true,
        ),
        r'\\server\share\Folder\clip.mp4',
      );
      expect(
        normalizeLocalPath(r'\\?\C:\Users\Test\file.mkv', isWindows: true),
        r'C:\Users\Test\file.mkv',
      );
      expect(
        normalizeLocalPath(
          r'\\?\UNC\nas\media\folder\movie.mp4',
          isWindows: true,
        ),
        r'\\nas\media\folder\movie.mp4',
      );
      expect(
        normalizeLocalPath(r'C:\Media\Folder\', isWindows: true),
        r'C:\Media\Folder',
      );
      expect(normalizeLocalPath(r'C:\', isWindows: true), r'C:\');
      expect(normalizeLocalPath('C:', isWindows: true), r'C:\');
    });
  });

  group('showInFolder', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('mpvson_file_utils_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test(
      'returns false without invoking runner for empty or network URLs',
      () async {
        var called = false;
        Future<ProcessResult> runner(String exe, List<String> args) async {
          called = true;
          return ProcessResult(0, 0, '', '');
        }

        expect(await showInFolder('', processRunner: runner), isFalse);
        expect(await showInFolder('   ', processRunner: runner), isFalse);
        expect(
          await showInFolder(
            'https://example.com/a.mp4',
            processRunner: runner,
          ),
          isFalse,
        );
        expect(
          await showInFolder('rtsp://camera/stream', processRunner: runner),
          isFalse,
        );
        expect(called, isFalse);
      },
    );

    test(
      'reveals existing file with spaces, commas, and special chars',
      () async {
        final subDir = Directory(p.join(tempRoot.path, 'My Music, Vol & 1'))
          ..createSync();
        final file = File(p.join(subDir.path, "01 - Hello, World & 'Café'.mp3"))
          ..writeAsStringSync('audio');

        String? capturedExe;
        List<String>? capturedArgs;

        final ok = await showInFolder(
          file.path.replaceAll(r'\', '/'),
          processRunner: (exe, args) async {
            capturedExe = exe;
            capturedArgs = args;
            return ProcessResult(0, Platform.isWindows ? 1 : 0, '', '');
          },
        );

        expect(ok, isTrue);
        if (Platform.isWindows) {
          expect(capturedExe, 'explorer.exe');
          expect(capturedArgs, ['/select,${p.windows.normalize(file.path)}']);
        } else if (Platform.isMacOS) {
          expect(capturedExe, 'open');
          expect(capturedArgs, ['-R', file.path]);
        } else if (Platform.isLinux) {
          expect(capturedExe, 'xdg-open');
          expect(capturedArgs, [subDir.path]);
        }
      },
    );

    test(
      'normalizes file:// URI and \\\\?\\ prefix for existing file',
      () async {
        final file = File(p.join(tempRoot.path, 'sample, video.mp4'))
          ..writeAsStringSync('video');
        final fileUri = Uri.file(file.path).toString();

        List<String>? capturedArgs;
        final ok = await showInFolder(
          fileUri,
          processRunner: (exe, args) async {
            capturedArgs = args;
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(ok, isTrue);
        if (Platform.isWindows) {
          expect(capturedArgs, ['/select,${p.windows.normalize(file.path)}']);
        }

        if (Platform.isWindows) {
          List<String>? longPrefixArgs;
          final longOk = await showInFolder(
            '\\\\?\\${file.path}',
            processRunner: (exe, args) async {
              longPrefixArgs = args;
              return ProcessResult(0, 0, '', '');
            },
          );
          expect(longOk, isTrue);
          expect(longPrefixArgs, ['/select,${p.windows.normalize(file.path)}']);
        }
      },
    );

    test('opens existing directory directly without /select,', () async {
      final dir = Directory(p.join(tempRoot.path, 'Folder With, Space'))
        ..createSync();

      String? capturedExe;
      List<String>? capturedArgs;

      final ok = await showInFolder(
        '${dir.path}${Platform.pathSeparator}',
        processRunner: (exe, args) async {
          capturedExe = exe;
          capturedArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(ok, isTrue);
      if (Platform.isWindows) {
        expect(capturedExe, 'explorer.exe');
        expect(capturedArgs, [p.windows.normalize(dir.path)]);
      } else if (Platform.isMacOS) {
        expect(capturedExe, 'open');
        expect(capturedArgs, [dir.path]);
      } else if (Platform.isLinux) {
        expect(capturedExe, 'xdg-open');
        expect(capturedArgs, [dir.path]);
      }
    });

    test(
      'falls back to nearest existing parent directory when file is missing',
      () async {
        final existingParent = Directory(p.join(tempRoot.path, 'Existing, Dir'))
          ..createSync();
        final missingPath = p.join(
          existingParent.path,
          'missing_sub',
          'deleted_movie.mkv',
        );

        List<String>? capturedArgs;
        final ok = await showInFolder(
          missingPath,
          processRunner: (exe, args) async {
            capturedArgs = args;
            return ProcessResult(0, 0, '', '');
          },
        );

        expect(ok, isTrue);
        if (Platform.isWindows) {
          expect(capturedArgs, [p.windows.normalize(existingParent.path)]);
        } else {
          expect(capturedArgs, [existingParent.path]);
        }
      },
    );

    test('handles UNC/SMB paths for file and parent fallback', () async {
      if (!Platform.isWindows) return;

      const uncFile = r'\\nas-box\media\Movies, 2026\clip & test.mkv';
      const uncDir = r'\\nas-box\media\Movies, 2026';

      List<String>? fileArgs;
      final fileOk = await showInFolder(
        '//nas-box/media/Movies, 2026/clip & test.mkv',
        processRunner: (exe, args) async {
          fileArgs = args;
          return ProcessResult(0, 1, '', '');
        },
        entityTypeResolver: (path) async => path == uncFile
            ? FileSystemEntityType.file
            : FileSystemEntityType.notFound,
      );
      expect(fileOk, isTrue);
      expect(fileArgs, ['/select,$uncFile']);

      List<String>? fallbackArgs;
      final fallbackOk = await showInFolder(
        r'\\nas-box\media\Movies, 2026\missing\movie.mkv',
        processRunner: (exe, args) async {
          fallbackArgs = args;
          return ProcessResult(0, 1, '', '');
        },
        entityTypeResolver: (path) async => path == uncDir
            ? FileSystemEntityType.directory
            : FileSystemEntityType.notFound,
      );
      expect(fallbackOk, isTrue);
      expect(fallbackArgs, [uncDir]);

      var offlineCalled = false;
      final offlineOk = await showInFolder(
        r'\\offline-nas\share\movie.mkv',
        processRunner: (exe, args) async {
          offlineCalled = true;
          return ProcessResult(0, 0, '', '');
        },
        entityTypeResolver: (_) async => FileSystemEntityType.notFound,
      );
      expect(offlineOk, isFalse);
      expect(offlineCalled, isFalse);
    });

    test('returns false when runner fails or throws', () async {
      final file = File(p.join(tempRoot.path, 'video.mp4'))
        ..writeAsStringSync('v');

      final badExit = await showInFolder(
        file.path,
        processRunner: (exe, args) async => ProcessResult(0, 2, '', 'err'),
      );
      expect(badExit, isFalse);

      final threw = await showInFolder(
        file.path,
        processRunner: (exe, args) async =>
            throw const ProcessException('e', []),
      );
      expect(threw, isFalse);
    });
  });
}
