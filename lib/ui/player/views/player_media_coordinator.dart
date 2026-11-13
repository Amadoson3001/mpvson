import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/gpu_info_service.dart';
import '../../../data/services/open_request_coordinator.dart';
import '../../../data/services/playback_statistics.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/open_request.dart';
import '../../core/components/app_dialog.dart';
import '../../core/toast/app_toast.dart';
import '../player_controller.dart';
import '../widgets/open_url_dialog.dart';
import 'playback_info_dialog.dart';
import 'settings/settings_dialog.dart';

typedef MediaFilePicker = Future<List<String>> Function();
typedef SubtitleFilePicker = Future<String?> Function();
typedef UrlPrompt = Future<String?> Function(BuildContext context);

class PlayerMediaCoordinator {
  PlayerMediaCoordinator({
    required this.getContext,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    this.openCoordinator,
    this.mediaPicker,
    this.subtitlePicker,
    this.urlPrompt,
    this.libraryRepository,
    this.appPreferences,
    this.desktopIntegration,
    required this.showMessage,
    required this.withControlsVisible,
    required this.onCloseContextMenu,
    required this.onOpenLibrary,
    required this.onClearFocusedQueueEntry,
  });

  final BuildContext Function() getContext;
  PlayerController controller;
  UpdateService updates;
  EngineUpdateService engineUpdates;
  OpenRequestCoordinator? openCoordinator;
  MediaFilePicker? mediaPicker;
  SubtitleFilePicker? subtitlePicker;
  UrlPrompt? urlPrompt;
  MediaLibraryRepository? libraryRepository;
  AppPreferencesRepository? appPreferences;
  DesktopIntegrationService? desktopIntegration;

  final void Function(String message) showMessage;
  final Future<T> Function<T>(Future<T> Function() action) withControlsVisible;
  final VoidCallback onCloseContextMenu;
  final VoidCallback onOpenLibrary;
  final VoidCallback onClearFocusedQueueEntry;

  BuildContext get context => getContext();

  Future<void> adjustPlaybackDelay({
    required bool audio,
    required bool later,
    required void Function(IconData icon, String message, {bool centered})
    showFeedback,
  }) async {
    final settings = controller.playbackSettings;
    final stepMs = appPreferences?.preferences.syncStepMs ?? 50;
    final step = later ? stepMs : -stepMs;
    final current = audio
        ? settings.audioDelaySeconds
        : settings.subtitleDelaySeconds;
    final boundedMs = ((current * 1000).round() + step).clamp(-10000, 10000);
    final next = boundedMs / 1000;
    final updated = audio
        ? settings.copyWith(audioDelaySeconds: next)
        : settings.copyWith(subtitleDelaySeconds: next);
    final suffix = boundedMs > 0 ? '+' : '';
    showFeedback(
      audio ? Icons.graphic_eq_rounded : Icons.closed_caption_rounded,
      '${audio ? 'Audio' : 'Subtitle'} delay $suffix$boundedMs ms',
      centered: true,
    );
    await controller.setPlaybackSettings(updated);
    if (controller.playbackSettingsError != null) {
      showMessage('The playback engine did not accept the delay change.');
    }
  }

  Future<void> addQueueFiles() async {
    onCloseContextMenu();
    try {
      await withControlsVisible(() async {
        final paths = await (mediaPicker == null
            ? pickMediaFiles()
            : mediaPicker!());
        if (paths.isEmpty) return;
        await openPaths(paths, append: true);
      });
    } catch (_) {
      showMessage('The file picker could not be opened.');
    }
  }

  /// Named apart from `file_selector`'s top-level `openFiles`, which
  /// [pickMediaFiles] calls: a member with that name would shadow the package
  /// function and swallow its arguments.
  Future<void> pickAndOpenFiles() async {
    onCloseContextMenu();
    try {
      final paths = await withControlsVisible(
        () => mediaPicker == null ? pickMediaFiles() : mediaPicker!(),
      );
      if (paths.isEmpty) return;
      await openPaths(paths);
    } catch (_) {
      showMessage('The file picker could not be opened.');
    }
  }

  Future<List<String>> pickMediaFiles() async {
    final mediaTypes = XTypeGroup(
      label: 'Media files',
      extensions: MediaCatalog.filePickerExtensions,
    );
    final audioVideoTypes = XTypeGroup(
      label: 'Audio and video files',
      extensions: MediaCatalog.filePickerExtensions,
    );
    final files = await openFiles(
      acceptedTypeGroups: [mediaTypes, audioVideoTypes],
    );
    return files
        .map((file) => file.path)
        .where((path) => path.isNotEmpty)
        .toList();
  }

