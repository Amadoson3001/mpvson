import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/media_catalog.dart';

const String windowsAppName = 'Mpvson';
const String windowsAssocProgId = 'Mpvson.AssocFile';
const String windowsAssocFriendlyName = 'Mpvson Media File';
const String windowsAppDescription =
    'A modern desktop video player for Windows, powered by mpv.';

/// Current HKCU Windows file-association registration state for Mpvson.
final class WindowsRegistrationStatus {
  const WindowsRegistrationStatus({
    required this.isRegistered,
    this.registeredExePath,
    this.matchesTarget = false,
    this.otherInstallExists = false,
    this.hasRegisteredApplication = false,
  });

  final bool isRegistered;
  final String? registeredExePath;
  final bool matchesTarget;
  final bool otherInstallExists;
  final bool hasRegisteredApplication;
}

/// Parses a Windows build number from `Platform.operatingSystemVersion` (or similar).
int? parseWindowsBuildNumber(String osVersion) {
  final buildMatch = RegExp(
    r'\bBuild\s+(\d+)\b',
    caseSensitive: false,
  ).firstMatch(osVersion);
  if (buildMatch != null) {
    return int.tryParse(buildMatch.group(1)!);
  }
  final dottedMatch = RegExp(r'\b\d+\.\d+\.(\d+)\b').firstMatch(osVersion);
  if (dottedMatch != null) {
    return int.tryParse(dottedMatch.group(1)!);
  }
  return null;
}

/// Whether the given Windows build number corresponds to Windows 11 (22000+).
bool isWindows11Build(int? buildNumber) =>
    buildNumber != null && buildNumber >= 22000;

/// Triggers Windows Explorer and Default Apps to refresh icon/extension caches.
void notifyWindowsShellAssociationChanged() {
  if (!Platform.isWindows) return;
  try {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final shChangeNotify = shell32
        .lookupFunction<
          Void Function(Int32, Uint32, IntPtr, IntPtr),
          void Function(int, int, int, int)
        >('SHChangeNotify');
    // SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0
    shChangeNotify(0x08000000, 0, 0, 0);
  } catch (_) {
    // Best-effort shell notification.
  }
}

/// Queries the currently registered executable path from `HKCU` on Windows.
Future<String?> queryRegisteredWindowsExecutable() async {
  if (!Platform.isWindows) return null;
  try {
    final result = await Process.run('reg.exe', <String>[
      'query',
      r'HKCU\Software\Classes\Mpvson.AssocFile\shell\open\command',
      '/ve',
    ]);
    if (result.exitCode != 0) return null;

    final output = result.stdout as String;
    final match = RegExp(
      r'REG_SZ\s+"?([^"\r\n]+mpvson\.exe)"?',
      caseSensitive: false,
    ).firstMatch(output);
    if (match != null) {
      return p.canonicalize(match.group(1)!);
    }
  } catch (_) {}
  return null;
}

