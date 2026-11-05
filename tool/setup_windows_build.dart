import 'dart:convert';
import 'dart:io';

void main() {
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
}
