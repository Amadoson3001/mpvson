import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../domain/models/open_request.dart';
import '../repositories/app_preferences_repository.dart';

typedef OpenPreferenceDialogHandler =
    Future<OpenBehaviorPreference?> Function();

typedef PlaybackCommandHandler =
    Future<void> Function({required List<String> paths, required bool playNow});

enum OpenStatus { accepted, cancelled, rejected }

class OpenResult {
  const OpenResult(this.status, {this.rejectedCount = 0});
  final OpenStatus status;
  final int rejectedCount;
}

class _QueuedRequest {
  const _QueuedRequest(this.request, this.completer);
  final OpenRequest request;
  final Completer<OpenResult> completer;
}

/// Validates inputs, resolves opening preferences, and serializes requests before calling playback commands.
class OpenRequestCoordinator {
  OpenRequestCoordinator({
    required this.preferences,
    required this.isPlaybackActive,
    required this.executePlaybackCommand,
    required this.showPreferenceDialog,
    this.ready,
  });

  final Future<void> Function()? ready;
  final AppPreferencesRepository preferences;
  final ValueGetter<bool> isPlaybackActive;
  final PlaybackCommandHandler executePlaybackCommand;
  final OpenPreferenceDialogHandler showPreferenceDialog;

  final Queue<_QueuedRequest> _queue = Queue<_QueuedRequest>();
  bool _isProcessing = false;
  bool _isShowingDialog = false;

  /// Submits an open request to be processed in order.
  Future<OpenResult> handleOpenRequest(OpenRequest request) async {
    final completer = Completer<OpenResult>();
    _queue.add(_QueuedRequest(request, completer));
    _processNext();
    return completer.future;
  }

  void _processNext() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_queue.isNotEmpty) {
        final entry = _queue.removeFirst();
        try {
          final success = await _executeRequest(entry.request);
          if (!entry.completer.isCompleted) {
            entry.completer.complete(success);
          }
        } catch (e) {
          if (!entry.completer.isCompleted) {
            entry.completer.complete(const OpenResult(OpenStatus.rejected));
          }
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<OpenResult> _executeRequest(OpenRequest request) async {
    await ready?.call();
    final validPaths = <String>[];
    var rejected = 0;
    for (final rawPath in request.sources) {
      final source = rawPath.trim();
      if (source.isEmpty) {
        rejected++;
        continue;
      }
      try {
        final uri = Uri.tryParse(source);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          if (uri.host.isEmpty) {
            rejected++;
          } else {
            validPaths.add(source);
          }
        } else {
          final path = uri != null && uri.scheme == 'file'
              ? uri.toFilePath(windows: Platform.isWindows)
              : source;
          if (await File(path).exists()) {
            validPaths.add(path);
          } else {
            rejected++;
          }
        }
      } on Object {
        rejected++;
      }
    }

    if (validPaths.isEmpty) {
      return OpenResult(OpenStatus.rejected, rejectedCount: rejected);
    }

    // 2. If nothing is currently loaded or playing, open selection and play normally.
    final currentlyActive = isPlaybackActive();
    if (!currentlyActive) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return OpenResult(OpenStatus.accepted, rejectedCount: rejected);
    }

    // 3. Explicit intent bypasses saved preferences
    if (request.intent == OpenIntent.playNow) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return OpenResult(OpenStatus.accepted, rejectedCount: rejected);
    }
    if (request.intent == OpenIntent.enqueue) {
      await executePlaybackCommand(paths: validPaths, playNow: false);
      return OpenResult(OpenStatus.accepted, rejectedCount: rejected);
    }

    // 4. Normal intent: resolve opening preferences
    var pref = preferences.preferences.openBehavior;
    if (pref == null || pref == OpenBehaviorPreference.askEveryTime) {
      if (_isShowingDialog) {
        // Prevent overlapping dialogs; discard or queue
        return const OpenResult(OpenStatus.cancelled);
      }
      _isShowingDialog = true;
      OpenBehaviorPreference? chosen;
      try {
        chosen = await showPreferenceDialog();
      } finally {
        _isShowingDialog = false;
      }

      if (chosen == null) {
        // Closing dialog cancels request without changing playback or saving preference
        return const OpenResult(OpenStatus.cancelled);
      }

      if (pref != OpenBehaviorPreference.askEveryTime) {
        await preferences.setOpenBehavior(chosen);
      }
      pref = chosen;
    }

    if (pref == OpenBehaviorPreference.playNewFilesNow) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return OpenResult(OpenStatus.accepted, rejectedCount: rejected);
    } else {
      await executePlaybackCommand(paths: validPaths, playNow: false);
      return OpenResult(OpenStatus.accepted, rejectedCount: rejected);
    }
  }
}
