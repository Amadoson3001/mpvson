// Tooling for verifying and bundling Windows VC++ runtime redistributable DLLs,
// detecting and cleaning debug-CRT artifacts (such as debug-CRT zlib.dll), and
// verifying Linux/Windows release distributions.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Known debug-CRT libraries that must never be packaged into release distributions.
const Set<String> debugCrtDllNames = <String>{
  'vcruntime140d.dll',
  'msvcp140d.dll',
  'msvcp140_1d.dll',
  'msvcp140_2d.dll',
  'msvcp140_atomic_waitd.dll',
  'msvcp140_codecvt_idsd.dll',
  'ucrtbased.dll',
  'concrt140d.dll',
  'vccorlib140d.dll',
  'msvcr120d.dll',
  'msvcp120d.dll',
  'msvcr110d.dll',
  'msvcp110d.dll',
  'msvcr100d.dll',
  'msvcp100d.dll',
};

/// Core VC++ 2015-2022 runtime redistributable DLLs needed by MSVC-compiled Flutter apps on x64.
const List<String> coreVcRuntimeDlls = <String>[
  'msvcp140.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll',
  'msvcp140_1.dll',
  'msvcp140_2.dll',
  'msvcp140_atomic_wait.dll',
  'msvcp140_codecvt_ids.dll',
  'concrt140.dll',
];

/// Parses the PE import table of [file] in pure Dart and returns all imported DLL names.
List<String> getPeImportedDlls(File file) {
  if (!file.existsSync()) return <String>[];
  final bytes = file.readAsBytesSync();
  return getPeImportedDllsFromBytes(bytes);
}

/// Parses the PE import table from raw [bytes].
List<String> getPeImportedDllsFromBytes(List<int> bytes) {
  if (bytes.length < 64) return <String>[];
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  if (view.getUint16(0, Endian.little) != 0x5A4D) return <String>[]; // "MZ"
  final peOffset = view.getUint32(0x3C, Endian.little);
  if (peOffset + 24 > bytes.length) return <String>[];
  if (view.getUint32(peOffset, Endian.little) != 0x00004550) {
    return <String>[]; // "PE\0\0"
  }

  final numSections = view.getUint16(peOffset + 6, Endian.little);
  final optHeaderSize = view.getUint16(peOffset + 20, Endian.little);
  final optHeaderOffset = peOffset + 24;
  if (optHeaderOffset + optHeaderSize > bytes.length) return <String>[];

  final magic = view.getUint16(optHeaderOffset, Endian.little);
  final is64 = magic == 0x20B;
  final dataDirsOffset = optHeaderOffset + (is64 ? 112 : 96);
  if (dataDirsOffset + 16 > bytes.length) return <String>[];

  final importRva = view.getUint32(dataDirsOffset + 8, Endian.little);
  final importSize = view.getUint32(dataDirsOffset + 12, Endian.little);
  if (importRva == 0 || importSize == 0) return <String>[];

  final sectionHeadersOffset = optHeaderOffset + optHeaderSize;
  int rvaToFileOffset(int rva) {
    for (var i = 0; i < numSections; i++) {
      final secOffset = sectionHeadersOffset + i * 40;
      if (secOffset + 40 > bytes.length) break;
      final virtSize = view.getUint32(secOffset + 8, Endian.little);
      final virtAddr = view.getUint32(secOffset + 12, Endian.little);
      final rawSize = view.getUint32(secOffset + 16, Endian.little);
      final rawOffset = view.getUint32(secOffset + 20, Endian.little);
      final size = virtSize > 0 ? virtSize : rawSize;
      if (rva >= virtAddr && rva < virtAddr + size) {
        return rawOffset + (rva - virtAddr);
      }
    }
    return 0;
  }

  final importFileOffset = rvaToFileOffset(importRva);
  if (importFileOffset == 0) return <String>[];

  final imported = <String>[];
  var descOffset = importFileOffset;
  while (descOffset + 20 <= bytes.length) {
    final nameRva = view.getUint32(descOffset + 12, Endian.little);
    if (nameRva == 0) break;
    final nameOffset = rvaToFileOffset(nameRva);
    if (nameOffset > 0 && nameOffset < bytes.length) {
      final sb = StringBuffer();
      for (var p = nameOffset; p < bytes.length && bytes[p] != 0; p++) {
        sb.writeCharCode(bytes[p]);
      }
      final name = sb.toString();
      if (name.isNotEmpty && !imported.contains(name)) {
        imported.add(name);
      }
    }
    descOffset += 20;
  }
  return imported;
}

/// Returns any debug-CRT libraries imported by [file].
List<String> getDebugCrtImports(File file) {
  final imports = getPeImportedDlls(file);
  return imports
      .where((dll) => debugCrtDllNames.contains(dll.toLowerCase()))
      .toList();
}

