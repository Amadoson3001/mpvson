import 'dart:ffi';
import 'dart:io';

/// Native process memory trimmer for Windows.
///
/// Calls Win32 `SetProcessWorkingSetSize` to reclaim unreferenced, inactive
/// pages from the working set and return physical RAM to the operating system.
abstract final class MemoryTrimmer {
  static final DynamicLibrary? _kernel32 = () {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('kernel32.dll');
    } catch (_) {
      return null;
    }
  }();

  static final int Function(int, int, int)? _setProcessWorkingSetSize = () {
    final lib = _kernel32;
    if (lib == null) return null;
    try {
      return lib.lookupFunction<
        Int32 Function(IntPtr, IntPtr, IntPtr),
        int Function(int, int, int)
      >('SetProcessWorkingSetSize');
    } catch (_) {
      return null;
    }
  }();

  /// Requests the Windows memory manager to trim clean and inactive pages from
  /// the current process's working set. Safe no-op on non-Windows platforms.
  static void trimWorkingSet() {
    if (!Platform.isWindows) return;
    try {
      _setProcessWorkingSetSize?.call(-1, -1, -1);
    } catch (_) {}
  }
}
