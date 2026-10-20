import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

// Opt-in probe. It proves that the module shipped next to the application is
// the engine pinned in packaging/windows/engine-provenance.json, and records the
// component versions that engine reports about itself so the provenance record
// can cite real output instead of assumptions. Run after building the Windows
// release:
//   flutter build windows --release
//   flutter test --dart-define=MPVSON_PROBE_ENGINE_INVENTORY=true \
//     test/native_engine_inventory_probe_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'records the bundled engine identity and component inventory',
    () async {
      final dll = File(
        p.normalize(
          p.absolute('build/windows/x64/runner/Release/libmpv-2.dll'),
        ),
      );
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Build the Windows release before running this probe.',
      );

      final recordFile = File(
        p.join('packaging', 'windows', 'engine-provenance.json'),
      );
      final record =
          jsonDecode(recordFile.readAsStringSync()) as Map<String, Object?>;
      final engine = record['engine']! as Map<String, Object?>;
      final artifact = record['artifact']! as Map<String, Object?>;

      final digest = sha256.convert(dll.readAsBytesSync()).toString();
      expect(
        digest,
        artifact['memberSha256'],
        reason: 'The bundled module is not the engine this build pinned.',
      );
      expect(dll.lengthSync(), artifact['memberSize']);

      MediaKit.ensureInitialized(libmpv: Platform.isWindows ? dll.path : null);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final platform = player.platform! as NativePlayer;

      Future<String?> readProperty(String name) async {
        try {
          final value =
              (await platform
                      .getProperty(name)
                      .timeout(const Duration(seconds: 5)))
                  .trim();
          return value.isEmpty ? null : value;
        } on Object {
          return null;
        }
      }

      final properties = <String, String?>{};
      for (final name in const <String>[
        'mpv-version',
        'mpv-configuration',
        'ffmpeg-version',
        'libass-version',
        'platform',
      ]) {
        properties[name] = await readProperty(name);
      }

      final mpvVersion = properties['mpv-version'];
      final engineVersion = engine['version']! as String;
      expect(
        mpvVersion,
        isNotNull,
        reason: 'The bundled engine must report mpv-version.',
      );
      expect(
        mpvVersion!,
        contains(engineVersion),
        reason: 'The running engine is not the pinned $engineVersion.',
      );
      expect(
        engine['commit'],
        startsWith(engineVersion.split('g').last),
        reason:
            'mpv reports the abbreviated commit in its version string, so the '
            'pinned full commit must start with it.',
      );
      expect(
        properties['ffmpeg-version'],
        isNotNull,
        reason: 'The bundled engine must report its FFmpeg build.',
      );
      expect(properties['mpv-configuration'], isNotNull);

      final inventory = <String, Object?>{
        'schemaVersion': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'module': <String, Object?>{
          'path': p.relative(dll.path, from: p.current),
          'size': dll.lengthSync(),
          'sha256': digest,
          'matchesPinnedRecord': true,
        },
        'engine': engine,
        'artifact': artifact,
        'reportedProperties': properties,
      };
      final out = File(p.absolute('test-output/engine-inventory.json'));
      await out.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
        flush: true,
      );

      // The report is also printed so the evidence survives in run logs.
      // ignore: avoid_print
      print('Bundled engine: $mpvVersion');
      // ignore: avoid_print
      print('FFmpeg: ${properties['ffmpeg-version']}');
      // ignore: avoid_print
      print('libass: ${properties['libass-version']}');
      // ignore: avoid_print
      print('Configuration: ${properties['mpv-configuration']}');
      // ignore: avoid_print
      print('Inventory written to ${out.path}');

      await player.dispose();
    },
    skip: !const bool.fromEnvironment('MPVSON_PROBE_ENGINE_INVENTORY'),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