Future<bool> _hasRegisteredApplicationEntry() async {
  if (!Platform.isWindows) return false;
  try {
    final result = await Process.run('reg.exe', <String>[
      'query',
      r'HKCU\Software\RegisteredApplications',
      '/v',
      windowsAppName,
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Checks whether Mpvson is registered in `HKCU` and whether it matches [targetExe].
Future<WindowsRegistrationStatus> checkWindowsRegistration(
  String targetExe,
) async {
  if (!Platform.isWindows) {
    return const WindowsRegistrationStatus(isRegistered: false);
  }
  final registeredExe = await queryRegisteredWindowsExecutable();
  final hasRegisteredApp = await _hasRegisteredApplicationEntry();
  if (registeredExe == null) {
    return WindowsRegistrationStatus(
      isRegistered: false,
      hasRegisteredApplication: hasRegisteredApp,
    );
  }

  final targetCanonical = p.canonicalize(targetExe).toLowerCase();
  final registeredCanonical = p.canonicalize(registeredExe).toLowerCase();
  final matches = targetCanonical == registeredCanonical;
  final otherExists = !matches && File(registeredExe).existsSync();

  return WindowsRegistrationStatus(
    isRegistered: true,
    registeredExePath: registeredExe,
    matchesTarget: matches,
    otherInstallExists: otherExists,
    hasRegisteredApplication: hasRegisteredApp,
  );
}

typedef RegCommandRunner = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _defaultRegRunner(List<String> args) =>
    Process.run('reg.exe', args);

/// Registers Mpvson ProgID, shell commands, Capabilities, and file associations
/// under `HKCU` for [targetExe] (no elevation required).
Future<bool> registerWindowsAssociations({
  required String targetExe,
  bool force = false,
  RegCommandRunner? runReg,
  void Function()? notifyShell,
  void Function(String message)? onInfo,
  void Function(String message)? onError,
}) async {
  final runner = runReg ?? _defaultRegRunner;
  final check = await checkWindowsRegistration(targetExe);
  if (check.isRegistered && !check.matchesTarget && check.otherInstallExists) {
    if (!force) {
      onError?.call(
        'Another Mpvson installation is already registered at:\n'
        '  ${check.registeredExePath}\n'
        'Run with --force to override this protection.',
      );
      return false;
    }
    onInfo?.call(
      'Overwriting existing registration at: ${check.registeredExePath}',
    );
  }

  Future<void> addReg(List<String> args) async {
    final result = await runner(<String>['add', ...args, '/f']);
    if (result.exitCode != 0) {
      throw ProcessException(
        'reg.exe',
        args,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  // 1. HKCU\Software\Classes\Mpvson.AssocFile ProgID
  const progIdKey = r'HKCU\Software\Classes\' + windowsAssocProgId;
  await addReg(<String>[
    progIdKey,
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    windowsAssocFriendlyName,
  ]);
  await addReg(<String>[
    progIdKey,
    '/v',
    'FriendlyTypeName',
    '/t',
    'REG_SZ',
    '/d',
    windowsAssocFriendlyName,
  ]);
  await addReg(<String>[
    '$progIdKey\\DefaultIcon',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'open',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\open',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '&Play with Mpvson',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\open',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\open',
    '/v',
    'MultiSelectModel',
    '/t',
    'REG_SZ',
    '/d',
    'Player',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\open\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" "%1"',
  ]);

  await addReg(<String>[
    '$progIdKey\\shell\\enqueue',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'Add to &queue',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\enqueue',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\enqueue',
    '/v',
    'MultiSelectModel',
    '/t',
    'REG_SZ',
    '/d',
    'Player',
  ]);
  await addReg(<String>[
    '$progIdKey\\shell\\enqueue\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" --enqueue "%1"',
  ]);

  // 2. HKCU\Software\Classes\Applications\mpvson.exe
  const appExeKey = r'HKCU\Software\Classes\Applications\mpvson.exe';
  await addReg(<String>[
    appExeKey,
    '/v',
    'FriendlyAppName',
    '/t',
    'REG_SZ',
    '/d',
    windowsAppName,
  ]);
  await addReg(<String>[
    '$appExeKey\\DefaultIcon',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\open',
    '/v',
    'MultiSelectModel',
    '/t',
    'REG_SZ',
    '/d',
    'Player',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\open\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" "%1"',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\enqueue',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    'Add to queue',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\enqueue',
    '/v',
    'Icon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\enqueue',
    '/v',
    'MultiSelectModel',
    '/t',
    'REG_SZ',
    '/d',
    'Player',
  ]);
  await addReg(<String>[
    '$appExeKey\\shell\\enqueue\\command',
    '/ve',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe" --enqueue "%1"',
  ]);

  for (final ext in MediaCatalog.supportedExtensions) {
    await addReg(<String>[
      '$appExeKey\\SupportedTypes',
      '/v',
      '.$ext',
      '/t',
      'REG_SZ',
      '/d',
      '',
    ]);
  }

  // 3. RegisteredApplications & Capabilities (Windows 10/11 Default Apps)
  await addReg(<String>[
    r'HKCU\Software\RegisteredApplications',
    '/v',
    windowsAppName,
    '/t',
    'REG_SZ',
    '/d',
    r'Software\' + windowsAppName + r'\Capabilities',
  ]);

  const capKey = r'HKCU\Software\' + windowsAppName + r'\Capabilities';
  await addReg(<String>[
    capKey,
    '/v',
    'ApplicationName',
    '/t',
    'REG_SZ',
    '/d',
    windowsAppName,
  ]);
  await addReg(<String>[
    capKey,
    '/v',
    'ApplicationDescription',
    '/t',
    'REG_SZ',
    '/d',
    windowsAppDescription,
  ]);
  await addReg(<String>[
    capKey,
    '/v',
    'ApplicationIcon',
    '/t',
    'REG_SZ',
    '/d',
    '"$targetExe",0',
  ]);

  for (final ext in MediaCatalog.supportedExtensions) {
    await addReg(<String>[
      '$capKey\\FileAssociations',
      '/v',
      '.$ext',
      '/t',
      'REG_SZ',
      '/d',
      windowsAssocProgId,
    ]);
  }

  for (final entry in MediaCatalog.extensionToMimeType.entries) {
    await addReg(<String>[
      '$capKey\\MIMEAssociations',
      '/v',
      entry.value,
      '/t',
      'REG_SZ',
      '/d',
      windowsAssocProgId,
    ]);
  }

  // 4. Per-extension OpenWithProgids & OpenWithList
  for (final ext in MediaCatalog.supportedExtensions) {
    final extKey = r'HKCU\Software\Classes\.' + ext;
    await addReg(<String>[
      '$extKey\\OpenWithProgids',
      '/v',
      windowsAssocProgId,
      '/t',
      'REG_SZ',
      '/d',
      '',
    ]);
    await addReg(<String>['$extKey\\OpenWithList\\mpvson.exe']);
  }

  (notifyShell ?? notifyWindowsShellAssociationChanged)();
  onInfo?.call('Successfully registered all file associations for Mpvson.');
  return true;
}

/// Unregisters Mpvson ProgID, commands, Capabilities, and file associations
/// from `HKCU`.
Future<bool> unregisterWindowsAssociations({
  required String targetExe,
  bool force = false,
  RegCommandRunner? runReg,
  void Function()? notifyShell,
  void Function(String message)? onInfo,
  void Function(String message)? onWarning,
}) async {
  final runner = runReg ?? _defaultRegRunner;
  final check = await checkWindowsRegistration(targetExe);
  if (!check.isRegistered) {
    onInfo?.call('No active Mpvson registration found in HKCU.');
    return true;
  }

  if (!check.matchesTarget && check.otherInstallExists && !force) {
    onWarning?.call(
      'Active registration points to a different install:\n'
      '  ${check.registeredExePath}\n'
      'Unregistration skipped to protect the other installation.',
    );
    return false;
  }

  Future<void> deleteReg(List<String> args) =>
      runner(<String>['delete', ...args, '/f']);

  for (final ext in MediaCatalog.supportedExtensions) {
    final extKey = r'HKCU\Software\Classes\.' + ext;
    await deleteReg(<String>[
      '$extKey\\OpenWithProgids',
      '/v',
      windowsAssocProgId,
    ]);
    await deleteReg(<String>['$extKey\\OpenWithList\\mpvson.exe']);
  }

  await deleteReg(<String>[
    r'HKCU\Software\RegisteredApplications',
    '/v',
    windowsAppName,
  ]);
  await deleteReg(<String>[r'HKCU\Software\' + windowsAppName]);
  await deleteReg(<String>[r'HKCU\Software\Classes\Applications\mpvson.exe']);
  await deleteReg(<String>[r'HKCU\Software\Classes\' + windowsAssocProgId]);

  (notifyShell ?? notifyWindowsShellAssociationChanged)();
  onInfo?.call('Successfully unregistered Mpvson file associations.');
  return true;
}
