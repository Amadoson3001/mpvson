import 'package:flutter/material.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../library/views/home_view.dart';
import '../../library/views/library_shell.dart';
import '../player_controller.dart';
import 'player_chrome_controller.dart';
import 'player_media_coordinator.dart';
import 'settings/settings_dialog.dart';

/// The library shell layered onto the player surface while the in-app library
/// is showing, wired to the player's media coordinator and chrome.
///
/// Extracted from `PlayerContent` so that file stays focused on stage and
/// mini-player wiring.
class PlayerEmbeddedLibrary extends StatelessWidget {
  const PlayerEmbeddedLibrary({
    super.key,
    required this.repository,
    required this.controller,
    required this.media,
    required this.chrome,
    required this.updates,
    required this.engineUpdates,
    required this.appPreferences,
    required this.libraryRepository,
    required this.desktopIntegration,
    required this.homeNavigationRequest,
    required this.draggingFiles,
    required this.settingsOpen,
    required this.onSettingsOpened,
    required this.onSettingsClosed,
    required this.onReturnToPlayerAnimated,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final PlayerMediaCoordinator media;
  final PlayerChromeController chrome;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final AppPreferencesRepository? appPreferences;
  final MediaLibraryRepository? libraryRepository;
  final DesktopIntegrationService? desktopIntegration;
  final int homeNavigationRequest;
  final bool draggingFiles;
  final bool settingsOpen;
  final VoidCallback onSettingsOpened;
  final VoidCallback onSettingsClosed;
  final VoidCallback onReturnToPlayerAnimated;

  @override
  Widget build(BuildContext context) {
    final canReturnToPlayer = controller.hasMedia && controller.isVideo;
    return LibraryShell(
      repository: repository,
      controller: controller,
      initialSection: LibrarySection.home,
      homeNavigationRequest: homeNavigationRequest,
      queueOpen: chrome.queueOpen,
      onQueueOpenChanged: chrome.setQueueOpen,
      home: HomeView(
        repository: repository,
        controller: controller,
        recent: controller.recent,
        onOpenFiles: media.pickAndOpenFiles,
        onOpenUrl: media.openUrl,
        onOpenRecent: media.playRecent,
        onRemoveRecent: media.removeRecent,
        onClearRecent: media.clearRecent,
        isDragging: draggingFiles,
      ),
      onOpenFiles: media.pickAndOpenFiles,
      onOpenUrl: media.openUrl,
      onAddQueueFiles: media.addQueueFiles,
      onBackToPlayer: canReturnToPlayer ? onReturnToPlayerAnimated : null,
      onAddFolders: media.addLibraryFolder,
      showSettings: settingsOpen,
      onSettings: onSettingsOpened,
      onCloseSettings: onSettingsClosed,
      folders: LibraryFoldersView(repository: repository),
      settings: SettingsDialog(
        controller: controller,
        updates: updates,
        engineUpdates: engineUpdates,
        pickSubtitle: media.pickSubtitle,
        appPreferences: appPreferences,
        libraryRepository: libraryRepository,
        desktopIntegration: desktopIntegration,
        embedded: true,
        onClose: onSettingsClosed,
      ),
    );
  }
}
