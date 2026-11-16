import 'dart:io';

import 'package:mpvson/data/services/windows_associations_core.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:path/path.dart' as p;

/// Resolves the absolute path to `mpvson.exe`.
String? findTargetExecutable({String? overridePath}) {
  if (overridePath != null && overridePath.trim().isNotEmpty) {
    final candidate = File(overridePath.trim());
    if (candidate.existsSync()) {
      return p.canonicalize(candidate.absolute.path);
    }
    throw ArgumentError('Specified executable not found: $overridePath');
  }

  final cwdCandidate = File(p.join(Directory.current.path, 'mpvson.exe'));
  if (cwdCandidate.existsSync()) {
    return p.canonicalize(cwdCandidate.absolute.path);
  }

  final buildCandidate = File(
    p.join(
      Directory.current.path,
      'build',
      'windows',
      'x64',
      'runner',
      'Release',
      'mpvson.exe',
    ),
  );
  if (buildCandidate.existsSync()) {
    return p.canonicalize(buildCandidate.absolute.path);
  }

  final scriptDir = File(Platform.script.toFilePath()).parent;
  final scriptDirCandidate = File(p.join(scriptDir.path, 'mpvson.exe'));
  if (scriptDirCandidate.existsSync()) {
    return p.canonicalize(scriptDirCandidate.absolute.path);
  }

  final repoRootCandidate = File(
    p.join(
      scriptDir.parent.path,
      'build',
      'windows',
      'x64',
      'runner',
      'Release',
      'mpvson.exe',
    ),
  );
  if (repoRootCandidate.existsSync()) {
    return p.canonicalize(repoRootCandidate.absolute.path);
  }

  return null;
}

Future<void> printStatus(String targetExe) async {
  final check = await checkWindowsRegistration(targetExe);
  stdout.writeln('=== Mpvson Registration Status ===');
  stdout.writeln('Target Executable: $targetExe');
  stdout.writeln('Target Exists: ${File(targetExe).existsSync()}');
  if (!check.isRegistered) {
    stdout.writeln('Registered in HKCU: No');
  } else {
    stdout.writeln('Registered in HKCU: Yes');
    stdout.writeln('Registered Path: ${check.registeredExePath}');
    stdout.writeln('Matches Target: ${check.matchesTarget}');
    stdout.writeln('Other Install Exists: ${check.otherInstallExists}');
  }
  stdout.writeln(
    'Total Supported Formats in MediaCatalog: ${MediaCatalog.supportedExtensions.length}',
  );
}

void printHelp() {
  stdout.writeln('''
Mpvson Windows Association Tool
Usage: dart run tool/windows_associations.dart <command> [options]

Commands:
  register       Register Mpvson file associations, ProgID, and capabilities for current user.
  unregister     Cleanly unregister Mpvson associations for current user.
  status         Show current registration status in HKCU.

Options:
  --exe=<path>   Path to mpvson.exe (auto-detected if omitted)
  --force        Allow registering or unregistering when another install is registered
  --dry-run      Print operations without making registry modifications
  --verbose      Print detailed command outputs
  --help, -h     Show this help message
''');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    printHelp();
    exit(args.isEmpty ? 1 : 0);
  }

  final command = args.first.toLowerCase();
  String? exePath;
  var force = false;
  var dryRun = false;
  var verbose = false;

  for (final arg in args.skip(1)) {
    if (arg.startsWith('--exe=')) {
      exePath = arg.substring('--exe='.length);
    } else if (arg == '--force') {
      force = true;
    } else if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg == '--verbose') {
      verbose = true;
    }
  }

  final resolvedExe = findTargetExecutable(overridePath: exePath);
  if (resolvedExe == null) {
    stderr.writeln(
      'Error: Could not find mpvson.exe. Specify path with --exe=<path>',
    );
    exit(1);
  }

  Future<ProcessResult> runner(List<String> regArgs) async {
    if (dryRun) {
      if (verbose) stdout.writeln('[DRY-RUN] reg ${regArgs.join(' ')}');
      return ProcessResult(0, 0, '', '');
    }
    return Process.run('reg.exe', regArgs);
  }

  switch (command) {
    case 'register':
      final success = await registerWindowsAssociations(
        targetExe: resolvedExe,
        force: force,
        runReg: runner,
        notifyShell: dryRun ? () {} : null,
        onInfo: stdout.writeln,
        onError: stderr.writeln,
      );
      exit(success ? 0 : 2);
    case 'unregister':
      final success = await unregisterWindowsAssociations(
        targetExe: resolvedExe,
        force: force,
        runReg: runner,
        notifyShell: dryRun ? () {} : null,
        onInfo: stdout.writeln,
        onWarning: stderr.writeln,
      );
      exit(success ? 0 : 2);
    case 'status':
      await printStatus(resolvedExe);
      exit(0);
    default:
      stderr.writeln('Unknown command: $command');
      printHelp();
      exit(1);
  }
}
