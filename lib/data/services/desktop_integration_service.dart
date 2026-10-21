import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../domain/models/media_metadata.dart';

enum SystemPlaybackStatus {
  closed,
  stopped,
  playing,
  paused,
}

abstract class DesktopIntegrationService extends ChangeNotifier {
  SystemPlaybackStatus get playbackStatus;
  MediaMetadata get currentMetadata;
  bool get isAwakeInhibited;

  Future<void> initialize();
  Future<void> updatePlaybackState({
    required SystemPlaybackStatus status,
    required Duration position,
    required Duration duration,
    required double playbackRate,
  });
  Future<void> updateMetadata(MediaMetadata metadata);
  Future<void> updateCapabilities({
    bool canPlay = true,
    bool canPause = true,
    bool canSeek = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
  });
  Future<void> setKeepAwake(bool enable, {required bool isVideoPlaying});
  Future<void> openDefaultAppsSettings();
  @override
  void dispose();
}
