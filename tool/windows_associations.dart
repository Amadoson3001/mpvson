import 'dart:ffi';
import 'dart:io';

import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:path/path.dart' as p;

const String appName = 'Mpvson';
const String progId = 'Mpvson.AssocFile';
const String progIdFriendlyName = 'Mpvson Media File';
const String appDescription =
    'A modern desktop video player for Windows, powered by mpv.';

class RegistrationCheckResult {
  const RegistrationCheckResult({
    required this.isRegistered,
    this.registeredExePath,
    this.matchesTarget = false,
    this.otherInstallExists = false,
  });

  final bool isRegistered;
  final String? registeredExePath;
  final bool matchesTarget;
  final bool otherInstallExists;
}

/// Resolves the absolute path to mpvson.exe.
String? findTargetExecutable({String? overridePath}) {
  if (overridePath != null && overridePath.trim().isNotEmpty) {
    final candidate = File(overridePath.trim());
    if (candidate.existsSync()) {
      return p.canonicalize(candidate.absolute.path);
    }
    throw ArgumentError('Specified executable not found: $overridePath');
  }

  // Check current working directory
  final cwdCandidate = File(p.join(Directory.current.path, 'mpvson.exe'));
  if (cwdCandidate.existsSync()) {
    return p.canonicalize(cwdCandidate.absolute.path);
  }

  // Check Release build output folder
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

  // Check script parent directory
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final scriptDirCandidate = File(p.join(scriptDir.path, 'mpvson.exe'));
  if (scriptDirCandidate.existsSync()) {
    return p.canonicalize(scriptDirCandidate.absolute.path);
  }

  // Check script repo root build
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

/// Executes `reg.exe` with provided arguments.
Future<ProcessResult> runReg(
  List<String> args, {
  bool dryRun = false,
  bool verbose = false,
}) async {
  if (dryRun) {
    if (verbose) {
      stdout.writeln('[DRY-RUN] reg ${args.join(' ')}');
    }
    return ProcessResult(0, 0, '', '');
  }
  return Process.run('reg.exe', args);
}

/// Queries the currently registered executable from HKCU.
Future<String?> getRegisteredExecutable() async {
  try {
    final result = await Process.run('reg.exe', [
      'query',
      r'HKCU\Software\Classes\Mpvson.AssocFile\shell\open\command',
      '/ve',
    ]);
    if (result.exitCode != 0) return null;

    final output = result.stdout as String;
    final match = RegExp(r'REG_SZ\s+"?([^"]+mpvson\.exe)"?', caseSensitive: false)
        .firstMatch(output);
    if (match != null) {
      return p.canonicalize(match.group(1)!);
    }
  } catch (_) {}
  return null;
}

/// Checks whether Mpvson is currently registered and whether it collides with another install.
Future<RegistrationCheckResult> checkRegistration(String targetExe) async {
  final registeredExe = await getRegisteredExecutable();
  if (registeredExe == null) {
    return const RegistrationCheckResult(isRegistered: false);
  }

  final targetCanonical = p.canonicalize(targetExe).toLowerCase();
  final registeredCanonical = p.canonicalize(registeredExe).toLowerCase();
  final matches = targetCanonical == registeredCanonical;
  final otherExists = !matches && File(registeredExe).existsSync();

  return RegistrationCheckResult(
    isRegistered: true,
    registeredExePath: registeredExe,
    matchesTarget: matches,
    otherInstallExists: otherExists,
  );
}

/// Triggers Windows Shell to refresh icon caches and file associations.
void notifyShellAssociationChange() {
  if (!Platform.isWindows) return;
  try {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final shChangeNotify = shell32.lookupFunction<
        Void Function(Int32, Uint32, IntPtr, IntPtr),
        void Function(int, int, int, int)>('SHChangeNotify');
    // SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0
    shChangeNotify(0x08000000, 0, 0, 0);
  } catch (e) {
    // Non-fatal if direct FFI call fails, fallback via powershell can be skipped
  }
}

/// Registers Mpvson ProgID, commands, Application capabilities, and file associations for current user.
Future<bool> registerAssociations({
  required String targetExe,
  bool force = false,
  bool dryRun = false,
  bool verbose = false,
}) async {
  final check = await checkRegistration(targetExe);
  if (check.isRegistered && !check.matchesTarget && check.otherInstallExists) {
    if (!force) {
      stderr.writeln(
        'ERROR: Another Mpvson installation is already registered at:\n'
        '  ${check.registeredExePath}\n'
        'To prevent overwriting another install, registration was aborted.\n'
        'Run with --force to override this protection.',
      );
      return false;
    } else {
      stdout.writeln(
        'Warning: Overwriting existing registration at: ${check.registeredExePath}',
      );
    }
  }

  stdout.writeln('Registering associations for: $targetExe');

  // 1. HKCU\Software\Classes\Mpvson.AssocFile ProgID
  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId,
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    progIdFriendlyName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId,
    '/v',
    'FriendlyTypeName',
    '/t',
    'REG_SZ',
    '/d',
    progIdFriendlyName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\DefaultIcon',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'open',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\open',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '&Play with Mpvson',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\open',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\open\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" "%1"',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  // Enqueue command
  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\enqueue',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'Add to &queue',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\enqueue',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    r'HKCU\Software\Classes\' + progId + r'\shell\enqueue\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" --enqueue "%1"',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  // 2. HKCU\Software\Classes\Applications\mpvson.exe
  final appExeKey = r'HKCU\Software\Classes\Applications\mpvson.exe';
  await runReg([
    'add',
    appExeKey,
    '/v',
    'FriendlyAppName',
    '/t',
    'REG_SZ',
    '/d',
    appName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    '$appExeKey\\DefaultIcon',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    '$appExeKey\\shell\\open\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" "%1"',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    '$appExeKey\\shell\\enqueue',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'Add to queue',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    '$appExeKey\\shell\\enqueue',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    '$appExeKey\\shell\\enqueue\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" --enqueue "%1"',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  for (final ext in MediaCatalog.supportedExtensions) {
    await runReg([
      'add',
      '$appExeKey\\SupportedTypes',
      '/v',
      '.$ext',
      '/t',
      'REG_SZ',
      '/d',
      '',
      '/f',
    ], dryRun: dryRun, verbose: verbose);
  }

  // 3. Registered Applications & Capabilities
  await runReg([
    'add',
    r'HKCU\Software\RegisteredApplications',
    '/v',
    appName,
    '/t',
    'REG_SZ',
    '/d',
    r'Software\' + appName + r'\Capabilities',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  final capKey = r'HKCU\Software\' + appName + r'\Capabilities';
  await runReg([
    'add',
    capKey,
    '/v',
    'ApplicationName',
    '/t',
    'REG_SZ',
    '/d',
    appName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    capKey,
    '/v',
    'ApplicationDescription',
    '/t',
    'REG_SZ',
    '/d',
    appDescription,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'add',
    capKey,
    '/v',
    'ApplicationIcon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  for (final ext in MediaCatalog.supportedExtensions) {
    await runReg([
      'add',
      '$capKey\\FileAssociations',
      '/v',
      '.$ext',
      '/t',
      'REG_SZ',
      '/d',
      progId,
      '/f',
    ], dryRun: dryRun, verbose: verbose);
  }

  for (final entry in MediaCatalog.extensionToMimeType.entries) {
    await runReg([
      'add',
      '$capKey\\MIMEAssociations',
      '/v',
      entry.value,
      '/t',
      'REG_SZ',
      '/d',
      progId,
      '/f',
    ], dryRun: dryRun, verbose: verbose);
  }

  // 4. File extension associations under HKCU\Software\Classes\.ext
  for (final ext in MediaCatalog.supportedExtensions) {
    final extKey = r'HKCU\Software\Classes\.' + ext;
    // Register in OpenWithProgids
    await runReg([
      'add',
      '$extKey\\OpenWithProgids',
      '/v',
      progId,
      '/t',
      'REG_SZ',
      '/d',
      '',
      '/f',
    ], dryRun: dryRun, verbose: verbose);

    // Register in OpenWithList
    await runReg([
      'add',
      '$extKey\\OpenWithList\\mpvson.exe',
      '/f',
    ], dryRun: dryRun, verbose: verbose);
  }

  if (!dryRun) {
    notifyShellAssociationChange();
  }

  stdout.writeln('Successfully registered all file associations for Mpvson.');
  return true;
}

/// Unregisters Mpvson ProgID, commands, Application capabilities, and file associations for current user.
Future<bool> unregisterAssociations({
  required String targetExe,
  bool force = false,
  bool dryRun = false,
  bool verbose = false,
}) async {
  final check = await checkRegistration(targetExe);
  if (!check.isRegistered) {
    stdout.writeln('No active Mpvson registration found in HKCU.');
    return true;
  }

  if (!check.matchesTarget && check.otherInstallExists) {
    if (!force) {
      stderr.writeln(
        'WARNING: Active registration points to a different install:\n'
        '  ${check.registeredExePath}\n'
        'Unregistration skipped to protect the other installation.\n'
        'Use --force to unregister regardless.',
      );
      return false;
    } else {
      stdout.writeln(
        'Warning: Forcibly unregistering installation at: ${check.registeredExePath}',
      );
    }
  }

  stdout.writeln('Unregistering associations for: $targetExe');

  // 1. Remove from OpenWithProgids & OpenWithList
  for (final ext in MediaCatalog.supportedExtensions) {
    final extKey = r'HKCU\Software\Classes\.' + ext;
    await runReg([
      'delete',
      '$extKey\\OpenWithProgids',
      '/v',
      progId,
      '/f',
    ], dryRun: dryRun, verbose: verbose);

    await runReg([
      'delete',
      '$extKey\\OpenWithList\\mpvson.exe',
      '/f',
    ], dryRun: dryRun, verbose: verbose);
  }

  // 2. Remove RegisteredApplications & Capabilities
  await runReg([
    'delete',
    r'HKCU\Software\RegisteredApplications',
    '/v',
    appName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  await runReg([
    'delete',
    r'HKCU\Software\' + appName,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  // 3. Remove Applications\mpvson.exe
  await runReg([
    'delete',
    r'HKCU\Software\Classes\Applications\mpvson.exe',
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  // 4. Remove ProgID
  await runReg([
    'delete',
    r'HKCU\Software\Classes\' + progId,
    '/f',
  ], dryRun: dryRun, verbose: verbose);

  if (!dryRun) {
    notifyShellAssociationChange();
  }

  stdout.writeln('Successfully unregistered Mpvson file associations.');
  return true;
}

Future<void> printStatus(String targetExe) async {
  final check = await checkRegistration(targetExe);
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
  stdout.writeln(
    '''
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
''',
  );
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

  switch (command) {
    case 'register':
      final success = await registerAssociations(
        targetExe: resolvedExe,
        force: force,
        dryRun: dryRun,
        verbose: verbose,
      );
      exit(success ? 0 : 2);
    case 'unregister':
      final success = await unregisterAssociations(
        targetExe: resolvedExe,
        force: force,
        dryRun: dryRun,
        verbose: verbose,
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
