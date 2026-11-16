import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/windows_associations_core.dart';
import 'package:mpvson/domain/models/graphics_settings.dart';
import 'package:mpvson/domain/models/media_catalog.dart';

void main() {
  group('Windows 10 & 11 compatibility', () {
    test('detects Windows 10 vs Windows 11 build numbers accurately', () {
      final win10 = parseWindowsBuildNumber(
        '"Windows 10 Pro" 10.0 (Build 19045)',
      );
      final win10Alt = parseWindowsBuildNumber('10.0.19045');
      final win11 = parseWindowsBuildNumber(
        '"Windows 11 Home" 10.0 (Build 22631)',
      );
      final win11_24h2 = parseWindowsBuildNumber('10.0.26100');

      expect(win10, 19045);
      expect(isWindows11Build(win10), isFalse);
      expect(win10Alt, 19045);
      expect(isWindows11Build(win10Alt), isFalse);
      expect(win11, 22631);
      expect(isWindows11Build(win11), isTrue);
      expect(win11_24h2, 26100);
      expect(isWindows11Build(win11_24h2), isTrue);
    });

    test(
      'installer.iss and portable scripts cover all MediaCatalog formats',
      () {
        final iss = File('packaging/windows/installer.iss').readAsStringSync();
        final regBat = File(
          'packaging/windows/register_portable.bat',
        ).readAsStringSync();
        final unregBat = File(
          'packaging/windows/unregister_portable.bat',
        ).readAsStringSync();

        for (final ext in MediaCatalog.supportedExtensions) {
          expect(
            iss,
            contains('ValueName: ".$ext"'),
            reason: 'installer.iss missing .$ext association',
          );
          expect(
            iss,
            contains('Software\\Classes\\.$ext\\OpenWithProgids'),
            reason: 'installer.iss missing .$ext OpenWithProgids',
          );
          expect(
            regBat,
            contains("'$ext'"),
            reason: 'register_portable.bat missing $ext',
          );
          expect(
            unregBat,
            contains("'$ext'"),
            reason: 'unregister_portable.bat missing $ext',
          );
        }

        for (final mime in MediaCatalog.extensionToMimeType.values.toSet()) {
          expect(
            iss,
            contains('ValueName: "$mime"'),
            reason: 'installer.iss missing MIME $mime',
          );
          expect(
            regBat,
            contains("'$mime'"),
            reason: 'register_portable.bat missing MIME $mime',
          );
        }
      },
    );

    test('default GraphicsSettings use AC/battery automatic GPU mode', () {
      const defaults = GraphicsSettings.defaults;
      expect(defaults.preferredGpu, GpuPreferenceMode.automatic);
      expect(
        defaults.resolvePreferredGpu(onAcPower: true),
        GpuPreferenceMode.highPerformance,
      );
      expect(
        defaults.resolvePreferredGpu(onAcPower: false),
        GpuPreferenceMode.powerSaving,
      );
    });
  });
}
