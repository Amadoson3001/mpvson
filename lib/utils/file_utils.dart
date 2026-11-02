import 'dart:io';
import 'package:flutter/foundation.dart';

/// Reveals the file or directory at [path] in the native platform file manager:
/// - Windows: File Explorer with item highlighted (`explorer.exe /select,<path>`).
/// - macOS: Finder with item highlighted (`open -R <path>`).
/// - Linux: Default file manager showing parent directory (`xdg-open <dir>`).
///
/// Returns `true` if the process was launched successfully, `false` otherwise.
Future<bool> showInFolder(String path) async {
  if (path.isEmpty) return false;

  try {
    if (Platform.isWindows) {
      final normalized = path.replaceAll('/', r'\');
      final result = await Process.run('explorer.exe', [
        '/select,',
        normalized,
      ]);
      // explorer.exe returns 0 on success, or 1 in certain Windows shell invocations
      return result.exitCode == 0 || result.exitCode == 1;
    } else if (Platform.isMacOS) {
      final result = await Process.run('open', ['-R', path]);
      return result.exitCode == 0;
    } else if (Platform.isLinux) {
      final target = File(path).parent.path;
      final result = await Process.run('xdg-open', [target]);
      return result.exitCode == 0;
    }
    return false;
  } catch (error) {
    debugPrint('showInFolder failed for "$path": $error');
    return false;
  }
}
