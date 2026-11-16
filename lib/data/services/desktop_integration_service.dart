import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../domain/models/media_metadata.dart';
import 'windows_associations_core.dart';

export 'windows_associations_core.dart' show WindowsRegistrationStatus;

enum SystemPlaybackStatus { closed, stopped, playing, paused }

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

  /// Null when the AC/battery state is unavailable.
  Future<bool?> isOnAcPower();
  Future<void> openDefaultAppsSettings();

  /// Returns the current Windows HKCU file-association status, or null on non-Windows.
  Future<WindowsRegistrationStatus?> getWindowsAssociationStatus() async =>
      null;

  /// Registers Mpvson's HKCU ProgID, Capabilities, and file associations on Windows.
  Future<bool> registerWindowsAssociations({bool force = true}) async => false;

  @override
  void dispose();
}
