import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'process_runner.dart';

/// How the running Mpvson installation is packaged and updated.
enum AppInstallMode {
  /// Windows per-user installation created by `MpvsonSetup.exe` (`unins*.exe` present).
  windowsInstaller,

  /// Writable Windows portable folder (`mpvson-windows-x64.zip`).
  windowsPortable,

  /// Writable Linux user bundle (`mpvson-linux-x64.tar.gz`).
  linuxBundle,

  /// Read-only or non-self-updatable installation.
  readOnly,
}

const int _maxArchiveEntries = 2000;
const int _maxUncompressedBytes = 1024 * 1024 * 1024; // 1 GiB
const String appUpdateErrorFileName = 'last-apply-error.log';
const _windowsBundleFiles = [
  'mpvson.exe',
  'flutter_windows.dll',
  'libmpv-2.dll',
  'data/icudtl.dat',
  'data/app.so',
  'engine-provenance.json',
];
const _linuxBundleFiles = [
  'mpvson',
  'lib/libflutter_linux_gtk.so',
  'lib/libapp.so',
  'data/icudtl.dat',
  'dev.mpvson.mpvson.desktop',
];
final RegExp _windowsUninstallerPattern = RegExp(
  r'^unins\d{3}\.exe$',
  caseSensitive: false,
);
final Random _applierRandom = Random.secure();

/// Detects whether the current Mpvson installation can auto-install updates
/// via the Windows installer, a writable portable/user bundle, or is read-only.
AppInstallMode detectInstallMode({
  String? executablePath,
  bool? isWindows,
  bool? isLinux,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final linux = isLinux ?? Platform.isLinux;
  final rawExePath = executablePath ?? Platform.resolvedExecutable;

  if (windows) {
    final exeDir = File(rawExePath).parent;
    if (_hasWindowsUninstaller(exeDir)) {
      return AppInstallMode.windowsInstaller;
    }
    return _isManagedBundle(exeDir, _windowsBundleFiles)
        ? AppInstallMode.windowsPortable
        : AppInstallMode.readOnly;
  }

  if (linux) {
    var resolvedExePath = rawExePath;
    try {
      resolvedExePath = File(rawExePath).resolveSymbolicLinksSync();
    } on Object {
      resolvedExePath = rawExePath;
    }
    final exeDir = File(resolvedExePath).parent;
    return _isManagedBundle(exeDir, _linuxBundleFiles)
        ? AppInstallMode.linuxBundle
        : AppInstallMode.readOnly;
  }

  return AppInstallMode.readOnly;
}

bool _isManagedBundle(Directory directory, List<String> files) =>
    !p.equals(directory.path, directory.parent.path) &&
    files.every((path) => File(p.join(directory.path, path)).existsSync()) &&
    _isDirectoryWritable(directory.parent);

void _validateBundle(Directory directory, List<String> paths) {
  for (final path in paths) {
    final file = File(p.join(directory.path, path));
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw FormatException('Update bundle is missing a required file: $path.');
    }
  }
}

bool _hasWindowsUninstaller(Directory exeDir) {
  try {
    if (File(p.join(exeDir.path, 'unins000.exe')).existsSync()) {
      return true;
    }
    if (!exeDir.existsSync()) return false;
    for (final entity in exeDir.listSync(followLinks: false)) {
      if (entity is File &&
          _windowsUninstallerPattern.hasMatch(p.basename(entity.path))) {
        return true;
      }
    }
  } on Object {
    return false;
  }
  return false;
}

bool _isDirectoryWritable(Directory directory) {
  try {
    if (!directory.existsSync()) return false;
    final suffix = _applierRandom.nextInt(1 << 32).toRadixString(16);
    final probe = File(
      p.join(directory.path, '.mpvson-write-$pid-$suffix.tmp'),
    );
    probe.writeAsStringSync('probe', flush: true);
    probe.deleteSync();
    return true;
  } on Object {
    return false;
  }
}

/// Validates and extracts a Windows portable `.zip` archive into [stagingDir].
///
/// Runs inside a background isolate to keep the UI responsive. Throws
/// [FormatException] if the archive violates path-traversal, entry-count, size,
/// symlink, or `mpvson.exe` entrypoint checks.
Future<void> stageZipArchive({
  required File archiveFile,
  required Directory stagingDir,
}) {
  final archivePath = archiveFile.path;
  final stagePath = stagingDir.path;
  return Isolate.run(() => _stageZipSync(archivePath, stagePath));
}

