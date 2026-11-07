// Static assertions for the llvm-strip step in windows/CMakeLists.txt (B-3).
//
// flutter_windows.dll, d3dcompiler_47.dll and vulkan-1.dll ship with an
// Authenticode signature. llvm-strip rewrites the binary and invalidates the
// signature, so the CMake strip step must skip exactly those files while still
// stripping everything else (libmpv-2.dll in particular).
//
// The test re-implements the strip file-list logic (GLOB the bundle's *.dll,
// lower-case the name, skip everything in MPVSON_SIGNED_DLLS) against the
// signed list parsed out of the CMake file. No processes are launched; full
// signature verification happens at the coordinator's release build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> signedDlls = <String>[
  'flutter_windows.dll',
  'd3dcompiler_47.dll',
  'vulkan-1.dll',
];

/// DLLs a Release bundle contains after the CMake install step.
const List<String> releaseBundleDlls = <String>[
  'flutter_windows.dll',
  'd3dcompiler_47.dll',
  'vulkan-1.dll',
  'libEGL.dll',
  'libGLESv2.dll',
  'libmpv-2.dll',
  'zlib.dll',
  'media_kit_native_event_loop.dll',
];

/// Re-implements the CMake strip loop: returns the DLLs llvm-strip runs on.
List<String> filesStrippedByCMake(
  Iterable<String> bundleDlls,
  List<String> signed,
) {
  final List<String> lowerCasedSigned = signed
      .map((String name) => name.toLowerCase())
      .toList();
  return bundleDlls
      .where((String name) => !lowerCasedSigned.contains(name.toLowerCase()))
      .toList();
}

void main() {
  final String cmake = File('windows/CMakeLists.txt').readAsStringSync();

  group('windows/CMakeLists.txt llvm-strip step', () {
    test('declares the Authenticode-signed DLL skip list', () {
      final RegExpMatch? match = RegExp(
        r'set\(MPVSON_SIGNED_DLLS\s+([^)]*)\)',
      ).firstMatch(cmake);
      expect(match, isNotNull, reason: 'MPVSON_SIGNED_DLLS must be declared.');
      final List<String> declared = match!
          .group(1)!
          .trim()
          .split(RegExp(r'\s+'))
          .where((String entry) => entry.isNotEmpty)
          .toList();
      expect(declared, containsAll(signedDlls));
      expect(declared, hasLength(signedDlls.length));
    });

    test('never strips the signed DLLs by name inside the loop', () {
      // The skip decision must sit inside the foreach loop and run before the
      // strip command.
      final int loopStart = cmake.indexOf(
        'foreach(_dll IN LISTS _bundled_dlls)',
      );
      expect(loopStart, greaterThan(0), reason: 'strip loop must exist.');
      final int loopEnd = cmake.indexOf('endforeach()', loopStart);
      expect(loopEnd, greaterThan(loopStart));
      final String loop = cmake.substring(loopStart, loopEnd);
      expect(
        loop,
        contains('IN_LIST'),
        reason: 'skip decision must use IN_LIST.',
      );
      expect(
        loop,
        contains('continue()'),
        reason: 'signed DLLs must be skipped.',
      );

      final int skipIndex = loop.indexOf('IN_LIST');
      final int continueIndex = loop.indexOf('continue()');
      final int stripIndex = loop.indexOf('--strip-all');
      expect(continueIndex, greaterThan(skipIndex));
      expect(stripIndex, greaterThan(continueIndex));
      expect(
        stripIndex,
        greaterThan(0),
        reason: 'unsigned DLLs must still be stripped.',
      );
    });

    test('still strips the engine module and other unsigned DLLs', () {
      final RegExpMatch? match = RegExp(
        r'set\(MPVSON_SIGNED_DLLS\s+([^)]*)\)',
      ).firstMatch(cmake);
      final List<String> signed = match!.group(1)!.trim().split(RegExp(r'\s+'));
      final List<String> stripped = filesStrippedByCMake(
        releaseBundleDlls,
        signed,
      );
      expect(stripped, contains('libmpv-2.dll'));
      expect(stripped, contains('libEGL.dll'));
      expect(stripped, contains('media_kit_native_event_loop.dll'));
    });

    test('leaves every signed DLL untouched in a simulated Release bundle', () {
      final RegExpMatch? match = RegExp(
        r'set\(MPVSON_SIGNED_DLLS\s+([^)]*)\)',
      ).firstMatch(cmake);
      final List<String> signed = match!.group(1)!.trim().split(RegExp(r'\s+'));
      final List<String> stripped = filesStrippedByCMake(
        releaseBundleDlls,
        signed,
      );
      for (final String dll in signedDlls) {
        expect(stripped, isNot(contains(dll)));
      }
      // The comparison is case-insensitive in CMake (string(TOLOWER)); the
      // simulated logic must agree for differently-cased on-disk names.
      expect(
        filesStrippedByCMake(
          releaseBundleDlls.map((String name) => name.toUpperCase()),
          signed,
        ),
        isNot(contains('FLUTTER_WINDOWS.DLL')),
      );
    });
  });
}
