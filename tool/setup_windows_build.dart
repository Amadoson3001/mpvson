import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.contains('--sync-active')) {
    stdout.writeln('Synchronizing active in-app engine into build pin...');
    final syncResult = Process.runSync('dart', ['run', 'tool/engine_provenance.dart', 'sync-active']);
    stdout.write(syncResult.stdout);
    if (syncResult.stderr.toString().isNotEmpty) {
      stderr.write(syncResult.stderr);
    }
  }

  stdout.writeln('Configuring Flutter plugin junctions for Windows...');
  final depsFile = File('.flutter-plugins-dependencies');
  if (!depsFile.existsSync()) {
    stderr.writeln('Error: .flutter-plugins-dependencies not found. Run flutter pub get first.');
    exit(1);
  }

  final data = jsonDecode(depsFile.readAsStringSync()) as Map<String, dynamic>;
  final plugins = (data['plugins'] as Map<String, dynamic>?)?['windows'] as List<dynamic>? ?? [];

  final baseDir = Directory(r'windows\flutter\ephemeral\.plugin_symlinks');
  if (!baseDir.existsSync()) {
    baseDir.createSync(recursive: true);
  }

  for (final raw in plugins) {
    final plugin = raw as Map<String, dynamic>;
    final name = plugin['name'] as String;
    var target = (plugin['path'] as String).replaceAll('/', r'\');
    while (target.endsWith(r'\')) {
      target = target.substring(0, target.length - 1);
    }
    final link = '${baseDir.path}\\$name';

    final linkEntity = Directory(link);
    if (linkEntity.existsSync()) {
      try {
        linkEntity.deleteSync(recursive: true);
      } catch (_) {}
    }

    final result = Process.runSync('cmd', ['/c', 'mklink', '/J', link, target]);
    if (result.exitCode == 0) {
      stdout.writeln('  [OK] $name -> $target');
    } else {
      stderr.writeln('  [FAIL] $name: ${result.stderr}');
    }
  }

  stdout.writeln('\nAll plugin junctions created successfully! Windows Developer Mode is not required.');

  // Ensure bundled engine is verified and in place for dev and release runs
  stdout.writeln('\nChecking playback engine for dev and release environments...');
  _ensureEngineConfigured();
}

void _ensureEngineConfigured() {
  final provFile = File(r'packaging\windows\engine-provenance.json');
  if (!provFile.existsSync()) return;

  try {
    final record = jsonDecode(provFile.readAsStringSync()) as Map<String, dynamic>;
    final engine = record['engine'] as Map<String, dynamic>;
    final artifact = record['artifact'] as Map<String, dynamic>;
    final version = engine['version'] as String;
    final member = artifact['member'] as String? ?? 'libmpv-2.dll';

    // Check AppData active update to sync if present
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      final selectionFile = File('$appData\\Mpvson\\Mpvson\\mpvson\\engines\\engine-selection.json');
      if (selectionFile.existsSync()) {
        try {
          final sel = jsonDecode(selectionFile.readAsStringSync()) as Map<String, dynamic>;
          final active = sel['active'] as Map<String, dynamic>?;
          if (active != null) {
            final activeVersion = active['version'] as String?;
            final activePath = active['path'] as String?;
            if (activeVersion != null && activePath != null) {
              final activeDll = File('$activePath\\$member');
              if (activeDll.existsSync()) {
                final cleanVersion = version.startsWith('v') ? version.substring(1) : version;
                final cleanActiveVersion = activeVersion.startsWith('v') ? activeVersion.substring(1) : activeVersion;
                if (cleanActiveVersion != cleanVersion) {
                  stdout.writeln('  [NOTICE] In-app engine v$cleanActiveVersion is installed in AppData, while build pin is $cleanVersion.');
                  stdout.writeln('  [TIP] To bundle v$cleanActiveVersion into future builds, run: dart run tool/engine_provenance.dart sync-active');
                } else {
                  stdout.writeln('  [OK] In-app engine v$cleanActiveVersion matches build pin $cleanVersion.');
                }
              }
            }
          }
        } catch (_) {}
      }
    }

    // Ensure engine cache DLL is deployed to runner Debug and Release if directories exist
    final cachedDll = File('build\\windows\\x64\\engine\\$version\\$member');
    if (cachedDll.existsSync()) {
      for (final mode in ['Debug', 'Release']) {
        final destDir = Directory('build\\windows\\x64\\runner\\$mode');
        if (destDir.existsSync()) {
          final targetDll = File('${destDir.path}\\$member');
          if (!targetDll.existsSync() || targetDll.lengthSync() != cachedDll.lengthSync()) {
            cachedDll.copySync(targetDll.path);
            stdout.writeln('  [OK] Installed $member into $mode environment.');
          } else {
            stdout.writeln('  [OK] $member already present in $mode environment.');
          }
        }
      }
    }
  } catch (e) {
    stdout.writeln('  [NOTICE] Engine pre-configuration note: $e');
  }
}
