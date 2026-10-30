import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'data/repositories/app_preferences_repository.dart';
import 'data/repositories/media_library_repository.dart';
import 'data/services/desktop_integration_service.dart';
import 'data/services/engine_update_service.dart';
import 'data/services/open_request_coordinator.dart';
import 'data/services/update_service.dart';
import 'ui/core/app_theme.dart';
import 'ui/core/components/media_accent_scope.dart';
import 'ui/core/toast/app_toast_host.dart';
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
    this.openCoordinator,
  });

  final OpenRequestCoordinator? openCoordinator;
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
    return ListenableBuilder(
      listenable: appPreferences ?? ValueNotifier<void>(null),
      builder: (context, _) {
        final prefs = appPreferences?.preferences;
        final themeMode = prefs?.themeMode ?? ThemeMode.dark;
        final accentPreset = AppAccentPreset.fromId(prefs?.accentPreset);
        final oledBlack = prefs?.oledBlack ?? false;

        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Mpvson',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: AppTheme.lightTheme(accent: accentPreset.lightColor),
          darkTheme: AppTheme.darkTheme(
            accent: accentPreset.color,
            oledBlack: oledBlack,
          ),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            final calmMode = prefs?.reduceMotion ?? false;
            final effectiveData = calmMode
                ? mq.copyWith(disableAnimations: true)
                : mq;
            return MediaQuery(
              data: effectiveData,
              child: AppToastHost(
                child: AppPreferencesScope(
                  preferences: prefs ?? const DesktopPreferences(),
                  child: MediaAccentScope(
                    controller: controller,
                    child: child!,
                  ),
                ),
              ),
            );
          },
          home: PlayerScreen(
            controller: controller,
            openCoordinator: openCoordinator,
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
      },
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

/// Provides desktop preferences to any widget in the tree.
class AppPreferencesScope extends InheritedWidget {
  const AppPreferencesScope({
    super.key,
    required this.preferences,
    required super.child,
  });

  final DesktopPreferences preferences;

  static DesktopPreferences? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
      ?.preferences;

  @override
  bool updateShouldNotify(AppPreferencesScope oldWidget) =>
      preferences != oldWidget.preferences;
}