/// Returns any VC++ runtime libraries imported by [file].
List<String> getVcRuntimeImports(File file) {
  final imports = getPeImportedDlls(file);
  return imports.where((dll) {
    final lower = dll.toLowerCase();
    return lower.startsWith('vcruntime') ||
        lower.startsWith('msvcp') ||
        lower.startsWith('concrt') ||
        lower.startsWith('vccorlib');
  }).toList();
}

/// Locates the x64 MSVC redistributable directory on the host machine.
Directory? findVcRedistDir() {
  // 1. Check VCToolsRedistDir environment variable (set by VS dev command prompt)
  final envRedist = Platform.environment['VCToolsRedistDir'];
  if (envRedist != null && envRedist.isNotEmpty) {
    final cand = Directory(p.join(envRedist, 'x64'));
    if (cand.existsSync()) {
      for (final sub in cand.listSync()) {
        if (sub is Directory &&
            p.basename(sub.path).toLowerCase().startsWith('microsoft.vc')) {
          return sub;
        }
      }
    }
  }

  // 2. Query vswhere.exe if installed
  final vswherePaths = <String>[
    r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
    r'C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe',
  ];
  for (final vswherePath in vswherePaths) {
    final vswhere = File(vswherePath);
    if (vswhere.existsSync()) {
      try {
        final res = Process.runSync(vswhere.path, <String>[
          '-latest',
          '-property',
          'installationPath',
        ]);
        if (res.exitCode == 0) {
          final vsPath = (res.stdout as String).trim();
          if (vsPath.isNotEmpty) {
            final redistDir = _findCrtInVs(vsPath);
            if (redistDir != null) return redistDir;
          }
        }
      } catch (_) {}
    }
  }

  // 3. Fall back to standard Visual Studio installation directories
  final searchRoots = <String>[
    r'C:\Program Files\Microsoft Visual Studio',
    r'C:\Program Files (x86)\Microsoft Visual Studio',
  ];
  for (final root in searchRoots) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final year in d.listSync()) {
      if (year is! Directory) continue;
      for (final edition in year.listSync()) {
        if (edition is! Directory) continue;
        final redistDir = _findCrtInVs(edition.path);
        if (redistDir != null) return redistDir;
      }
    }
  }
  return null;
}

Directory? _findCrtInVs(String vsPath) {
  final msvcRedist = Directory(p.join(vsPath, r'VC\Redist\MSVC'));
  if (!msvcRedist.existsSync()) return null;
  for (final verDir in msvcRedist.listSync()) {
    if (verDir is! Directory) continue;
    final x64Dir = Directory(p.join(verDir.path, 'x64'));
    if (!x64Dir.existsSync()) continue;
    for (final sub in x64Dir.listSync()) {
      if (sub is Directory &&
          p.basename(sub.path).toLowerCase().startsWith('microsoft.vc')) {
        return sub;
      }
    }
  }
  return null;
}

/// Copies core VC++ runtime redistributable DLLs to [destination].
/// Returns the list of copied files.
List<File> copyVcRuntimeDlls(Directory destination, {Directory? redistDir}) {
  final redist = redistDir ?? findVcRedistDir();
  if (redist == null || !redist.existsSync()) return <File>[];
  if (!destination.existsSync()) destination.createSync(recursive: true);

  final copied = <File>[];
  for (final name in coreVcRuntimeDlls) {
    final source = File(p.join(redist.path, name));
    if (source.existsSync()) {
      final target = File(p.join(destination.path, name));
      if (!target.existsSync() || target.lengthSync() != source.lengthSync()) {
        source.copySync(target.path);
        copied.add(target);
      }
    }
  }
  return copied;
}

/// Cleans debug-CRT dependencies (such as debug-CRT zlib.dll) from [bundleDir].
/// Returns the list of deleted file paths.
List<String> cleanDebugCrtArtifacts(Directory bundleDir) {
  if (!bundleDir.existsSync()) return <String>[];
  final cleaned = <String>[];

  // Specific check for legacy zlib.dll
  final zlib = File(p.join(bundleDir.path, 'zlib.dll'));
  if (zlib.existsSync()) {
    final debugs = getDebugCrtImports(zlib);
    if (debugs.isNotEmpty) {
      zlib.deleteSync();
      cleaned.add(zlib.path);
    }
  }

  // General check for any DLL/EXE linking debug CRT
  for (final entity in bundleDir.listSync()) {
    if (entity is File &&
        (entity.path.endsWith('.dll') || entity.path.endsWith('.exe'))) {
      if (cleaned.contains(entity.path)) continue;
      final debugs = getDebugCrtImports(entity);
      if (debugs.isNotEmpty) {
        entity.deleteSync();
        cleaned.add(entity.path);
      }
    }
  }
  return cleaned;
}

