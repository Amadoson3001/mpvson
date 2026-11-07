import 'dart:io';

import 'package:flutter/foundation.dart';

/// Runs an external process. Injectable so tests (and embedders) never launch
/// a real file manager by accident; defaults to [Process.run].
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Reveals the file or directory at [path] in the native platform file manager:
/// - Windows: File Explorer with item highlighted (`explorer.exe /select,<path>`).
/// - macOS: Finder with item highlighted (`open -R <path>`).
/// - Linux: Default file manager showing parent directory (`xdg-open <dir>`).
///
/// Returns `true` if the process was launched successfully, `false` otherwise.
Future<bool> showInFolder(String path, {ProcessRunner? processRunner}) async {
  final runner = processRunner ?? Process.run;
  final trimmed = path.trim();
  if (trimmed.isEmpty) return false;

  try {
    if (Platform.isWindows) {
      final normalized = trimmed.replaceAll('/', r'\');
      // `/select,<path>` must be passed as ONE argument: splitting it makes
      // Explorer open the user's home directory instead of highlighting the
      // requested item.
      final result = await runner('explorer.exe', <String>[
        '/select,$normalized',
      ]);
      // explorer.exe returns 0 on success, or 1 in certain Windows shell invocations
      return result.exitCode == 0 || result.exitCode == 1;
    } else if (Platform.isMacOS) {
      final result = await runner('open', ['-R', trimmed]);
      return result.exitCode == 0;
    } else if (Platform.isLinux) {
      final target = File(trimmed).parent.path;
      final result = await runner('xdg-open', [target]);
      return result.exitCode == 0;
    }
    return false;
  } catch (error) {
    debugPrint('showInFolder failed for "$path": $error');
    return false;
  }
}
