import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'data/repositories/app_preferences_repository.dart';
import 'data/repositories/media_library_repository.dart';
import 'data/services/desktop_integration_service.dart';
import 'data/services/engine_update_service.dart';
import 'data/services/update_service.dart';
import 'ui/core/app_theme.dart';
import 'ui/player/player_controller.dart';
import 'ui/player/views/player_screen.dart'
    show PlayerScreen, PlayerVideoBuilder, FullscreenSetter, SubtitleFilePicker;

class MpvsonApp extends StatelessWidget {
  const MpvsonApp({
    super.key,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    this.desktopWindow = false,
    this.videoBuilder,
    this.enableNativeDrop = true,
    this.fullscreenSetter,
    this.subtitlePicker,
    this.navigatorKey,
    this.appPreferences,
    this.libraryRepository,
    this.desktopIntegration,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final bool desktopWindow;
  final PlayerVideoBuilder? videoBuilder;
  final bool enableNativeDrop;
  final FullscreenSetter? fullscreenSetter;
  final SubtitleFilePicker? subtitlePicker;
  final GlobalKey<NavigatorState>? navigatorKey;
  final AppPreferencesRepository? appPreferences;
  final MediaLibraryRepository? libraryRepository;
  final DesktopIntegrationService? desktopIntegration;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Mpvson',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: PlayerScreen(
        controller: controller,
        updates: updates,
        engineUpdates: engineUpdates,
        desktopWindow: desktopWindow,
        videoBuilder: videoBuilder ?? _nativeVideo,
        enableNativeDrop: enableNativeDrop,
        fullscreenSetter: fullscreenSetter,
        subtitlePicker: subtitlePicker,
        appPreferences: appPreferences,
        libraryRepository: libraryRepository,
        desktopIntegration: desktopIntegration,
      ),
    );
  }

  static Widget _nativeVideo(
    BuildContext context,
    PlayerController controller,
  ) => Video(
    controller: controller.videoController,
    fit: BoxFit.contain,
    controls: null,
    pauseUponEnteringBackgroundMode: false,
  );
}