/// Validates and extracts a Linux `.tar.gz` bundle into [stagingDir].
///
/// Runs inside a background isolate to keep the UI responsive. Throws
/// [FormatException] if the archive violates path-traversal, entry-count, size,
/// symlink-escape, or `mpvson` binary checks.
Future<void> stageTarGzArchive({
  required File archiveFile,
  required Directory stagingDir,
}) {
  final archivePath = archiveFile.path;
  final stagePath = stagingDir.path;
  return Isolate.run(() => _stageTarGzSync(archivePath, stagePath));
}

void _stageZipSync(String archivePath, String stagePath) {
  final stageDir = Directory(stagePath);
  if (stageDir.existsSync()) {
    throw const FileSystemException(
      'The update staging directory already exists.',
    );
  }
  stageDir.createSync(recursive: true);

  final normalizedStage = p.normalize(p.absolute(stagePath));
  final fileStream = InputFileStream(archivePath);
  try {
    final archive = ZipDecoder().decodeStream(fileStream);
    if (archive.files.length > _maxArchiveEntries) {
      throw const FormatException('Update ZIP contains too many entries.');
    }

    var totalBytes = 0;
    for (final file in archive.files) {
      final relativePath = _validatedArchivePath(
        file.name,
        label: 'Update ZIP',
      );
      if (relativePath == '.') continue;

      final destPath = p.normalize(p.join(normalizedStage, relativePath));
      if (!p.isWithin(normalizedStage, destPath)) {
        throw const FormatException('Update ZIP contains an unsafe path.');
      }
      if (file.isSymbolicLink || file.symbolicLink != null) {
        throw const FormatException('Update ZIP contains a link entry.');
      }

      if (file.isDirectory) {
        Directory(destPath).createSync(recursive: true);
        continue;
      }

      totalBytes += file.size;
      if (totalBytes > _maxUncompressedBytes) {
        throw const FormatException('Update ZIP exceeds the size limit.');
      }

      Directory(p.dirname(destPath)).createSync(recursive: true);
      final outStream = OutputFileStream(destPath);
      try {
        file.writeContent(outStream, freeMemory: true);
      } finally {
        try {
          outStream.closeSync();
        } finally {
          file.closeSync();
        }
      }
    }

    _validateBundle(stageDir, _windowsBundleFiles);
  } catch (_) {
    try {
      if (stageDir.existsSync()) {
        stageDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    rethrow;
  } finally {
    fileStream.closeSync();
  }
}

Future<void> _stageTarGzSync(String archivePath, String stagePath) async {
  final stageDir = Directory(stagePath);
  if (stageDir.existsSync()) {
    throw const FileSystemException(
      'The update staging directory already exists.',
    );
  }
  stageDir.createSync(recursive: true);

  final normalizedStage = p.normalize(p.absolute(stagePath));
  final expansionDir = stageDir.parent.createTempSync('inflate-update-');
  try {
    final tarFile = File(p.join(expansionDir.path, 'bundle.tar'));
    final output = await tarFile.open(mode: FileMode.write);
    try {
      var expandedBytes = 0;
      await for (final chunk in gzip.decoder.bind(
        File(archivePath).openRead(),
      )) {
        expandedBytes += chunk.length;
        if (expandedBytes > _maxUncompressedBytes) {
          throw const FormatException('Update archive exceeds the size limit.');
        }
        await output.writeFrom(chunk);
      }
    } finally {
      await output.close();
    }
    final input = InputFileStream(tarFile.path);
    try {
      _extractTar(input, stageDir, normalizedStage);
    } finally {
      input.closeSync();
    }
  } catch (_) {
    try {
      stageDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Preserve the original preparation error.
    }
    rethrow;
  } finally {
    try {
      expansionDir.deleteSync(recursive: true);
    } on FileSystemException {
      // The staged bundle is independent of the temporary tar.
    }
  }
}

void _extractTar(
  InputFileStream input,
  Directory stageDir,
  String normalizedStage,
) {
  final archive = TarDecoder().decodeStream(input);

  if (archive.files.length > _maxArchiveEntries) {
    throw const FormatException('Update archive contains too many entries.');
  }

  var totalBytes = 0;
  for (final file in archive.files) {
    final relativePath = _validatedArchivePath(
      file.name,
      label: 'Update archive',
      allowLeadingDotSlash: true,
    );
    if (relativePath == '.') continue;

    final destPath = p.normalize(p.join(normalizedStage, relativePath));
    if (!p.isWithin(normalizedStage, destPath)) {
      throw const FormatException('Update archive contains an unsafe path.');
    }

    if (file.isSymbolicLink || file.symbolicLink != null) {
      final linkTarget = file.symbolicLink;
      if (linkTarget == null || linkTarget.isEmpty) {
        throw const FormatException(
          'Update archive contains an empty symlink.',
        );
      }
      if (p.isAbsolute(linkTarget) || linkTarget.contains('\u0000')) {
        throw const FormatException(
          'Update archive contains an unsafe symlink target.',
        );
      }
      final resolvedTarget = p.normalize(
        p.join(p.dirname(destPath), linkTarget),
      );
      if (!p.isWithin(normalizedStage, resolvedTarget)) {
        throw const FormatException(
          'Update archive symlink escapes the staging directory.',
        );
      }
      Directory(p.dirname(destPath)).createSync(recursive: true);
      final link = Link(destPath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      link.createSync(linkTarget);
      continue;
    }

    if (file.isDirectory) {
      Directory(destPath).createSync(recursive: true);
      continue;
    }

    totalBytes += file.size;
    if (totalBytes > _maxUncompressedBytes) {
      throw const FormatException('Update archive exceeds the size limit.');
    }

    Directory(p.dirname(destPath)).createSync(recursive: true);
    final outStream = OutputFileStream(destPath);
    try {
      file.writeContent(outStream, freeMemory: true);
    } finally {
      try {
        outStream.closeSync();
      } finally {
        file.closeSync();
      }
    }
  }

  _validateBundle(stageDir, _linuxBundleFiles);
}

String _validatedArchivePath(
  String rawName, {
  required String label,
  bool allowLeadingDotSlash = false,
}) {
  if (rawName.contains('\u0000')) {
    throw FormatException('$label contains a null byte in an entry path.');
  }
  var normalized = rawName.replaceAll('\\', '/');
  if (allowLeadingDotSlash) {
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    if (normalized == '.' || normalized.isEmpty) {
      return '.';
    }
  }
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw FormatException('$label contains an absolute path: $rawName');
  }

  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) {
    return '.';
  }
  for (final part in parts) {
    if (part == '.' || part == '..') {
      throw FormatException('$label contains a traversal path: $rawName');
    }
  }
  return p.joinAll(parts);
}

/// Launches the verified Windows Inno Setup installer silently with auto-relaunch.
Future<void> launchWindowsInstaller({
  required String installerPath,
  ProcessRunner processRunner = ProcessRunner.standard,
}) async {
  final file = File(installerPath);
  await processRunner.start(
    file.path,
    const <String>[
      '/SILENT',
      '/SP-',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/NOCLOSEAPPLICATIONS',
      // Never force-close Mpvson on the automatic path: the app only launches
      // this installer after its guarded shutdown has saved the session and
      // the user agreed to close. Forcing would bypass a cancelled close.
      '/AUTOUPDATE=1',
    ],
    workingDirectory: file.parent.path,
    mode: ProcessStartMode.detached,
  );
}

/// Launches a detached PowerShell helper that waits for [currentPid] to exit,
/// replaces the portable bundle at [targetDir] from [stagingDir], and relaunches
/// [appExecutablePath] with `--post-update`.
Future<void> launchWindowsPortableSwapper({
  required Directory updatesDir,
  required Directory stagingDir,
  required Directory targetDir,
  required String appExecutablePath,
  required int currentPid,
  required String expectedVersion,
  ProcessRunner processRunner = ProcessRunner.standard,
}) async {
  _validateSwapDirectories(updatesDir, stagingDir, targetDir);
  await updatesDir.create(recursive: true);
  final suffix = _applierRandom.nextInt(1 << 32).toRadixString(16);
  final scriptFile = File(p.join(updatesDir.path, 'apply-update-$suffix.ps1'));
  final errorLogPath = p.join(updatesDir.path, appUpdateErrorFileName);

  await scriptFile.writeAsString(_windowsSwapperScript, flush: true);
  await processRunner.start(
    'powershell.exe',
    <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      scriptFile.path,
      '-WaitPid',
      '$currentPid',
      '-StageDir',
      stagingDir.path,
      '-TargetDir',
      targetDir.path,
      '-AppExe',
      appExecutablePath,
      '-ErrorLog',
      errorLogPath,
      '-ExpectedVersion',
      expectedVersion,
    ],
    workingDirectory: updatesDir.path,
    mode: ProcessStartMode.detached,
  );
}

