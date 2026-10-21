import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:path/path.dart' as p;

import '../../tool/windows_associations.dart';

void main() {
  group('Windows Associations & MediaCatalog Alignment', () {
    test('MediaCatalog formats match expected audio and video counts', () {
      expect(MediaCatalog.audioExtensions, containsAll(<String>[
        'mp3',
        'flac',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'oga',
        'opus',
        'wma',
        'aiff',
        'aif',
        'ape',
      ]));

      expect(MediaCatalog.videoExtensions, containsAll(<String>[
        'mp4',
        'mkv',
        'avi',
        'webm',
        'mov',
        'flv',
        'wmv',
        'm4v',
        'ts',
        'm2ts',
        'vob',
        'ogv',
        '3gp',
      ]));

      expect(MediaCatalog.supportedExtensions.length, 25);
    });

    test('Inno Setup script installer.iss contains all required specs and formats', () {
      final issFile = File('packaging/windows/installer.iss');
      expect(issFile.existsSync(), isTrue, reason: 'installer.iss must exist');

      final content = issFile.readAsStringSync();

      // Privileges and target directory
      expect(content, contains('PrivilegesRequired=lowest'));
      expect(content, contains(r'DefaultDirName={localappdata}\Programs\{#MyAppName}'));
      expect(content, contains(r'build\windows\x64\runner\Release\*'));

      // Shortcuts
      expect(content, contains(r'Name: "{autoprograms}\{#MyAppName}"'));
      expect(content, contains(r'Name: "{autodesktop}\{#MyAppName}"'));

      // ProgID & Commands
      expect(content, contains(r'Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}"'));
      expect(content, contains(r'"{app}\{#MyAppExeName}"" ""%1"""'));
      expect(content, contains(r'"{app}\{#MyAppExeName}"" --enqueue ""%1"""'));

      // Registered Applications
      expect(content, contains(r'Root: HKCU; Subkey: "Software\RegisteredApplications"'));
      expect(content, contains(r'Software\{#MyAppName}\Capabilities'));

      // Clean uninstall flags
      expect(content, contains('Flags: uninsdeletekey'));
      expect(content, contains('Flags: uninsdeletevalue'));
      expect(content, contains('Flags: uninsdeletekeyifempty'));

      // Verify every single extension from MediaCatalog is included in installer.iss
      for (final ext in MediaCatalog.supportedExtensions) {
        expect(
          content,
          contains('ValueName: ".$ext"'),
          reason: 'installer.iss must register .$ext in FileAssociations',
        );
        expect(
          content,
          contains(r'Subkey: "Software\Classes\.' + ext + r'\OpenWithProgids"'),
          reason: 'installer.iss must register .$ext in OpenWithProgids',
        );
      }

      // Verify MIME associations from MediaCatalog are included
      for (final mime in MediaCatalog.extensionToMimeType.values) {
        expect(
          content,
          contains('ValueName: "$mime"'),
          reason: 'installer.iss must register $mime in MIMEAssociations',
        );
      }
    });

    test('Portable batch scripts match MediaCatalog formats and safe registration', () {
      final registerBat = File('packaging/windows/register_portable.bat');
      final unregisterBat = File('packaging/windows/unregister_portable.bat');

      expect(registerBat.existsSync(), isTrue);
      expect(unregisterBat.existsSync(), isTrue);

      final regContent = registerBat.readAsStringSync();
      final unregContent = unregisterBat.readAsStringSync();

      // Ensure open and enqueue commands are present
      expect(regContent, contains('--enqueue'));
      expect(regContent, contains('Mpvson.AssocFile'));
      expect(regContent, contains('Software\\Mpvson\\Capabilities'));
      expect(regContent, contains('Software\\RegisteredApplications'));

      // Ensure protection against overwriting other installs is present
      expect(regContent, contains('Registration aborted'));
      expect(unregContent, contains('Unregistration aborted'));

      // Ensure all extensions from MediaCatalog are covered in batch scripts
      for (final ext in MediaCatalog.supportedExtensions) {
        expect(
          regContent,
          contains("'$ext'"),
          reason: 'register_portable.bat must include $ext',
        );
        expect(
          unregContent,
          contains("'$ext'"),
          reason: 'unregister_portable.bat must include $ext',
        );
      }
    });

    test('findTargetExecutable finds existing release binary or accepts override', () {
      final repoRoot = Directory.current.path;
      final releaseExe = p.join(
        repoRoot,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'mpvson.exe',
      );

      if (File(releaseExe).existsSync()) {
        final found = findTargetExecutable();
        expect(found, isNotNull);
        expect(found!.toLowerCase(), equals(p.canonicalize(releaseExe).toLowerCase()));

        final foundOverride = findTargetExecutable(overridePath: releaseExe);
        expect(
          foundOverride!.toLowerCase(),
          equals(p.canonicalize(releaseExe).toLowerCase()),
        );
      }
    });

    test('dry-run registration and unregistration complete successfully without mutating system', () async {
      final repoRoot = Directory.current.path;
      final releaseExe = p.join(
        repoRoot,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'mpvson.exe',
      );

      final registered = await registerAssociations(
        targetExe: releaseExe,
        force: true,
        dryRun: true,
        verbose: false,
      );
      expect(registered, isTrue);

      final unregistered = await unregisterAssociations(
        targetExe: releaseExe,
        force: true,
        dryRun: true,
        verbose: false,
      );
      expect(unregistered, isTrue);
    });
  });
}
