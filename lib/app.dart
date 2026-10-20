import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
