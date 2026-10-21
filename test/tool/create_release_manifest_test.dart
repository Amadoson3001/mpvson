import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:path/path.dart' as p;
import '../../tool/create_release_manifest.dart';

void main() {
  test(
    'generates target hashes that the app manifest parser accepts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson-manifest-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final windowsFile = File(
        '${directory.path}${Platform.pathSeparator}app.zip',
      );
      final linuxFile = File(
        '${directory.path}${Platform.pathSeparator}app.tar.gz',
      );
      await windowsFile.writeAsBytes([1, 2, 3, 4]);
      await linuxFile.writeAsBytes([5, 6, 7, 8]);

      final generated = await createReleaseManifest(
        version: '1.2.0-rc.1',
        engineVersion: '0.40.0',
        notes: 'Candidate release',
        releaseUri: Uri.parse('https://example.org/releases/1.2.0-rc.1'),
        windowsFile: windowsFile,
        windowsUri: Uri.parse('https://example.org/app.zip'),
        linuxFile: linuxFile,
        linuxUri: Uri.parse('https://example.org/app.tar.gz'),
      );

      final windows = UpdateManifest.parse(
        _encode(generated),
        platform: UpdatePlatform.windows,
      );
      final linux = UpdateManifest.parse(
        _encode(generated),
        platform: UpdatePlatform.linux,
      );
      expect(windows.release.sha256, isNot(linux.release.sha256));
      expect(windows.release.version, '1.2.0-rc.1');
      expect(generated['schemaVersion'], 1);
    },
  );

  test(
    'prevents output from colliding with Windows or Linux release artifacts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson-manifest-collision-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final windowsFile = File(p.join(directory.path, 'app.zip'));
      final linuxFile = File(p.join(directory.path, 'app.tar.gz'));
      await windowsFile.writeAsBytes([1, 2, 3]);
      await linuxFile.writeAsBytes([4, 5, 6]);

      // Exact output match
      expect(
        () => validateManifestOutput(
          outputFile: windowsFile,
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('collides with the Windows release artifact'),
          ),
        ),
      );

      expect(
        () => validateManifestOutput(
          outputFile: linuxFile,
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('collides with the Linux release artifact'),
          ),
        ),
      );

      // Equivalent path (dot dot navigation and case variations)
      final equivalentWindows = File(
        p.join(directory.path, 'sub', '..', 'app.zip'),
      );
      expect(
        () => validateManifestOutput(
          outputFile: equivalentWindows,
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        throwsA(isA<FileSystemException>()),
      );

      final equivalentLinux = File(p.join(directory.path, '.', 'app.tar.gz'));
      expect(
        () => validateManifestOutput(
          outputFile: equivalentLinux,
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        throwsA(isA<FileSystemException>()),
      );

      // Distinct output path succeeds
      final validOutput = File(p.join(directory.path, 'manifest.json'));
      await expectLater(
        validateManifestOutput(
          outputFile: validOutput,
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        completes,
      );
    },
  );

  test('prevents output collision through symbolic link aliases', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mpvson-manifest-symlink-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final windowsFile = File(p.join(directory.path, 'app.zip'));
    final linuxFile = File(p.join(directory.path, 'app.tar.gz'));
    await windowsFile.writeAsBytes([1, 2, 3]);
    await linuxFile.writeAsBytes([4, 5, 6]);

    try {
      final symlink = Link(p.join(directory.path, 'manifest-alias.json'));
      await symlink.create(windowsFile.path);

      expect(
        () => validateManifestOutput(
          outputFile: File(symlink.path),
          windowsFile: windowsFile,
          linuxFile: linuxFile,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('Windows release artifact'),
          ),
        ),
      );
    } on FileSystemException {
      // Skip if OS privilege restricts symlink creation in the test environment
    }
  });

  test('writes manifest atomically without leaving temporary files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mpvson-manifest-atomic-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final outputFile = File(p.join(directory.path, 'release-manifest.json'));
    final manifestData = {
      'schemaVersion': 1,
      'version': '1.0.0',
      'notes': 'Atomic write test',
    };

    await writeManifestAtomically(outputFile, manifestData);

    expect(await outputFile.exists(), isTrue);
    final decoded = jsonDecode(await outputFile.readAsString());
    expect(decoded['version'], '1.0.0');

    // Confirm no .tmp files were left behind in the directory
    final entries = await directory.list().toList();
    final tempEntries = entries.where(
      (e) => p.basename(e.path).endsWith('.tmp'),
    );
    expect(tempEntries, isEmpty);

    // Overwriting existing file atomically also succeeds cleanly
    manifestData['version'] = '1.0.1';
    await writeManifestAtomically(outputFile, manifestData);
    final updated = jsonDecode(await outputFile.readAsString());
    expect(updated['version'], '1.0.1');

    final updatedEntries = await directory.list().toList();
    expect(
      updatedEntries.where((e) => p.basename(e.path).endsWith('.tmp')),
      isEmpty,
    );
  });

  test('rejects a non-SemVer engine version', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mpvson-manifest-engine-version-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final windowsFile = File(p.join(directory.path, 'app.zip'));
    final linuxFile = File(p.join(directory.path, 'app.tar.gz'));
    await windowsFile.writeAsBytes(<int>[1, 2, 3, 4]);
    await linuxFile.writeAsBytes(<int>[5, 6, 7, 8]);

    await expectLater(
      createReleaseManifest(
        version: '1.2.0',
        engineVersion: 'latest',
        notes: '',
        releaseUri: Uri.parse('https://example.org/releases/1.2.0'),
        windowsFile: windowsFile,
        windowsUri: Uri.parse('https://example.org/app.zip'),
        linuxFile: linuxFile,
        linuxUri: Uri.parse('https://example.org/app.tar.gz'),
      ),
      throwsFormatException,
    );
  });
}

String _encode(Map<String, Object?> manifest) {
  return jsonEncode(manifest);
}