/// Launches a detached POSIX shell helper that waits for [currentPid] to exit,
/// replaces the Linux user bundle at [targetDir] from [stagingDir], and
/// relaunches [appExecutablePath] with `--post-update`.
Future<void> launchLinuxBundleSwapper({
  required Directory updatesDir,
  required Directory stagingDir,
  required Directory targetDir,
  required String appExecutablePath,
  required int currentPid,
  required String expectedVersion,
  ProcessRunner processRunner = ProcessRunner.standard,
}) async {
  _validateSwapDirectories(updatesDir, stagingDir, targetDir);
  await updatesDir.create(recursive: true);
  final suffix = _applierRandom.nextInt(1 << 32).toRadixString(16);
  final scriptFile = File(p.join(updatesDir.path, 'apply-update-$suffix.sh'));
  final errorLogPath = p.join(updatesDir.path, appUpdateErrorFileName);

  await scriptFile.writeAsString(_linuxSwapperScript, flush: true);
  await processRunner.start(
    '/bin/sh',
    <String>[
      scriptFile.path,
      '$currentPid',
      stagingDir.path,
      targetDir.path,
      appExecutablePath,
      errorLogPath,
      expectedVersion,
    ],
    workingDirectory: updatesDir.path,
    mode: ProcessStartMode.detached,
  );
}

