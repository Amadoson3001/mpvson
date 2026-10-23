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

class _QueuedRequest {
  const _QueuedRequest(this.request, this.completer);
  final OpenRequest request;
  final Completer<bool> completer;
}

/// Validates inputs, resolves opening preferences, and serializes requests before calling playback commands.
class OpenRequestCoordinator {
  OpenRequestCoordinator({
    required this.preferences,
    required this.isPlaybackActive,
    required this.executePlaybackCommand,
    required this.showPreferenceDialog,
  });

  final AppPreferencesRepository preferences;
  final ValueGetter<bool> isPlaybackActive;
  final PlaybackCommandHandler executePlaybackCommand;
  final OpenPreferenceDialogHandler showPreferenceDialog;

  final Queue<_QueuedRequest> _queue = Queue<_QueuedRequest>();
  bool _isProcessing = false;
  bool _isShowingDialog = false;

  /// Submits an open request to be processed in order.
  Future<bool> handleOpenRequest(OpenRequest request) async {
    final completer = Completer<bool>();
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
            entry.completer.complete(false);
          }
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<bool> _executeRequest(OpenRequest request) async {
    // 1. Validate inputs: filter out non-existent or unsupported files if they are local files
    final validPaths = <String>[];
    for (final rawPath in request.sources) {
      final trimmed = rawPath.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        validPaths.add(trimmed);
      } else {
        final file = File(trimmed);
        if (file.existsSync()) {
          validPaths.add(file.path);
        }
      }
    }

    if (validPaths.isEmpty) {
      return false;
    }

    // 2. If nothing is currently loaded or playing, open selection and play normally.
    final currentlyActive = isPlaybackActive();
    if (!currentlyActive) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return true;
    }

    // 3. Explicit intent bypasses saved preferences
    if (request.intent == OpenIntent.playNow) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return true;
    }
    if (request.intent == OpenIntent.enqueue) {
      await executePlaybackCommand(paths: validPaths, playNow: false);
      return true;
    }

    // 4. Normal intent: resolve opening preferences
    var pref = preferences.preferences.openBehavior;
    if (pref == null || pref == OpenBehaviorPreference.askEveryTime) {
      if (_isShowingDialog) {
        // Prevent overlapping dialogs; discard or queue
        return false;
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
        return false;
      }

      if (pref != OpenBehaviorPreference.askEveryTime) {
        await preferences.setOpenBehavior(chosen);
      }
      pref = chosen;
    }

    if (pref == OpenBehaviorPreference.playNewFilesNow) {
      await executePlaybackCommand(paths: validPaths, playNow: true);
      return true;
    } else {
      await executePlaybackCommand(paths: validPaths, playNow: false);
      return true;
    }
  }
}