  Future<void> openPaths(
    List<String> paths, {
    bool append = false,
    OpenOrigin origin = OpenOrigin.filePicker,
    bool playNow = false,
  }) async {
    if (paths.isEmpty) return;
    try {
      final coordinator = openCoordinator;
      if (coordinator == null) {
        await controller.openPaths(paths, append: append);
        return;
      }
      final result = await coordinator.handleOpenRequest(
        OpenRequest(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          sources: paths,
          origin: origin,
          intent: append
              ? OpenIntent.enqueue
              : playNow
              ? OpenIntent.playNow
              : OpenIntent.normal,
        ),
      );
      if (result.status == OpenStatus.rejected) {
        showMessage(
          result.message ??
              'Could not open the selected media. Check the source and try again.',
        );
      } else if (result.rejectedCount > 0) {
        showMessage(
          result.message ?? 'Some selected sources could not be opened.',
        );
      }
    } catch (_) {
      showMessage('Mpvson could not open that media.');
    }
  }

  Future<void> openUrl() async {
    onCloseContextMenu();
    final url = await withControlsVisible(
      () => urlPrompt == null
          ? AppDialog.show<String>(
              context: context,
              builder: (_) => const OpenUrlDialog(),
            )
          : urlPrompt!(context),
    );
    if (url == null || url.trim().isEmpty) return;
    await openPaths([url.trim()]);
  }

  Future<void> playRecent(MediaEntry entry) =>
      openPaths([entry.path], playNow: true);

  Future<void> removeRecent(MediaEntry entry) async {
    final ctx = context;
    try {
      final restored = controller.removeRecent(entry);
      if (restored != null && ctx.mounted) {
        AppToast.show(
          ctx,
          'Removed from recently played',
          actionLabel: 'Undo',
          onAction: () => controller.restoreRecent(restored.$1, restored.$2),
        );
      }
    } catch (_) {
      showMessage('Could not remove this item from recently played.');
    }
  }

  Future<void> clearRecent() async {
    final ctx = context;
    try {
      final cleared = controller.clearRecent();
      if (cleared.isNotEmpty && ctx.mounted) {
        AppToast.show(
          ctx,
          'Recently played cleared',
          actionLabel: 'Undo',
          onAction: () => controller.restoreRecentList(cleared),
        );
      }
    } catch (_) {
      showMessage('Could not clear recently played.');
    }
  }

  Future<String?> pickSubtitle() => withControlsVisible(() async {
    if (subtitlePicker != null) return subtitlePicker!();
    const subtitleTypes = XTypeGroup(
      label: 'Subtitle files',
      extensions: ['ass', 'idx', 'srt', 'ssa', 'sub', 'vtt'],
    );
    final file = await openFile(acceptedTypeGroups: [subtitleTypes]);
    return file?.path;
  });

  Future<void> loadSubtitle() async {
    final ctx = context;
    final String? path;
    try {
      path = await pickSubtitle();
    } catch (_) {
      showMessage('The file picker could not be opened.');
      return;
    }
    if (path == null || path.isEmpty) return;
    try {
      await controller.loadSubtitle(path);
    } catch (_) {
      if (!ctx.mounted) return;
      AppToast.show(
        ctx,
        'Mpvson could not load that subtitle file.',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> removeQueueEntryById(String id) async {
    final index = controller.queue.indexWhere((e) => e.id == id);
    if (index == -1) {
      onClearFocusedQueueEntry();
      return;
    }
    await removeQueueIndex(index);
  }

  Future<void> removeQueueIndex(int index) async {
    final ctx = context;
    try {
      await controller.removeAt(index);
      if (!ctx.mounted) return;
      onClearFocusedQueueEntry();
      AppToast.show(
        ctx,
        'Removed from queue',
        actionLabel: 'Undo',
        onAction: () => unawaited(controller.undoRemove()),
      );
    } catch (_) {
      showMessage('Could not remove this item from the queue.');
    }
  }

  Future<void> addLibraryFolder() async {
    final repository = libraryRepository;
    if (repository == null) return;
    final ctx = context;
    try {
      final path = await getDirectoryPath();
      if (path != null) await repository.addFolder(path);
    } catch (_) {
      if (!ctx.mounted) return;
      AppToast.show(
        ctx,
        'Could not add the folder. Try again.',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> showSettings({
    bool showMediaLibrary = false,
    VoidCallback? onOpenSettingsView,
    VoidCallback? onToggleVideoSettings,
  }) async {
    onCloseContextMenu();
    if (controller.hasMedia &&
        controller.isVideo &&
        !showMediaLibrary &&
        onToggleVideoSettings != null) {
      onToggleVideoSettings();
      return;
    }
    if (libraryRepository != null) {
      onOpenSettingsView?.call();
      return;
    }
    await withControlsVisible(
      () => AppDialog.show<void>(
        context: context,
        builder: (_) => SettingsDialog(
          controller: controller,
          updates: updates,
          engineUpdates: engineUpdates,
          pickSubtitle: pickSubtitle,
          appPreferences: appPreferences,
          libraryRepository: libraryRepository,
          desktopIntegration: desktopIntegration,
          showMediaLibrary: showMediaLibrary,
        ),
      ),
    );
  }

  Future<void> showPlaybackInfo() async {
    onCloseContextMenu();
    final gpuInfo = GpuInfoService();
    await withControlsVisible(
      () => AppDialog.show<void>(
        context: context,
        builder: (_) => PlaybackInfoDialog(
          readStatistics: () =>
              readNativePlaybackStatistics(controller.player, gpuInfo: gpuInfo),
        ),
      ),
    );
  }
}
