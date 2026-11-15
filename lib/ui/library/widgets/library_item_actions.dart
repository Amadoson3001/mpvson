import 'dart:io';

import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_source.dart';
// Prefixed: the class below has methods named showInFolder and openWith.
import '../../../utils/file_utils.dart' as files;
import '../../core/toast/app_toast.dart';
import '../../player/player_controller.dart';
import 'media_properties_dialog.dart';

/// Descriptor for a library item the item menus act on.
@immutable
class LibraryItemTarget {
  const LibraryItemTarget({
    required this.id,
    required this.path,
    required this.title,
    required this.kind,
    this.isAvailable = true,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.record,
  });

  factory LibraryItemTarget.fromEntry(MediaEntry entry) {
    return LibraryItemTarget(
      id: entry.id,
      path: entry.path,
      title: entry.title,
      kind: MediaCatalog.kindFromExtension(entry.path),
      duration: entry.duration,
      position: entry.position,
    );
  }

  factory LibraryItemTarget.fromRecord(
    MediaItemRecord record, {
    Duration position = Duration.zero,
  }) {
    return LibraryItemTarget(
      id: record.id,
      path: record.path,
      title: record.title,
      kind: record.kind,
      isAvailable: record.isAvailable,
      duration: record.metadata.duration,
      position: position,
      record: record,
    );
  }

  final String id;
  final String path;
  final String title;
  final MediaKind kind;
  final bool isAvailable;
  final Duration duration;
  final Duration position;
  final MediaItemRecord? record;

  bool get isNetwork => MediaEntry.isNetworkUrl(path);
}

/// The operations both library item menus offer: the row overflow menu and the
/// right-click context menu.
///
/// The two menus present the same actions and must keep the same rules — which
/// sources count as reachable, what the user is told when one is not, and which
/// toast follows a success or a failure. Presentation stays in the menus; the
/// behavior lives here so a rule change is made once.
///
/// The playlist actions are deliberately absent: the overflow menu opens the
/// add-to-playlist dialog while the context menu drives an inline submenu, so
/// they are different flows rather than shared ones.
class LibraryItemActions {
  LibraryItemActions({
    required this.target,
    required this.repository,
    required this.controller,
    required this.hostContext,
    this.onShowInFolder,
  });

  final LibraryItemTarget target;
  final MediaLibraryRepository repository;
  final PlayerController controller;

  /// Context used for toasts and dialogs. The menus pass the library context,
  /// which outlives both the popup and the overlay.
  final BuildContext hostContext;
  final ValueChanged<String>? onShowInFolder;

  /// Whether the source can be opened at all: a reachable local file, or a
  /// network or buffered source that does not need a file check.
  Future<bool> ensureSourceReachable() async {
    if (target.isNetwork) return true;
    final validation = MediaSource.validate(target.path);
    if (!validation.isValid || validation.source == null) return false;
    final normalized = MediaEntry.normalizeSourcePath(validation.source!);
    if (MediaEntry.isBufferedNetworkSource(normalized)) return true;
    try {
      return await File(normalized).exists();
    } catch (_) {
      return false;
    }
  }

  void _showUnreachable() {
    if (!hostContext.mounted) return;
    AppToast.show(
      hostContext,
      'File not found: ${target.title}',
      tone: AppToastTone.danger,
    );
  }

  /// Replaces the current queue with this item. [onPlay] lets a caller take
  /// over playback instead of opening the path directly.
  Future<void> playNow({VoidCallback? onPlay}) async {
    if (!target.isAvailable) return;
    if (onPlay != null) {
      onPlay();
      return;
    }
    try {
      await controller.openPaths([target.path], append: false, initialIndex: 0);
      if (hostContext.mounted && controller.error != null) {
        AppToast.show(
          hostContext,
          controller.error!,
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not play "${target.title}"',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  /// Queues the item, next in line when [playNext] and at the end otherwise.
  Future<void> enqueue({required bool playNext}) async {
    if (!target.isAvailable) return;
    if (!await ensureSourceReachable()) {
      _showUnreachable();
      return;
    }
    try {
      if (playNext) {
        await controller.playNext([target.path]);
      } else {
        await controller.addToQueue([target.path]);
      }
      if (!hostContext.mounted) return;
      final error = controller.error;
      AppToast.show(
        hostContext,
        error ??
            (playNext
                ? 'Playing next: ${target.title}'
                : 'Added to queue: ${target.title}'),
        tone: error != null ? AppToastTone.danger : AppToastTone.neutral,
      );
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          playNext
              ? 'Could not queue "${target.title}" next'
              : 'Could not add "${target.title}" to queue',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  /// Hands the file to the system application chooser.
  Future<void> openWith() async {
    if (!await ensureSourceReachable()) {
      _showUnreachable();
      return;
    }
    try {
      final launched = await files.openWith(target.path);
      if (!launched && hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open system app chooser',
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open system app chooser',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  /// Reveals the file in the platform file manager.
  Future<void> showInFolder() async {
    final onShow = onShowInFolder;
    if (onShow != null) {
      onShow(target.path);
      return;
    }
    try {
      final ok = await files.showInFolder(target.path);
      if (!ok && hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open File Explorer',
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open File Explorer',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  /// Opens the properties dialog for this item.
  Future<void> showProperties() async {
    if (!hostContext.mounted ||
        Navigator.maybeOf(hostContext, rootNavigator: true) == null) {
      return;
    }
    try {
      await MediaPropertiesDialog.show(
        hostContext,
        path: target.path,
        title: target.title,
        kind: target.kind,
        repository: repository,
        duration: target.duration,
        position: target.position,
        initialRecord: target.record,
        onShowInFolder: onShowInFolder,
      );
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open properties',
          tone: AppToastTone.danger,
        );
      }
    }
  }
}
