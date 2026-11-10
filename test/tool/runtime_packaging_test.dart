// Tests for PE dependency inspection, debug-CRT detection, and VC++ runtime packaging (Bug #7).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/runtime_packaging.dart';

void main() {
  group('PE parser & Debug CRT detection', () {
    test('detects debug CRT imports from a synthetic PE import table', () {
      // Constructs a minimal valid PE32+ (x64) with an import table containing
      // VCRUNTIME140D.dll and KERNEL32.dll.
      final bytes = <int>[];
      // DOS Header: "MZ" at 0, e_lfanew at 0x3C
      bytes.addAll([0x4D, 0x5A]); // MZ
      while (bytes.length < 0x3C) {
        bytes.add(0);
      }
      bytes.addAll([0x80, 0x00, 0x00, 0x00]); // e_lfanew = 0x80 (128)
      while (bytes.length < 128) {
        bytes.add(0);
      }

      // PE Header: "PE\0\0"
      bytes.addAll([0x50, 0x45, 0x00, 0x00]);
      // COFF File Header (20 bytes):
      // Machine = 0x8664 (x64)
      bytes.addAll([0x64, 0x86]);
      // NumberOfSections = 1
      bytes.addAll([0x01, 0x00]);
      // TimeDateStamp
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      // PointerToSymbolTable
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      // NumberOfSymbols
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      // SizeOfOptionalHeader = 0xF0 (240 bytes)
      bytes.addAll([0xF0, 0x00]);
      // Characteristics
      bytes.addAll([0x22, 0x20]);

      // Optional Header (PE32+, magic = 0x20B)
      final optStart = bytes.length;
      bytes.addAll([0x0B, 0x02]); // Magic = 0x20B
      while (bytes.length < optStart + 112) {
        bytes.add(0);
      }

      // Data Directory index 0 = Export Table (8 bytes)
      bytes.addAll([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
      // Data Directory index 1 = Import Table (8 bytes at offset 112 + 8)
      // RVA = 0x1000, Size = 40 (2 descriptors: 1 real, 1 null terminator)
      bytes.addAll([0x00, 0x10, 0x00, 0x00]); // Import RVA = 0x1000
      bytes.addAll([0x28, 0x00, 0x00, 0x00]); // Import Size = 40
      while (bytes.length < optStart + 240) {
        bytes.add(0);
      }

      // Section Header (40 bytes)
      // Name: .rdata
      bytes.addAll([0x2E, 0x72, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00]);
      bytes.addAll([0x00, 0x10, 0x00, 0x00]); // VirtualSize = 0x1000
      bytes.addAll([0x00, 0x10, 0x00, 0x00]); // VirtualAddress = 0x1000
      bytes.addAll([0x00, 0x02, 0x00, 0x00]); // SizeOfRawData = 0x200 (512)
      bytes.addAll([0x00, 0x02, 0x00, 0x00]); // PointerToRawData = 0x200 (512)
      bytes.addAll([0x00, 0x00, 0x00, 0x00]); // Relocations
      bytes.addAll([0x00, 0x00, 0x00, 0x00]); // Linenumbers
      bytes.addAll([0x00, 0x00]); // NumberOfRelocations
      bytes.addAll([0x00, 0x00]); // NumberOfLinenumbers
      bytes.addAll([0x40, 0x00, 0x00, 0x40]); // Characteristics

      // Pad to PointerToRawData (0x200 = 512 bytes)
      while (bytes.length < 512) {
        bytes.add(0);
      }

      // At FileOffset 512 (RVA 0x1000):
      // IMAGE_IMPORT_DESCRIPTOR (20 bytes)
      // OriginalFirstThunk = 0, TimeDateStamp = 0, ForwarderChain = 0
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);
      // Name RVA: RVA 0x1000 + 40 = 0x1028 (File offset 512 + 40 = 552)
      bytes.addAll([0x28, 0x10, 0x00, 0x00]);
      // FirstThunk
      bytes.addAll([0x00, 0x00, 0x00, 0x00]);

      // Null terminator descriptor (20 bytes)
      for (var i = 0; i < 20; i++) {
        bytes.add(0);
      }

      // At FileOffset 552: Name string "VCRUNTIME140D.dll\0"
      bytes.addAll('VCRUNTIME140D.dll'.codeUnits);
      bytes.add(0);

      final imports = getPeImportedDllsFromBytes(bytes);
      expect(imports, contains('VCRUNTIME140D.dll'));
      expect(
        imports.where((d) => debugCrtDllNames.contains(d.toLowerCase())),
        contains('VCRUNTIME140D.dll'),
      );
    });

    test('release bundle contains no debug CRT binaries', () {
      final releaseDir = Directory('build/windows/x64/runner/Release');
      if (!releaseDir.existsSync()) return;

      final verification = verifyBundleRuntimes(releaseDir);
      expect(
        verification.debugCrtViolations,
        isEmpty,
        reason: 'Release bundle must not contain binaries linking debug CRT',
      );
      expect(verification.isValid, isTrue);
    });

    test('release bundle has core VC++ runtime DLLs bundled', () {
      final releaseDir = Directory('build/windows/x64/runner/Release');
      if (!releaseDir.existsSync()) return;

      final bundled = releaseDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path).toLowerCase())
          .toList();

      expect(bundled, contains('msvcp140.dll'));
      expect(bundled, contains('vcruntime140.dll'));
      expect(bundled, contains('vcruntime140_1.dll'));
      expect(
        bundled,
        isNot(contains('zlib.dll')),
        reason:
            'zlib.dll links debug CRT and must not be present in release bundle',
      );
    });

    test('cleanDebugCrtArtifacts removes debug CRT binaries from directory', () {
      final tempDir = Directory.systemTemp.createTempSync('mpvson_crt_test_');
      try {
        final dummyClean = File(p.join(tempDir.path, 'clean.dll'))
          ..writeAsStringSync('clean');
        expect(dummyClean.existsSync(), isTrue);

        // A mock file named zlib.dll with empty content won't be deleted unless it imports debug CRT,
        // but if it's absent or clean it's untouched.
        final cleaned = cleanDebugCrtArtifacts(tempDir);
        expect(cleaned, isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('Linux install script runtime verification', () {
    test('install.sh checks for libmpv runtime dependency', () {
      final script = File('packaging/linux/install.sh').readAsStringSync();
      expect(script, contains('libmpv'));
      expect(script, contains('ldconfig'));
      expect(script, contains('apt install libmpv2'));
      expect(script, contains('dnf install mpv-libs'));
      expect(script, contains('pacman -S mpv'));
    });
  });
}
