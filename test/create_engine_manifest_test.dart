import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/engine_release.dart';
import 'package:path/path.dart' as p;

import '../tool/create_engine_manifest.dart';

void main() {
  group('createEngineManifest', () {
    test(
      'is deterministic and verifies against canonical payload bytes',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mpvson-engine-manifest-test-',
        );
        addTearDown(() => directory.delete(recursive: true));

        final engineZip = File(p.join(directory.path, 'engine.zip'));
        final signingKey = File(p.join(directory.path, 'signing-key.seed'));
        await engineZip.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('libmpv-2.dll', <int>[1, 2, 3, 4]),
            ArchiveFile.bytes('avcodec-61.dll', <int>[5, 6]),
          ]),
        );
        final seed = List<int>.generate(32, (index) => index);
        await signingKey.writeAsBytes(seed);

        final first = await createEngineManifest(
          engineZip: engineZip,
          engineUri: Uri.parse(
            'https://downloads.example.org/engine/0.40.0/windows-x64.zip',
          ),
          engineVersion: '0.40.0',
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '0.1.0',
          maximumAppVersionExclusive: '1.0.0',
          notes: 'Engine update notes.',
          signingKeyFile: signingKey,
        );
        final second = await createEngineManifest(
          engineZip: engineZip,
          engineUri: Uri.parse(
            'https://downloads.example.org/engine/0.40.0/windows-x64.zip',
          ),
          engineVersion: '0.40.0',
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '0.1.0',
          maximumAppVersionExclusive: '1.0.0',
          notes: 'Engine update notes.',
          signingKeyFile: signingKey,
        );

        expect(jsonEncode(first), jsonEncode(second));
        expect(first.keys.toList(), <String>[
          'schemaVersion',
          'payload',
          'signature',
        ]);
        expect(first['schemaVersion'], 1);
        final parsed = EngineUpdateManifest.parse(
          encodeAndValidateEngineManifest(first),
        );
        expect(parsed.release.engineVersion, '0.40.0');

        final payload = first['payload']! as Map<String, Object?>;
        final artifact =
            (payload['artifacts']! as Map<String, Object?>)['windows']!
                as Map<String, Object?>;
        expect(payload['engineVersion'], '0.40.0');
        expect(payload['mediaKitVersion'], '1.2.6');
        expect(payload['minimumAppVersion'], '0.1.0');
        expect(payload['maximumAppVersionExclusive'], '1.0.0');
        expect(artifact['size'], await engineZip.length());
        expect(artifact['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));

        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPairFromSeed(seed);
        final publicKey = await keyPair.extractPublicKey();
        final signatureBytes = base64Decode(first['signature']! as String);
        final signature = Signature(signatureBytes, publicKey: publicKey);
        expect(
          await algorithm.verify(
            _canonicalBytes(payload),
            signature: signature,
          ),
          isTrue,
        );

        final tamperedPayload = Map<String, Object?>.of(payload)
          ..['notes'] = 'Changed after signing.';
        expect(
          await algorithm.verify(
            _canonicalBytes(tamperedPayload),
            signature: signature,
          ),
          isFalse,
        );
      },
    );

    test(
      'rejects invalid SemVer, insecure URLs, and inverted app bounds',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mpvson-engine-manifest-input-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engineZip = File(p.join(directory.path, 'engine.zip'));
        final signingKey = File(p.join(directory.path, 'key.seed'));
        await engineZip.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('libmpv-2.dll', <int>[1]),
          ]),
        );
        await signingKey.writeAsBytes(List<int>.filled(32, 9));

        Future<Map<String, Object?>> generate({
          String engineVersion = '0.40.0',
          Uri? url,
          String maximumAppVersionExclusive = '1.0.0',
          String notes = '',
          File? outputFile,
        }) => createEngineManifest(
          engineZip: engineZip,
          engineUri: url ?? Uri.parse('https://example.org/engine.zip'),
          engineVersion: engineVersion,
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '0.1.0',
          maximumAppVersionExclusive: maximumAppVersionExclusive,
          notes: notes,
          signingKeyFile: signingKey,
          outputFile: outputFile,
        );

        await expectLater(
          generate(engineVersion: '0.40'),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          generate(url: Uri.parse('http://example.org/engine.zip')),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          generate(maximumAppVersionExclusive: '0.1.0'),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          generate(notes: List<String>.filled(80 * 1024 + 1, 'n').join()),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          generate(
            url: Uri.parse(
              'https://example.org/${List<String>.filled(4090, 'a').join()}',
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'rejects a UTF-8 manifest over the download limit before writing',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mpvson-engine-manifest-size-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engineZip = File(p.join(directory.path, 'engine.zip'));
        final signingKey = File(p.join(directory.path, 'key.seed'));
        final output = File(p.join(directory.path, 'manifest.json'));
        await engineZip.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('libmpv-2.dll', <int>[1]),
          ]),
        );
        await signingKey.writeAsBytes(List<int>.filled(32, 9));

        await expectLater(
          createEngineManifest(
            engineZip: engineZip,
            engineUri: Uri.parse('https://example.org/engine.zip'),
            engineVersion: '0.40.0',
            mediaKitVersion: '1.2.6',
            minimumAppVersion: '0.1.0',
            notes: List<String>.filled(44 * 1024, '\u0001').join(),
            signingKeyFile: signingKey,
            outputFile: output,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await output.exists(), isFalse);
      },
    );

    test(
      'requires the libmpv DLL at ZIP root and rejects unsafe entries',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mpvson-engine-manifest-zip-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final missingDll = File(p.join(directory.path, 'missing.zip'));
        await missingDll.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('readme.txt', <int>[1]),
            ArchiveFile.bytes('bin/libmpv-2.dll', <int>[2]),
          ]),
        );
        await expectLater(
          validateEngineArchive(missingDll),
          throwsA(isA<FormatException>()),
        );

        final wrongDllCasing = File(p.join(directory.path, 'wrong-case.zip'));
        await wrongDllCasing.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('LIBMPV-2.DLL', <int>[1]),
          ]),
        );
        await expectLater(
          validateEngineArchive(wrongDllCasing),
          throwsA(isA<FormatException>()),
        );

        final mismatchedNames = File(
          p.join(directory.path, 'mismatched-local-name.zip'),
        );
        await mismatchedNames.writeAsBytes(_zipWithMismatchedLocalName());
        await expectLater(
          validateEngineArchive(mismatchedNames),
          throwsA(isA<FormatException>()),
        );

        final oversizedSymlink = File(
          p.join(directory.path, 'oversized-symlink.zip'),
        );
        await oversizedSymlink.writeAsBytes(_zipWithOversizedSymlink());
        await expectLater(
          validateEngineArchive(oversizedSymlink),
          throwsA(isA<FormatException>()),
        );

        final unsafe = File(p.join(directory.path, 'unsafe.zip'));
        await unsafe.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('libmpv-2.dll', <int>[1]),
            ArchiveFile.bytes('../outside.txt', <int>[2]),
          ]),
        );
        await expectLater(
          validateEngineArchive(unsafe),
          throwsA(isA<FormatException>()),
        );

        final emptyDll = File(p.join(directory.path, 'empty-dll.zip'));
        await emptyDll.writeAsBytes(
          _zipWithEntries(<ArchiveFile>[
            ArchiveFile.bytes('libmpv-2.dll', const <int>[]),
          ]),
        );
        await expectLater(
          validateEngineArchive(emptyDll),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'rejects output collisions with the ZIP, signing key, and notes file',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mpvson-engine-manifest-collision-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final engineZip = File(p.join(directory.path, 'engine.zip'));
        final signingKey = File(p.join(directory.path, 'key.seed'));
        final notesFile = File(p.join(directory.path, 'notes.txt'));
        await engineZip.writeAsBytes(<int>[1]);
        await signingKey.writeAsBytes(List<int>.filled(32, 7));
        await notesFile.writeAsString('notes');
        final nestedDirectory = Directory(p.join(directory.path, 'nested'));
        await nestedDirectory.create();

        for (final input in <File>[engineZip, signingKey, notesFile]) {
          await expectLater(
            validateEngineManifestOutput(
              outputFile: File(input.path),
              inputFiles: <File>[engineZip, signingKey, notesFile],
            ),
            throwsA(
              isA<FileSystemException>().having(
                (error) => error.message,
                'message',
                contains('collides with an input file'),
              ),
            ),
          );
        }

        await expectLater(
          validateEngineManifestOutput(
            outputFile: File(p.join(nestedDirectory.path, '..', 'engine.zip')),
            inputFiles: <File>[engineZip, signingKey, notesFile],
          ),
          throwsA(isA<FileSystemException>()),
        );
      },
    );
  });

  group('parseEngineManifestArguments', () {
    test('rejects unknown, duplicate, incomplete, and conflicting options', () {
      expect(
        () => parseEngineManifestArguments(const <String>[]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseEngineManifestArguments(<String>['--unknown', 'value']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseEngineManifestArguments(<String>[
          '--engine-url',
          'one',
          '--engine-url',
          'two',
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseEngineManifestArguments(<String>['--engine-url']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseEngineManifestArguments(<String>[
          '--notes',
          'inline',
          '--notes-file',
          'notes.txt',
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

List<int> _zipWithEntries(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return ZipEncoder().encode(archive);
}

List<int> _zipWithMismatchedLocalName() {
  final bytes = List<int>.of(
    _zipWithEntries(<ArchiveFile>[
      ArchiveFile.bytes('libmpv-2.dll', <int>[1]),
    ]),
  );
  const filename = 'libmpv-2.dll';
  bytes[30 + filename.length - 1] = 'q'.codeUnitAt(0);
  return bytes;
}

List<int> _zipWithOversizedSymlink() {
  final link = ArchiveFile.bytes('engine-link', utf8.encode('libmpv-2.dll'))
    ..mode = 0xa1ff;
  final bytes = List<int>.of(
    _zipWithEntries(<ArchiveFile>[
      ArchiveFile.bytes('libmpv-2.dll', <int>[1]),
      link,
    ]),
  );
  const centralDirectorySignature = 0x02014b50;
  const filenameOffset = 46;
  const uncompressedSizeOffset = 24;
  const versionMadeByOffset = 4;
  const wantedName = 'engine-link';
  final oversizedLength = maxEngineZipUncompressedBytes + 1;
  var patched = false;

  for (var offset = 0; offset + filenameOffset <= bytes.length; offset++) {
    final signature =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    if (signature != centralDirectorySignature) continue;
    final filenameLength = bytes[offset + 28] | (bytes[offset + 29] << 8);
    final filenameEnd = offset + filenameOffset + filenameLength;
    if (filenameEnd > bytes.length) continue;
    final filename = ascii.decode(
      bytes.sublist(offset + filenameOffset, filenameEnd),
    );
    if (filename != wantedName) continue;

    // Mark the entry as Unix-created so its mode is interpreted as symlink.
    bytes[offset + versionMadeByOffset] = 20;
    bytes[offset + versionMadeByOffset + 1] = 3;
    for (var index = 0; index < 4; index++) {
      bytes[offset + uncompressedSizeOffset + index] =
          (oversizedLength >> (8 * index)) & 0xff;
    }
    patched = true;
    break;
  }

  if (!patched) {
    throw StateError('Could not locate the test ZIP central directory entry.');
  }
  return bytes;
}

List<int> _canonicalBytes(Object? value) =>
    utf8.encode(jsonEncode(_sortJson(value)));

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortJson(value[key]),
    };
  }
  if (value is List) return value.map(_sortJson).toList(growable: false);
  return value;
}