void _validateSwapDirectories(
  Directory updates,
  Directory staged,
  Directory target,
) {
  final targetPath = p.normalize(target.absolute.path);
  final updatesPath = p.normalize(updates.absolute.path);
  final stagedPath = p.normalize(staged.absolute.path);
  if (p.equals(targetPath, p.dirname(targetPath)) ||
      p.equals(targetPath, updatesPath) ||
      p.isWithin(targetPath, updatesPath) ||
      !p.isWithin(updatesPath, stagedPath)) {
    throw const FileSystemException(
      'The update files must be staged outside the installation folder.',
    );
  }
}

/// Best-effort cleanup for orphaned temporary downloads, staging dirs, and helper
/// scripts older than [maxAge].
Future<void> cleanupStaleArtifacts(
  Directory updatesDir, {
  Duration maxAge = const Duration(hours: 1),
}) async {
  try {
    if (!await updatesDir.exists()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in updatesDir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final isStaleCandidate =
          (name.startsWith('.mpvson-update-') && name.endsWith('.part')) ||
          name.startsWith('staged-') ||
          name.startsWith('apply-update-');
      if (!isStaleCandidate) continue;

      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        await entity.delete(recursive: true);
      } on Object {
        // Ignore locked or already-removed entries.
      }
    }
  } on Object {
    // Cleanup is best-effort and must never block updates.
  }
}

const String _windowsSwapperScript = r'''
param(
  [Parameter(Mandatory = $true)][int]$WaitPid,
  [Parameter(Mandatory = $true)][string]$StageDir,
  [Parameter(Mandatory = $true)][string]$TargetDir,
  [Parameter(Mandatory = $true)][string]$AppExe,
  [Parameter(Mandatory = $true)][string]$ErrorLog,
  [Parameter(Mandatory = $true)][string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'

$exited = $false
for ($i = 0; $i -lt 120; $i++) {
  if (-not (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) {
    $exited = $true
    break
  }
  Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 350

# A cancelled or stalled close must never reach the replacement step. Keep the
# staged package and the downloaded archive for a later retry.
if (-not $exited -or (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) {
  try {
    Set-Content -LiteralPath $ErrorLog -Value "Mpvson (PID $WaitPid) was still running when the update helper timed out. No files were changed." -Encoding UTF8
  } catch {}
  exit 1
}

$id = [Guid]::NewGuid().ToString('N')
$candidate = "$TargetDir.mpvson-update-$id"
$backup = "$TargetDir.mpvson-previous-$id"
$ack = Join-Path (Split-Path -Parent $ErrorLog) "update-ready-$id"
$child = $null
$movedOld = $false
$movedNew = $false
try {
  # Prepare on the installation volume before touching the running bundle.
  Copy-Item -LiteralPath $StageDir -Destination $candidate -Recurse -Force
  foreach ($item in Get-ChildItem -LiteralPath $TargetDir -Force) {
    $destination = Join-Path $candidate $item.Name
    if (-not (Test-Path -LiteralPath $destination)) {
      Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
  }
  [IO.Directory]::Move($TargetDir, $backup)
  $movedOld = $true
  [IO.Directory]::Move($candidate, $TargetDir)
  $movedNew = $true
  $env:MPVSON_UPDATE_READY_FILE = $ack
  $env:MPVSON_UPDATE_EXPECTED_VERSION = $ExpectedVersion
  $child = Start-Process -FilePath $AppExe -ArgumentList '--post-update' -WorkingDirectory $TargetDir -PassThru
  for ($i = 0; $i -lt 180; $i++) {
    if (Test-Path -LiteralPath $ack) {
      Remove-Item -LiteralPath $ack -Force -ErrorAction SilentlyContinue
      exit 0
    }
    if ($child.HasExited) { throw 'The new version closed before it was ready.' }
    Start-Sleep -Milliseconds 250
  }
  throw 'The new version did not report a successful startup.'
} catch {
  $reason = $_.Exception.Message
  if ($movedOld -and ($null -eq $child -or $child.HasExited)) {
    try {
      if ($movedNew) { [IO.Directory]::Move($TargetDir, $candidate) }
      [IO.Directory]::Move($backup, $TargetDir)
      $reason += ' The previous bundle was restored.'
    } catch {
      $reason += " The previous bundle is at $backup."
    }
  } elseif ($movedOld) {
    $reason += " The previous bundle is at $backup."
  }
  Set-Content -LiteralPath $ErrorLog -Value $reason -Encoding UTF8
  exit 1
}
''';

