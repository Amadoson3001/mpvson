// Generates and verifies SHA256SUMS files for release artifacts in a directory.
//
// Usage:
//   dart run tool/create_checksums.dart [dist] [--verify]
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final verifyOnly = arguments.contains('--verify');
  final positional = arguments.where((a) => !a.startsWith('-')).toList();
  final targetDirPath = positional.isEmpty ? 'dist' : positional.first;
  final dir = Directory(targetDirPath);

  if (!dir.existsSync()) {
    stderr.writeln('Directory does not exist: ${dir.path}');
    exitCode = 1;
    return;
  }

  final sumsFile = File(p.join(dir.path, 'SHA256SUMS'));
  if (verifyOnly) {
    if (!sumsFile.existsSync()) {
      stderr.writeln('Missing ${sumsFile.path}');
      exitCode = 1;
      return;
    }
    var ok = true;
    for (final rawLine in sumsFile.readAsLinesSync()) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line);
      if (match == null) {
        stderr.writeln('Invalid SHA256SUMS line: "$rawLine"');
        ok = false;
        continue;
      }
      final expected = match.group(1)!.toLowerCase();
      final name = match.group(2)!.trim();
      final artifact = File(p.join(dir.path, name));
      if (!artifact.existsSync()) {
        stderr.writeln('Missing artifact listed in SHA256SUMS: $name');
        ok = false;
        continue;
      }
      final actual = (await sha256.bind(artifact.openRead()).first).toString();
      if (actual != expected) {
        stderr.writeln(
          'SHA-256 mismatch for $name: expected $expected, got $actual',
        );
        ok = false;
      } else {
        stdout.writeln('OK  $name ($actual)');
      }
    }
    if (!ok) exitCode = 1;
    return;
  }

  final artifacts = dir.listSync().whereType<File>().where((f) {
    final name = p.basename(f.path);
    return name != 'SHA256SUMS' &&
        !name.endsWith('.sha256') &&
        (name.endsWith('.zip') ||
            name.endsWith('.exe') ||
            name.endsWith('.tar.gz') ||
            name.endsWith('.msi'));
  }).toList()..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  if (artifacts.isEmpty) {
    stderr.writeln('No release artifacts found in ${dir.path}');
    exitCode = 1;
    return;
  }

  final lines = <String>[];
  for (final file in artifacts) {
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final name = p.basename(file.path);
    lines.add('$digest  $name');
    stdout.writeln('$digest  $name');
  }
  await sumsFile.writeAsString('${lines.join('\n')}\n');
  stdout.writeln('Wrote ${sumsFile.path}');
}
