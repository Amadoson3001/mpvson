import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/utils/file_utils.dart';

class _FakeRunner {
  _FakeRunner({this._exitCode = 0, this._throwOnCall = false});

  final List<({String executable, List<String> arguments})> calls = [];
  final int _exitCode;
  final bool _throwOnCall;

  ProcessRunner get run => (executable, arguments) async {
    calls.add((executable: executable, arguments: arguments));
    if (_throwOnCall) {
      throw const FileSystemException('launcher unavailable');
    }
    return ProcessResult(0, _exitCode, '', '');
  };

  bool get neverCalled => calls.isEmpty;
}

void main() {
  group('showInFolder (fake process runner)', () {
    test('empty path returns false without launching anything', () async {
      final runner = _FakeRunner();
      expect(await showInFolder('', processRunner: runner.run), isFalse);
      expect(runner.neverCalled, isTrue);
    });

    test(
      'whitespace-only path returns false without launching anything',
      () async {
        final runner = _FakeRunner();
        expect(await showInFolder('   ', processRunner: runner.run), isFalse);
        expect(runner.neverCalled, isTrue);
      },
    );

    test('runner failure is swallowed and reported as false', () async {
      final runner = _FakeRunner(throwOnCall: true);
      expect(
        await showInFolder(r'C:\media\clip.mkv', processRunner: runner.run),
        isFalse,
      );
      expect(runner.calls, hasLength(1));
    });

    test(
      'windows reveal passes /select,<path> as a single argument',
      skip: Platform.isWindows ? false : 'Windows-only behavior',
      () async {
        final runner = _FakeRunner();
        final result = await showInFolder(
          r'C:\media folder\clip.mkv',
          processRunner: runner.run,
        );

        expect(result, isTrue);
        expect(runner.calls, hasLength(1));
        expect(runner.calls.single.executable, 'explorer.exe');
        expect(runner.calls.single.arguments, <String>[
          r'/select,C:\media folder\clip.mkv',
        ]);
        expect(
          runner.calls.single.arguments.single.contains(','),
          isTrue,
          reason: 'the select verb and path must be one argument',
        );
      },
    );

    test(
      'windows normalizes forward slashes before invoking explorer',
      skip: Platform.isWindows ? false : 'Windows-only behavior',
      () async {
        final runner = _FakeRunner();
        await showInFolder(
          'C:/media folder/clip.mkv',
          processRunner: runner.run,
        );
        expect(runner.calls.single.arguments, <String>[
          r'/select,C:\media folder\clip.mkv',
        ]);
      },
    );

    test(
      'windows exit code 1 still counts as revealed',
      skip: Platform.isWindows ? false : 'Windows-only behavior',
      () async {
        final runner = _FakeRunner(exitCode: 1);
        expect(
          await showInFolder(r'C:\media\clip.mkv', processRunner: runner.run),
          isTrue,
        );
      },
    );

    test(
      'windows exit code 2 is reported as failure',
      skip: Platform.isWindows ? false : 'Windows-only behavior',
      () async {
        final runner = _FakeRunner(exitCode: 2);
        expect(
          await showInFolder(r'C:\media\clip.mkv', processRunner: runner.run),
          isFalse,
        );
      },
    );

    test(
      'macos reveal calls open -R with the path',
      skip: Platform.isMacOS ? false : 'macOS-only behavior',
      () async {
        final runner = _FakeRunner();
        final result = await showInFolder(
          '/media/clip.mkv',
          processRunner: runner.run,
        );

        expect(result, isTrue);
        expect(runner.calls.single.executable, 'open');
        expect(runner.calls.single.arguments, <String>[
          '-R',
          '/media/clip.mkv',
        ]);
      },
    );

    test(
      'linux reveal calls xdg-open on the parent directory',
      skip: Platform.isLinux ? false : 'Linux-only behavior',
      () async {
        final runner = _FakeRunner();
        final result = await showInFolder(
          '/media/clip.mkv',
          processRunner: runner.run,
        );

        expect(result, isTrue);
        expect(runner.calls.single.executable, 'xdg-open');
        expect(runner.calls.single.arguments, <String>['/media']);
      },
    );

    test(
      'unsupported platform returns false without launching anything',
      () async {
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          return;
        }
        final runner = _FakeRunner();
        expect(await showInFolder('/x', processRunner: runner.run), isFalse);
        expect(runner.neverCalled, isTrue);
      },
    );
  });
}
