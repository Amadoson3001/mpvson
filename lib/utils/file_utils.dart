import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Runs an external process. Injectable so embedders and tests never launch a
/// real file manager by accident; defaults to [Process.run].
typedef ShowInFolderRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Resolves the filesystem entity type at [path].
typedef EntityTypeResolver = Future<FileSystemEntityType> Function(String path);

const _nonLocalSchemes = <String>{
  'http',
  'https',
  'rtsp',
  'rtsps',
  'rtmp',
  'udp',
  'mms',
  'smb',
  'ftp',
  'data',
  'blob',
};

/// Removes Windows extended-length prefixes (`\\?\` and `\\?\UNC\`) so shell
/// APIs and Explorer receive standard Win32/UNC paths.
String stripWindowsLongPathPrefix(String source) {
  const longPrefix = r'\\?\';
  const uncPrefix = r'\\?\UNC\';
  if (source.startsWith(uncPrefix)) {
    return '\\\\${source.substring(uncPrefix.length)}';
  }
  if (source.startsWith(longPrefix) &&
      source.length > longPrefix.length &&
      !source.substring(longPrefix.length).startsWith('UNC')) {
    return source.substring(longPrefix.length);
  }
  return source;
}

/// Normalizes [rawPath] (including `file://` URIs, `\\?\` prefixes, mixed
/// slashes, relative segments, and UNC/SMB paths) into a clean local
/// filesystem path, or returns `null` if [rawPath] is empty or a network URL.
String? normalizeLocalPath(
  String rawPath, {
  @visibleForTesting bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return null;

  var candidate = stripWindowsLongPathPrefix(trimmed);
  final isUncLike = candidate.startsWith(r'\\') || candidate.startsWith('//');

  if (!isUncLike) {
    final uri = Uri.tryParse(candidate);
    if (uri != null && uri.scheme.length > 1) {
      final scheme = uri.scheme.toLowerCase();
      if (scheme == 'file') {
        try {
          candidate = uri.toFilePath(windows: windows);
        } on UnsupportedError {
          candidate = uri.path;
        }
        candidate = stripWindowsLongPathPrefix(candidate);
      } else if (_nonLocalSchemes.contains(scheme) || uri.hasAuthority) {
        return null;
      } else {
        return null;
      }
    }
  }

  if (windows) {
    if (candidate.startsWith('/') &&
        candidate.length > 2 &&
        RegExp(r'^[a-zA-Z]:').hasMatch(candidate.substring(1))) {
      candidate = candidate.substring(1);
    }
    candidate = candidate.replaceAll('/', r'\');
    if (candidate.length == 2 && RegExp(r'^[a-zA-Z]:$').hasMatch(candidate)) {
      candidate = '$candidate\\';
    }
    final ctx = p.windows;
    final resolved = ctx.isAbsolute(candidate)
        ? candidate
        : ctx.absolute(candidate);
    return ctx.normalize(resolved);
  }

  final ctx = p.posix;
  final resolved = ctx.isAbsolute(candidate)
      ? candidate
      : ctx.absolute(candidate);
  return ctx.normalize(resolved);
}

class _RevealTarget {
  const _RevealTarget({required this.path, required this.isDirectory});

  final String path;
  final bool isDirectory;
}

Future<_RevealTarget?> _resolveRevealTarget(
  String normalizedPath,
  EntityTypeResolver resolveType,
  p.Context pathContext,
) async {
  try {
    final type = await resolveType(normalizedPath);
    if (type == FileSystemEntityType.file) {
      return _RevealTarget(path: normalizedPath, isDirectory: false);
    }
    if (type == FileSystemEntityType.directory) {
      return _RevealTarget(path: normalizedPath, isDirectory: true);
    }
  } catch (_) {
    // Fall through to parent-directory fallback if direct stat fails.
  }

  // Missing file or broken link: walk up until an existing ancestor directory.
  var previous = normalizedPath;
  var current = pathContext.dirname(normalizedPath);
  while (current.isNotEmpty && current != previous) {
    try {
      final parentType = await resolveType(current);
      if (parentType == FileSystemEntityType.directory) {
        return _RevealTarget(path: current, isDirectory: true);
      }
    } catch (_) {}
    previous = current;
    current = pathContext.dirname(current);
  }
  return null;
}

/// Reveals the file or directory at [path] in the native platform file manager:
/// - Windows: File Explorer highlighting the file (via Win32 `ShellExecuteW`
///   launching `explorer.exe /select,"<path>"`), or opening the directory /
///   nearest existing parent folder.
/// - macOS: Finder highlighting the file (`open -R <path>`) or opening the
///   directory (`open <dir>`).
/// - Linux: Default file manager opening the parent directory (or directory
///   itself) via `xdg-open <dir>`.
///
/// Returns `true` if the target was revealed or opened successfully.
Future<bool> showInFolder(
  String path, {
  ShowInFolderRunner? processRunner,
  @visibleForTesting EntityTypeResolver? entityTypeResolver,
}) async {
  final normalized = normalizeLocalPath(path);
  if (normalized == null) return false;

  final resolveType =
      entityTypeResolver ?? (target) => FileSystemEntity.type(target);
  final pathContext = Platform.isWindows ? p.windows : p.posix;
  final target = await _resolveRevealTarget(
    normalized,
    resolveType,
    pathContext,
  );
  if (target == null) return false;

  try {
    if (Platform.isWindows) {
      if (processRunner == null) {
        final targetPath = target.path;
        final isDirectory = target.isDirectory;
        final revealed = await Isolate.run(
          () => _WindowsShell.revealPath(targetPath, isDirectory: isDirectory),
        );
        if (revealed) return true;
      }

      final args = target.isDirectory
          ? <String>[target.path]
          : <String>['/select,${target.path}'];

      if (processRunner != null) {
        final result = await processRunner('explorer.exe', args);
        // explorer.exe returns 0 on success, or 1 in certain shell invocations.
        return result.exitCode == 0 || result.exitCode == 1;
      }

      await Process.start(
        'explorer.exe',
        args,
        mode: ProcessStartMode.detached,
      );
      return true;
    } else if (Platform.isMacOS) {
      final runner = processRunner ?? Process.run;
      final args = target.isDirectory
          ? <String>[target.path]
          : <String>['-R', target.path];
      final result = await runner('open', args);
      return result.exitCode == 0;
    } else if (Platform.isLinux) {
      final runner = processRunner ?? Process.run;
      final dirPath = target.isDirectory
          ? target.path
          : pathContext.dirname(target.path);
      final result = await runner('xdg-open', <String>[dirPath]);
      return result.exitCode == 0;
    }
    return false;
  } catch (error) {
    developer.log('$error', name: 'showInFolder', error: error);
    return false;
  }
}

/// Opens the native system "Open with" chooser (or platform fallback) for the
/// file at [path].
///
/// Uses [Process.start] in detached mode so external app pickers never block
/// the Flutter UI thread. Returns `true` if the launcher started cleanly.
Future<bool> openWith(String path) async {
  final normalized = normalizeLocalPath(path);
  if (normalized == null) return false;

  try {
    final type = await FileSystemEntity.type(normalized);
    if (type == FileSystemEntityType.notFound) return false;

    if (Platform.isWindows) {
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final openWithExe = p.join(systemRoot, 'System32', 'OpenWith.exe');
      if (await File(openWithExe).exists()) {
        await Process.start(openWithExe, <String>[
          normalized,
        ], mode: ProcessStartMode.detached);
        return true;
      }
      await Process.start('rundll32.exe', <String>[
        'shell32.dll,OpenAs_RunDLL',
        normalized,
      ], mode: ProcessStartMode.detached);
      return true;
    } else if (Platform.isMacOS) {
      await Process.start('open', <String>[
        '-R',
        normalized,
      ], mode: ProcessStartMode.detached);
      return true;
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', <String>[
        normalized,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    return false;
  } catch (error) {
    developer.log('$error', name: 'openWith', error: error);
    return false;
  }
}

abstract final class _WindowsShell {
  static const int _coinitApartmentThreaded = 0x2;
  static const int _coinitDisableOle1Dde = 0x4;
  static const int _sOk = 0;
  static const int _sFalse = 1;
  static const int _swShowNormal = 1;

  static final int Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
    int,
    Pointer<Uint32>,
  )?
  _shParseDisplayName = _lookupShellParseDisplayName();

  static final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)?
  _shOpenFolderAndSelectItems = _lookupOpenFolderAndSelectItems();

  static final void Function(Pointer<Void>)? _ilFree = _lookupIlFree();

  static DynamicLibrary? _tryOpenShell32() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('shell32.dll');
    } catch (_) {
      return null;
    }
  }

  static final DynamicLibrary? _shell32 = _tryOpenShell32();

  static int Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
    int,
    Pointer<Uint32>,
  )?
  _lookupShellParseDisplayName() {
    final lib = _shell32;
    if (lib == null) return null;
    try {
      return lib.lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Uint32>,
        )
      >('SHParseDisplayName');
    } catch (_) {
      return null;
    }
  }

  static int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)?
  _lookupOpenFolderAndSelectItems() {
    final lib = _shell32;
    if (lib == null) return null;
    try {
      return lib.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int)
      >('SHOpenFolderAndSelectItems');
    } catch (_) {
      return null;
    }
  }

  static void Function(Pointer<Void>)? _lookupIlFree() {
    final lib = _shell32;
    if (lib == null) return null;
    try {
      return lib.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('ILFree');
    } catch (_) {
      return null;
    }
  }

  static bool _selectFileWithShellItem(_Bindings b, String filePath) {
    final parseDisplayName = _shParseDisplayName;
    final openFolderAndSelect = _shOpenFolderAndSelectItems;
    final ilFree = _ilFree;
    if (parseDisplayName == null ||
        openFolderAndSelect == null ||
        ilFree == null) {
      return false;
    }

    final cleanPath = stripWindowsLongPathPrefix(filePath);
    final pathPtr = _allocUtf16(b, cleanPath);
    final ppidl = b.coTaskMemAlloc(sizeOf<IntPtr>()).cast<Pointer<Void>>();
    if (pathPtr == nullptr || ppidl == nullptr) {
      if (pathPtr != nullptr) b.coTaskMemFree(pathPtr.cast());
      if (ppidl != nullptr) b.coTaskMemFree(ppidl.cast());
      return false;
    }
    ppidl.value = nullptr;

    try {
      final hrParse = parseDisplayName(
        pathPtr.cast(),
        nullptr,
        ppidl,
        0,
        nullptr,
      );
      final pidl = ppidl.value;
      if (hrParse < 0 || pidl == nullptr) return false;
      try {
        final hrSelect = openFolderAndSelect(pidl, 0, nullptr, 0);
        return hrSelect >= 0;
      } finally {
        ilFree(pidl);
      }
    } finally {
      b.coTaskMemFree(pathPtr.cast());
      b.coTaskMemFree(ppidl.cast());
    }
  }

  static final _Bindings? _bindings = _loadBindings();

  static _Bindings? _loadBindings() {
    if (!Platform.isWindows) return null;
    try {
      final ole32 = DynamicLibrary.open('ole32.dll');
      final shell32 = DynamicLibrary.open('shell32.dll');
      return _Bindings(
        coInitializeEx: ole32
            .lookupFunction<
              Int32 Function(Pointer<Void>, Uint32),
              int Function(Pointer<Void>, int)
            >('CoInitializeEx'),
        coUninitialize: ole32.lookupFunction<Void Function(), void Function()>(
          'CoUninitialize',
        ),
        coTaskMemAlloc: ole32
            .lookupFunction<
              Pointer<Uint16> Function(IntPtr),
              Pointer<Uint16> Function(int)
            >('CoTaskMemAlloc'),
        coTaskMemFree: ole32
            .lookupFunction<
              Void Function(Pointer<Void>),
              void Function(Pointer<Void>)
            >('CoTaskMemFree'),
        shellExecuteW: shell32
            .lookupFunction<
              IntPtr Function(
                Pointer<Void>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                Int32,
              ),
              int Function(
                Pointer<Void>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                Pointer<Uint16>,
                int,
              )
            >('ShellExecuteW'),
      );
    } catch (_) {
      return null;
    }
  }

  static Pointer<Uint16> _allocUtf16(_Bindings b, String text) {
    final units = text.codeUnits;
    final ptr = b.coTaskMemAlloc((units.length + 1) * 2);
    if (ptr == nullptr) return nullptr;
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  static bool revealPath(String rawPath, {required bool isDirectory}) {
    final b = _bindings;
    if (b == null) return false;

    final hrInit = b.coInitializeEx(
      nullptr,
      _coinitApartmentThreaded | _coinitDisableOle1Dde,
    );
    final shouldUninit = hrInit == _sOk || hrInit == _sFalse;
    try {
      final cleanPath = stripWindowsLongPathPrefix(rawPath);
      final verbPtr = _allocUtf16(b, 'open');
      final filePtr = _allocUtf16(b, isDirectory ? cleanPath : 'explorer.exe');
      // Launch Explorer asynchronously with /select,"<path>" first so the shell
      // opens immediately without blocking in synchronous COM namespace walks.
      // Quotes wrap only the path (never /select,) so spaces/commas/& work.
      final paramsPtr = isDirectory
          ? nullptr
          : _allocUtf16(b, '/select,"${cleanPath.replaceAll('"', '')}"');
      if (verbPtr != nullptr &&
          filePtr != nullptr &&
          (isDirectory || paramsPtr != nullptr)) {
        try {
          if (isDirectory || cleanPath.length < 260) {
            final result = b.shellExecuteW(
              nullptr,
              verbPtr,
              filePtr,
              paramsPtr,
              nullptr,
              _swShowNormal,
            );
            if (result > 32) return true;
          }
        } finally {
          b.coTaskMemFree(verbPtr.cast());
          b.coTaskMemFree(filePtr.cast());
          if (paramsPtr != nullptr) b.coTaskMemFree(paramsPtr.cast());
        }
      } else {
        if (verbPtr != nullptr) b.coTaskMemFree(verbPtr.cast());
        if (filePtr != nullptr) b.coTaskMemFree(filePtr.cast());
        if (paramsPtr != nullptr) b.coTaskMemFree(paramsPtr.cast());
      }

      if (!isDirectory && _selectFileWithShellItem(b, cleanPath)) {
        return true;
      }
      return false;
    } catch (error) {
      developer.log('$error', name: 'showInFolder.win32', error: error);
      return false;
    } finally {
      if (shouldUninit) {
        b.coUninitialize();
      }
    }
  }
}

class _Bindings {
  const _Bindings({
    required this.coInitializeEx,
    required this.coUninitialize,
    required this.coTaskMemAlloc,
    required this.coTaskMemFree,
    required this.shellExecuteW,
  });

  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;
  final Pointer<Uint16> Function(int) coTaskMemAlloc;
  final void Function(Pointer<Void>) coTaskMemFree;
  final int Function(
    Pointer<Void>,
    Pointer<Uint16>,
    Pointer<Uint16>,
    Pointer<Uint16>,
    Pointer<Uint16>,
    int,
  )
  shellExecuteW;
}
