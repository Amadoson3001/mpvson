import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_popup_menu_item.dart';
import '../../core/toast/app_toast.dart';
import '../../player/player_controller.dart';
import 'add_to_playlist_dialog.dart';
import 'library_item_actions.dart';

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

  LibraryItemActions get _actions => LibraryItemActions(
    target: LibraryItemTarget.fromRecord(item),
    repository: repository,
    controller: controller,
    hostContext: libraryContext,
    onShowInFolder: onShowInFolder,
  );

  @override
  Widget build(BuildContext context) {
    final isNetwork = LibraryItemTarget.fromRecord(item).isNetwork;
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
        final actions = _actions;
        switch (action) {
          case LibraryItemMenuAction.playNow:
            await actions.playNow();
            break;
          case LibraryItemMenuAction.playNext:
            await actions.enqueue(playNext: true);
            break;
          case LibraryItemMenuAction.addToQueue:
            await actions.enqueue(playNext: false);
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
            await actions.openWith();
            break;
          case LibraryItemMenuAction.showInFolder:
            await actions.showInFolder();
            break;
          case LibraryItemMenuAction.properties:
            await actions.showProperties();
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
