import 'dart:io';

import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_source.dart';
import '../../../utils/file_utils.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_popup_menu_item.dart';
import '../../core/toast/app_toast.dart';
import '../../player/player_controller.dart';
import 'add_to_playlist_dialog.dart';
import 'media_properties_dialog.dart';

/// Actions available in the Music and Videos item overflow menu.
enum LibraryItemMenuAction {
  playNow,
  playNext,
  addToQueue,
  addToPlaylist,
  toggleFavorite,
  openWith,
  showInFolder,
  properties,
}

/// Shared overflow action menu for Music and Videos library items.
class LibraryItemActionMenu extends StatelessWidget {
  const LibraryItemActionMenu({
    super.key,
    required this.item,
    required this.repository,
    required this.controller,
    required this.libraryContext,
    required this.onShowInFolder,
    this.onFavoriteToggled,
  });

  final MediaItemRecord item;
  final MediaLibraryRepository repository;
  final PlayerController controller;
  final BuildContext libraryContext;
  final ValueChanged<String> onShowInFolder;
  final void Function(String mediaId, bool isFavorite)? onFavoriteToggled;

  Future<bool> _ensureSourceReachable() async {
    if (MediaEntry.isNetworkUrl(item.path)) return true;
    final validation = MediaSource.validate(item.path);
    if (!validation.isValid || validation.source == null) return false;
    final normalized = MediaEntry.normalizeSourcePath(validation.source!);
    if (MediaEntry.isBufferedNetworkSource(normalized)) return true;
    try {
      return await File(normalized).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _enqueueItem({required bool playNext}) async {
    final hostContext = libraryContext;
    if (!item.isAvailable) return;
    if (!await _ensureSourceReachable()) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'File not found: ${item.title}',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    try {
      if (playNext) {
        await controller.playNext([item.path]);
      } else {
        await controller.addToQueue([item.path]);
      }
      if (!hostContext.mounted) return;
      final error = controller.error;
      AppToast.show(
        hostContext,
        error ??
            (playNext
                ? 'Playing next: ${item.title}'
                : 'Added to queue: ${item.title}'),
        tone: error != null ? AppToastTone.danger : AppToastTone.neutral,
      );
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          playNext
              ? 'Could not queue "${item.title}" next'
              : 'Could not add "${item.title}" to queue',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNetwork = MediaEntry.isNetworkUrl(item.path);
    final canOpenWith = item.isAvailable && !isNetwork;

    return PopupMenuButton<LibraryItemMenuAction>(
      icon: Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: context.palette.mutedText,
      ),
      tooltip: 'Actions',
      color: context.palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: BorderSide(color: context.palette.border),
      ),
      onSelected: (action) async {
        final hostContext = libraryContext;
        switch (action) {
          case LibraryItemMenuAction.playNow:
            if (!item.isAvailable) return;
            try {
              await controller.openPaths(
                [item.path],
                append: false,
                initialIndex: 0,
              );
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
                  'Could not play "${item.title}"',
                  tone: AppToastTone.danger,
                );
              }
            }
            break;
          case LibraryItemMenuAction.playNext:
            await _enqueueItem(playNext: true);
            break;
          case LibraryItemMenuAction.addToQueue:
            await _enqueueItem(playNext: false);
            break;
          case LibraryItemMenuAction.toggleFavorite:
            final next = !item.isFavorite;
            try {
              await repository.toggleFavorite(item.id, next);
              onFavoriteToggled?.call(item.id, next);
            } catch (_) {
              if (hostContext.mounted) {
                AppToast.show(
                  hostContext,
                  'Could not update favorite state',
                  tone: AppToastTone.danger,
                );
              }
            }
            break;
          case LibraryItemMenuAction.addToPlaylist:
            if (!hostContext.mounted ||
                Navigator.maybeOf(hostContext, rootNavigator: true) == null) {
              return;
            }
            try {
              final added = await AddToPlaylistDialog.show(
                hostContext,
                repository,
                item.id,
              );
              if (!hostContext.mounted) return;
              if (added) {
                AppToast.show(
                  hostContext,
                  'Added to playlist',
                  tone: AppToastTone.success,
                  duration: const Duration(seconds: 3),
                );
              }
            } catch (_) {
              if (hostContext.mounted) {
                AppToast.show(
                  hostContext,
                  'Could not add item to playlist',
                  tone: AppToastTone.danger,
                );
              }
            }
            break;
          case LibraryItemMenuAction.openWith:
            if (!canOpenWith) return;
            if (!await _ensureSourceReachable()) {
              if (hostContext.mounted) {
                AppToast.show(
                  hostContext,
                  'File not found: ${item.title}',
                  tone: AppToastTone.danger,
                );
              }
              return;
            }
            try {
              final launched = await openWith(item.path);
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
            break;
          case LibraryItemMenuAction.showInFolder:
            onShowInFolder(item.path);
            break;
          case LibraryItemMenuAction.properties:
            if (!hostContext.mounted ||
                Navigator.maybeOf(hostContext, rootNavigator: true) == null) {
              return;
            }
            try {
              await MediaPropertiesDialog.show(
                hostContext,
                path: item.path,
                title: item.title,
                kind: item.kind,
                repository: repository,
                duration: item.metadata.duration,
                initialRecord: item,
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
            break;
        }
      },
      itemBuilder: (context) {
        final accent = Theme.of(context).colorScheme.primary;
        return [
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.playNow,
            enabled: item.isAvailable,
            icon: Icons.play_arrow_rounded,
            iconColor: accent,
            text: 'Play now',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.playNext,
            enabled: item.isAvailable,
            icon: Icons.playlist_play_rounded,
            text: 'Play next',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.addToQueue,
            enabled: item.isAvailable,
            icon: Icons.queue_music_rounded,
            text: 'Add to queue',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.addToPlaylist,
            icon: Icons.playlist_add_rounded,
            text: 'Add to playlist',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.toggleFavorite,
            icon: item.isFavorite
                ? Icons.favorite_border_rounded
                : Icons.favorite_rounded,
            iconColor: accent,
            text: item.isFavorite ? 'Remove favorite' : 'Favorite',
          ),
          const PopupMenuDivider(height: 1),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.openWith,
            enabled: canOpenWith,
            icon: Icons.open_in_new_rounded,
            text: 'Open with',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.showInFolder,
            enabled: !isNetwork,
            icon: Icons.folder_open_rounded,
            text: 'Open in File Explorer',
          ),
          AppPopupMenuItem<LibraryItemMenuAction>(
            value: LibraryItemMenuAction.properties,
            icon: Icons.info_outline_rounded,
            text: 'Properties',
          ),
        ];
      },
    );
  }
}
