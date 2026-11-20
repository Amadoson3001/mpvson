import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
import '../../../domain/models/media_source.dart';
import '../../../domain/models/open_request.dart';
import '../../../utils/file_utils.dart';
import '../../core/components/app_dialog.dart';
import '../../core/toast/app_toast.dart';
import '../player_controller.dart';
import '../widgets/open_url_dialog.dart';
import 'playback_info_dialog.dart';
import 'settings/settings_dialog.dart';

typedef MediaFilePicker = Future<List<String>> Function();
typedef SubtitleFilePicker = Future<String?> Function();
typedef UrlPrompt = Future<String?> Function(BuildContext context);
typedef ScreenshotWriter =
    Future<String?> Function(Uint8List bytes, String suggestedName);

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
    this.screenshotWriter,
    this.revealInFolder,
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
  ScreenshotWriter? screenshotWriter;
  Future<bool> Function(String path)? revealInFolder;
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
    final files = await openFiles(acceptedTypeGroups: [mediaTypes]);
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

  Future<void> openUrl({bool defaultEnqueue = false}) async {
    onCloseContextMenu();
    if (urlPrompt != null) {
      final url = await withControlsVisible(() => urlPrompt!(context));
      if (url == null || url.trim().isEmpty) return;
      await openPaths([url.trim()], append: defaultEnqueue);
      return;
    }
    final recentUrls = controller.saveNetworkUrls
        ? controller.recent
              .where((entry) => MediaSource.isNetworkUrl(entry.path))
              .take(4)
              .toList(growable: false)
        : const <MediaEntry>[];
    final result = await withControlsVisible(
      () => OpenUrlDialog.show(
        context,
        allowEnqueue: true,
        recentUrls: recentUrls,
      ),
    );
    if (result == null || result.url.trim().isEmpty) return;
    await openPaths([
      result.url.trim(),
    ], append: defaultEnqueue || result.enqueue);
  }

  Future<void> addQueueUrl() => openUrl(defaultEnqueue: true);

  Future<void> handleDroppedPaths(
    List<String> paths, {
    bool append = false,
  }) async {
    if (paths.isEmpty) return;
    final subtitlePaths = <String>[];
    final mediaPaths = <String>[];
    for (final path in paths) {
      if (MediaCatalog.isSubtitleFile(path)) {
        subtitlePaths.add(path);
      } else {
        mediaPaths.add(path);
      }
    }
    if (mediaPaths.isNotEmpty) {
      await openPaths(
        mediaPaths,
        append: append,
        origin: OpenOrigin.dragAndDrop,
      );
    }
    if (subtitlePaths.isEmpty) return;
    final ctx = context;
    if (!controller.hasMedia && mediaPaths.isEmpty) {
      if (ctx.mounted) {
        AppToast.show(ctx, 'Open a video first to load subtitles.');
      }
      return;
    }
    for (final subtitle in subtitlePaths) {
      await controller.loadSubtitle(subtitle);
    }
    if (ctx.mounted && controller.error == null) {
      AppToast.show(
        ctx,
        subtitlePaths.length == 1
            ? 'Subtitle loaded'
            : 'Loaded ${subtitlePaths.length} subtitles',
      );
    }
  }

  Future<void> saveScreenshot() async {
    onCloseContextMenu();
    final ctx = context;
    if (!controller.hasMedia || controller.isAudio) {
      if (ctx.mounted) {
        AppToast.show(
          ctx,
          'Screenshots are only available while a video is open.',
        );
      }
      return;
    }
    final bytes = await controller.captureFrame();
    if (bytes == null || bytes.isEmpty) {
      if (ctx.mounted) {
        AppToast.show(
          ctx,
          'Could not capture the current frame.',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    final suggestedName = _screenshotFileName(controller.current?.title);
    String? savedPath;
    try {
      if (screenshotWriter != null) {
        savedPath = await screenshotWriter!(bytes, suggestedName);
      } else {
        savedPath = await _writeScreenshotFile(bytes, suggestedName);
      }
    } catch (_) {
      if (ctx.mounted) {
        AppToast.show(
          ctx,
          'Could not save the screenshot.',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    if (!ctx.mounted) return;
    if (savedPath == null || savedPath.isEmpty) {
      AppToast.show(
        ctx,
        'Could not save the screenshot.',
        tone: AppToastTone.danger,
      );
      return;
    }
    final targetPath = savedPath;
    AppToast.show(
      ctx,
      'Screenshot saved',
      actionLabel: 'Show in folder',
      onAction: () => unawaited(_revealPath(targetPath)),
    );
  }

  Future<void> copyCurrentUrl() async {
    onCloseContextMenu();
    final current = controller.current;
    if (current == null || !MediaSource.isNetworkUrl(current.path)) return;
    await Clipboard.setData(ClipboardData(text: current.path));
    final ctx = context;
    if (ctx.mounted) {
      AppToast.show(ctx, 'Stream URL copied');
    }
  }

  Future<void> showCurrentInFolder() async {
    onCloseContextMenu();
    final current = controller.current;
    if (current == null || MediaSource.isNetworkUrl(current.path)) return;
    await _revealPath(current.path);
  }

  Future<void> _revealPath(String path) async {
    final ctx = context;
    final ok = await (revealInFolder ?? showInFolder)(path);
    if (!ok && ctx.mounted) {
      AppToast.show(
        ctx,
        'Could not open File Explorer.',
        tone: AppToastTone.danger,
      );
    }
  }

  static String _screenshotFileName(String? rawTitle) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final clean = (rawTitle ?? 'frame')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\- ]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final prefix = clean.isEmpty
        ? 'frame'
        : (clean.length > 40 ? clean.substring(0, 40) : clean);
    return 'mpvson_${prefix}_$stamp.jpg';
  }

  static Future<String> _writeScreenshotFile(
    Uint8List bytes,
    String fileName,
  ) async {
    Directory? baseDir;
    final userProfile = Platform.environment['USERPROFILE'];
    if (Platform.isWindows && userProfile != null && userProfile.isNotEmpty) {
      final pictures = Directory(p.join(userProfile, 'Pictures'));
      if (await pictures.exists()) {
        baseDir = pictures;
      }
    }
    baseDir ??= await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(baseDir.path, 'Mpvson Screenshots'));
    await folder.create(recursive: true);
    final outFile = File(p.join(folder.path, fileName));
    await outFile.writeAsBytes(bytes, flush: true);
    return outFile.path;
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
    final subtitleTypes = XTypeGroup(
      label: 'Subtitle files',
      extensions: MediaCatalog.subtitleExtensions.toList()..sort(),
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
          readStatistics: () => readNativePlaybackStatistics(
            controller.player,
            gpuInfo: gpuInfo,
            streamPlaybackState: controller.transportState.streamPlaybackState,
            videoController: controller.hasMedia && controller.isVideo
                ? controller.videoController
                : null,
          ),
        ),
      ),
    );
  }
}