/// Result of bundle runtime verification.
class BundleRuntimeVerification {
  const BundleRuntimeVerification({
    required this.isValid,
    required this.debugCrtViolations,
    required this.bundledVcRuntimes,
    required this.requiredVcRuntimes,
    required this.missingVcRuntimes,
  });

  final bool isValid;
  final List<String> debugCrtViolations;
  final List<String> bundledVcRuntimes;
  final List<String> requiredVcRuntimes;
  final List<String> missingVcRuntimes;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'isValid': isValid,
      'vcRuntimeBundled':
          missingVcRuntimes.isEmpty && bundledVcRuntimes.isNotEmpty,
      'bundledVcRuntimes': bundledVcRuntimes,
      'missingVcRuntimes': missingVcRuntimes,
      'debugCrtViolations': debugCrtViolations,
    };
  }
}

/// Verifies that all binaries in [bundleDir] are clean of debug CRTs and checks
/// VC++ runtime redistributable bundling.
BundleRuntimeVerification verifyBundleRuntimes(Directory bundleDir) {
  if (!bundleDir.existsSync()) {
    return const BundleRuntimeVerification(
      isValid: false,
      debugCrtViolations: <String>['Bundle directory does not exist'],
      bundledVcRuntimes: <String>[],
      requiredVcRuntimes: <String>[],
      missingVcRuntimes: <String>[],
    );
  }

  final debugViolations = <String>[];
  final requiredVcRuntimes = <String>{};
  final bundledVcRuntimes = <String>[];

  for (final entity in bundleDir.listSync()) {
    if (entity is File &&
        (entity.path.endsWith('.dll') || entity.path.endsWith('.exe'))) {
      final name = p.basename(entity.path).toLowerCase();
      if (name.startsWith('msvcp') ||
          name.startsWith('vcruntime') ||
          name.startsWith('concrt')) {
        bundledVcRuntimes.add(p.basename(entity.path));
      }

      final debugs = getDebugCrtImports(entity);
      if (debugs.isNotEmpty) {
        debugViolations.add(
          '${p.basename(entity.path)} links debug CRT (${debugs.join(', ')})',
        );
      }

      final vcImports = getVcRuntimeImports(entity);
      for (final req in vcImports) {
        requiredVcRuntimes.add(req.toLowerCase());
      }
    }
  }

  final missingVcRuntimes = <String>[];
  for (final req in requiredVcRuntimes) {
    if (!bundledVcRuntimes.map((b) => b.toLowerCase()).contains(req)) {
      missingVcRuntimes.add(req);
    }
  }

  final isValid = debugViolations.isEmpty;
  return BundleRuntimeVerification(
    isValid: isValid,
    debugCrtViolations: debugViolations,
    bundledVcRuntimes: bundledVcRuntimes,
    requiredVcRuntimes: requiredVcRuntimes.toList(),
    missingVcRuntimes: missingVcRuntimes,
  );
}

/// Verifies a Windows release zip archive for runtime requirements and absence of debug CRTs.
Map<String, Object?> verifyWindowsReleaseArchive(File zipFile) {
  if (!zipFile.existsSync()) {
    return <String, Object?>{
      'isValid': false,
      'error': 'File not found: ${zipFile.path}',
    };
  }

  final archive = ZipDecoder().decodeStream(InputFileStream(zipFile.path));
  final entryNames = archive.files.map((f) => f.name).toList();
  final problems = <String>[];
  final bundledVc = <String>[];

  final hasExe = entryNames.any(
    (n) => p.basename(n).toLowerCase() == 'mpvson.exe',
  );
  if (!hasExe) {
    problems.add('Archive does not contain mpvson.exe');
  }

  for (final file in archive.files) {
    final base = p.basename(file.name).toLowerCase();
    if (debugCrtDllNames.contains(base)) {
      problems.add('Archive contains debug CRT binary: ${file.name}');
    }
    if (base.startsWith('msvcp') ||
        base.startsWith('vcruntime') ||
        base.startsWith('concrt')) {
      bundledVc.add(base);
    }

    if (base.endsWith('.dll') || base.endsWith('.exe')) {
      final bytes = file.content as List<int>;
      final debugs = getPeImportedDllsFromBytes(
        bytes,
      ).where((d) => debugCrtDllNames.contains(d.toLowerCase())).toList();
      if (debugs.isNotEmpty) {
        problems.add('${file.name} links debug CRT (${debugs.join(', ')})');
      }
    }
  }

  final hasCoreVc =
      bundledVc.contains('msvcp140.dll') &&
      bundledVc.contains('vcruntime140.dll') &&
      bundledVc.contains('vcruntime140_1.dll');

  return <String, Object?>{
    'isValid': problems.isEmpty,
    'problems': problems,
    'bundledVcRuntime': bundledVc,
    'hasCoreVcRuntime': hasCoreVc,
  };
}
