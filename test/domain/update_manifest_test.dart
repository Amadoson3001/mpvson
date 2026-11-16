import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';

void main() {
  const validHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  String encodeManifest({
    int schemaVersion = 1,
    String version = '0.2.0',
    String engineVersion = '0.42.0',
    String windowsUrl = 'https://example.org/mpvson-windows-x64.zip',
    String windowsHash = validHash,
    String linuxUrl = 'https://example.org/mpvson-linux-x64.tar.gz',
    String linuxHash = validHash,
    String? releaseUrl = 'https://example.org/releases/0.2.0',
  }) {
    return jsonEncode(<String, Object?>{
      'schemaVersion': schemaVersion,
      'version': version,
      'notes': 'Bug fixes',
      'engineVersion': engineVersion,
      'releaseUrl': ?releaseUrl,
      'artifacts': <String, Object?>{
        'windows': <String, Object?>{'url': windowsUrl, 'sha256': windowsHash},
        'linux': <String, Object?>{'url': linuxUrl, 'sha256': linuxHash},
      },
    });
  }

  group('SemanticVersion', () {
    test('compares core, prerelease, and build metadata per SemVer 2.0.0', () {
      final alpha = SemanticVersion.parse('1.0.0-alpha.1+build.5');
      final beta = SemanticVersion.parse('1.0.0-beta');
      final stable = SemanticVersion.parse('1.0.0+99');
      final stableSame = SemanticVersion.parse('1.0.0+1');

      expect(alpha.compareTo(beta), lessThan(0));
      expect(beta.compareTo(stable), lessThan(0));
      expect(stable.compareTo(stableSame), 0);
    });

    test('rejects leading zeroes in prerelease numbers', () {
      expect(() => SemanticVersion.parse('1.0.0-01'), throwsFormatException);
    });
  });

  group('UpdateManifest', () {
    test('parses valid Windows and Linux release entries', () {
      final raw = encodeManifest(windowsHash: validHash.toUpperCase());
      final win = UpdateManifest.parse(raw, platform: UpdatePlatform.windows);
      final linux = UpdateManifest.parse(raw, platform: UpdatePlatform.linux);

      expect(win.release.version, '0.2.0');
      expect(win.release.engineVersion, '0.42.0');
      expect(win.release.sha256, validHash);
      expect(
        win.release.downloadUri.toString(),
        'https://example.org/mpvson-windows-x64.zip',
      );
      expect(
        linux.release.downloadUri.toString(),
        'https://example.org/mpvson-linux-x64.tar.gz',
      );
    });

    test('rejects non-HTTPS URLs, embedded credentials, and bad SHA-256', () {
      expect(
        () => UpdateManifest.parse(
          encodeManifest(windowsUrl: 'http://example.org/app.zip'),
          platform: UpdatePlatform.windows,
        ),
        throwsFormatException,
      );
      expect(
        () => UpdateManifest.parse(
          encodeManifest(windowsUrl: 'https://user:pass@example.org/app.zip'),
          platform: UpdatePlatform.windows,
        ),
        throwsFormatException,
      );
      expect(
        () => UpdateManifest.parse(
          encodeManifest(windowsHash: 'not-a-hash'),
          platform: UpdatePlatform.windows,
        ),
        throwsFormatException,
      );
      expect(
        () => UpdateManifest.parse(
          encodeManifest(schemaVersion: 2),
          platform: UpdatePlatform.windows,
        ),
        throwsFormatException,
      );
    });
  });
}