const String _linuxSwapperScript = r'''#!/bin/sh
WAIT_PID="$1"
STAGE_DIR="$2"
TARGET_DIR="$3"
APP_EXE="$4"
ERROR_LOG="$5"
EXPECTED_VERSION="$6"

EXITED=0
i=0
while [ "$i" -lt 120 ]; do
  if ! kill -0 "$WAIT_PID" 2>/dev/null; then
    EXITED=1
    break
  fi
  sleep 0.25
  i=$((i + 1))
done
sleep 0.35

# Never replace files while the previous instance is still alive: a cancelled
# or stalled close must leave both bundles untouched and retryable.
if [ "$EXITED" -ne 1 ] || kill -0 "$WAIT_PID" 2>/dev/null; then
  echo "Mpvson (PID $WAIT_PID) was still running when the update helper timed out. No files were changed." > "$ERROR_LOG"
  exit 1
fi

TRANSACTION=$(mktemp -d "$(dirname "$TARGET_DIR")/.mpvson-update.XXXXXXXX") || {
  echo 'Could not prepare an update beside the installed bundle.' > "$ERROR_LOG"
  exit 1
}
CANDIDATE="$TRANSACTION/new"
BACKUP="$TRANSACTION/previous"
ACK="$(dirname "$ERROR_LOG")/update-ready-$(basename "$TRANSACTION")"
fail() {
  echo "$1" > "$ERROR_LOG"
  exit 1
}

mkdir "$CANDIDATE" && cp -a "$STAGE_DIR/." "$CANDIDATE/" ||
  fail 'Could not copy the update to the installation volume.'
for entry in "$TARGET_DIR"/* "$TARGET_DIR"/.[!.]* "$TARGET_DIR"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=$(basename "$entry")
  [ -e "$CANDIDATE/$name" ] || [ -L "$CANDIDATE/$name" ] ||
    cp -a "$entry" "$CANDIDATE/" || fail 'Could not retain the existing bundle files.'
done
chmod +x "$CANDIDATE/mpvson" || fail 'Could not make the new Mpvson executable.'
for script in install.sh uninstall.sh; do
  [ ! -f "$CANDIDATE/$script" ] || chmod +x "$CANDIDATE/$script" ||
    fail 'Could not restore the bundle script permissions.'
done

mv "$TARGET_DIR" "$BACKUP" || fail 'Could not move the previous Mpvson bundle.'
if ! mv "$CANDIDATE" "$TARGET_DIR"; then
  mv "$BACKUP" "$TARGET_DIR" && fail 'Could not apply the update. The previous bundle was restored.'
  fail "Could not apply the update. The previous bundle is at $BACKUP."
fi

MPVSON_UPDATE_READY_FILE="$ACK" MPVSON_UPDATE_EXPECTED_VERSION="$EXPECTED_VERSION" \
  nohup "$APP_EXE" >/dev/null 2>&1 &
child=$!
i=0
while [ "$i" -lt 180 ]; do
  if [ -f "$ACK" ]; then
    rm -f "$ACK"
    exit 0
  fi
  if ! kill -0 "$child" 2>/dev/null; then
    if mv "$TARGET_DIR" "$CANDIDATE" && mv "$BACKUP" "$TARGET_DIR"; then
      fail 'The new version closed before it was ready. The previous bundle was restored.'
    fi
    fail "The new version closed before it was ready. The previous bundle is at $BACKUP."
  fi
  sleep 0.25
  i=$((i + 1))
done
fail "The new version did not report a successful startup. The previous bundle is at $BACKUP."
''';
