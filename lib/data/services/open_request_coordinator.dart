import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../domain/models/media_catalog.dart';
import '../../domain/models/open_request.dart';
import '../repositories/app_preferences_repository.dart';

typedef OpenPreferenceDialogHandler =
    Future<OpenBehaviorPreference?> Function();

typedef PlaybackCommandHandler =
    Future<void> Function({required List<String> paths, required bool playNow});

/// Expands a folder into the playable media files it contains.
typedef FolderExpander = Future<List<String>> Function(String folderPath);

enum OpenStatus { accepted, cancelled, rejected }

class OpenResult {
  const OpenResult(this.status, {this.rejectedCount = 0, this.message});

  final OpenStatus status;
  final int rejectedCount;

  /// Optional user-facing explanation, e.g. when a dropped folder could not
  /// be opened and the user is pointed at the library settings instead of
  /// receiving a silent no-op.
  final String? message;
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
    this.expandFolder,
  });

  /// Shown when an opened folder contains no playable media, so the request
  /// fails with a concrete instruction instead of a silent no-op.
  static const String folderNotPlayableMessage =
      'That folder has no playable media files. Add folders in Settings to '
      'scan their media into the library.';

  /// Bounded folder expansion so dropping a huge tree cannot stall the queue.
  static const int _maxExpandedFolderFiles = 500;
  static const int _maxFolderExpansionDepth = 8;

  final Future<void> Function()? ready;
  final AppPreferencesRepository preferences;
  final ValueGetter<bool> isPlaybackActive;
  final PlaybackCommandHandler executePlaybackCommand;
  final OpenPreferenceDialogHandler showPreferenceDialog;

  /// Injectable folder expansion for tests and alternate catalog sources.
  /// Defaults to a bounded walk using [MediaCatalog.isSupportedFile].
  final FolderExpander? expandFolder;

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
    String? message;
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
          } else if (expandFolder != null) {
            // A custom expander (e.g. catalog-backed) may resolve folders
            // that are not plain local directories.
            final media = await expandFolder!(path);
            if (media.isEmpty) {
              rejected++;
              message ??= folderNotPlayableMessage;
            } else {
              validPaths.addAll(media);
            }
          } else if (await Directory(path).exists()) {
            // A dropped or opened folder expands into the playable media it
            // contains; when it holds none, explain how folders are added.
            final media = await _defaultExpandFolder(path);
            if (media.isEmpty) {
              rejected++;
              message ??= folderNotPlayableMessage;
            } else {
              validPaths.addAll(media);
            }
          } else {
            rejected++;
          }
        }
      } on Object {
        rejected++;
      }
    }

    // Dropping a folder alongside one of its own files would otherwise queue
    // the same media twice.
    final dedupedPaths = <String>[];
    final seenPaths = <String>{};
    for (final path in validPaths) {
      final identity = Platform.isWindows ? path.toLowerCase() : path;
      if (seenPaths.add(identity)) dedupedPaths.add(path);
    }

    if (dedupedPaths.isEmpty) {
      return OpenResult(
        OpenStatus.rejected,
        rejectedCount: rejected,
        message: message,
      );
    }

    // 2. If nothing is currently loaded or playing, open selection and play normally.
    final currentlyActive = isPlaybackActive();
    if (!currentlyActive) {
      await executePlaybackCommand(paths: dedupedPaths, playNow: true);
      return OpenResult(
        OpenStatus.accepted,
        rejectedCount: rejected,
        message: message,
      );
    }

    // 3. Explicit intent bypasses saved preferences
    if (request.intent == OpenIntent.playNow) {
      await executePlaybackCommand(paths: dedupedPaths, playNow: true);
      return OpenResult(
        OpenStatus.accepted,
        rejectedCount: rejected,
        message: message,
      );
    }
    if (request.intent == OpenIntent.enqueue) {
      await executePlaybackCommand(paths: dedupedPaths, playNow: false);
      return OpenResult(
        OpenStatus.accepted,
        rejectedCount: rejected,
        message: message,
      );
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
      await executePlaybackCommand(paths: dedupedPaths, playNow: true);
      return OpenResult(
        OpenStatus.accepted,
        rejectedCount: rejected,
        message: message,
      );
    } else {
      await executePlaybackCommand(paths: dedupedPaths, playNow: false);
      return OpenResult(
        OpenStatus.accepted,
        rejectedCount: rejected,
        message: message,
      );
    }
  }

  /// Default folder expansion: a depth- and count-bounded walk that collects
  /// files recognized by the [MediaCatalog], sorted for deterministic order.
  Future<List<String>> _defaultExpandFolder(String folderPath) async {
    final found = <String>[];
    final pending = Queue<({String path, int depth})>()
      ..add((path: folderPath, depth: 0));
    final visitedDirectories = <String>{folderPath};
    while (pending.isNotEmpty && found.length < _maxExpandedFolderFiles) {
      final current = pending.removeFirst();
      final List<FileSystemEntity> children;
      try {
        children = await Directory(
          current.path,
        ).list(followLinks: false).toList();
      } on FileSystemException {
        continue;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        if (found.length >= _maxExpandedFolderFiles) break;
        // `type` returns notFound for entries that disappear mid-walk.
        final type = await FileSystemEntity.type(
          child.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (current.depth + 1 < _maxFolderExpansionDepth &&
              visitedDirectories.add(child.path)) {
            pending.add((path: child.path, depth: current.depth + 1));
          }
          continue;
        }
        if (type == FileSystemEntityType.file &&
            MediaCatalog.isSupportedFile(child.path)) {
          found.add(child.path);
        }
      }
    }
    return found;
  }
}
