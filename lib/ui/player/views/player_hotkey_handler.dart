import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/player_hotkeys.dart';
import '../player_controller.dart';

class PlayerHotkeyHandler {
  PlayerHotkeyHandler({
    required this.controller,
    required this.getHotkeys,
    required this.isQueueOpen,
    required this.isContextMenuOpen,
    required this.isFullscreen,
    required this.isDesktopWindow,
    required this.isNativeWindow,
    required this.hasLibraryRepository,
    required this.getSeekStepSeconds,
    required this.getFocusedQueueEntryId,
    required this.isControlsFocusActive,
    required this.isQueueFocusActive,
    required this.isInsidePlayer,
    required this.onCloseContextMenu,
    required this.onCloseQueue,
    required this.onToggleQueue,
    required this.onOpenContextMenu,
    required this.onToggleFullscreen,
    required this.onSetFullscreen,
    required this.onToggleMiniPlayer,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onOpenLibrary,
    required this.onRemoveQueueEntry,
    required this.onAdjustVolume,
    required this.onToggleMute,
    required this.onAdjustDelay,
    required this.onShowPlaybackInfo,
    required this.onShowControls,
  });

  final PlayerController controller;
  final PlayerHotkeys Function() getHotkeys;
  final bool Function() isQueueOpen;
  final bool Function() isContextMenuOpen;
  final bool Function() isFullscreen;
  final bool isDesktopWindow;
  final bool isNativeWindow;
  final bool hasLibraryRepository;
  final int Function() getSeekStepSeconds;
  final String? Function() getFocusedQueueEntryId;
  final bool Function() isControlsFocusActive;
  final bool Function() isQueueFocusActive;
  final bool Function(BuildContext context) isInsidePlayer;
  final VoidCallback onCloseContextMenu;
  final VoidCallback onCloseQueue;
  final VoidCallback onToggleQueue;
  final VoidCallback onOpenContextMenu;
  final VoidCallback onToggleFullscreen;
  final Future<void> Function(bool value) onSetFullscreen;
  final VoidCallback onToggleMiniPlayer;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final VoidCallback onOpenLibrary;
  final Future<void> Function(String entryId) onRemoveQueueEntry;
  final ValueChanged<double> onAdjustVolume;
  final VoidCallback onToggleMute;
  final Future<void> Function({required bool audio, required bool later})
  onAdjustDelay;
  final VoidCallback onShowPlaybackInfo;
  final VoidCallback onShowControls;

  static const _spaceHoldDelay = Duration(milliseconds: 180);

  Timer? _spaceTimer;
  bool _spaceHeld = false;
  bool _longSpacePress = false;
  double _rateBeforeHold = 1;
  bool _isDisposed = false;

  bool get isSpaceHeld => _spaceHeld;

  void cancelHeldSpeed() {
    _spaceTimer?.cancel();
    _spaceHeld = false;
    if (_longSpacePress) {
      _longSpacePress = false;
      unawaited(controller.setRate(_rateBeforeHold));
    }
  }

  void handlePrimaryFocusChange() {
    if (!_spaceHeld) return;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (_textInputFocused ||
        focusedContext == null ||
        !isInsidePlayer(focusedContext)) {
      cancelHeldSpeed();
    }
  }

  bool get _textInputFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _sliderFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is Slider ||
        context.findAncestorWidgetOfExactType<Slider>() != null;
  }

  PlayerAction? _actionFor(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed) return null;
    return getHotkeys().actionFor(
      event.logicalKey,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
  }

  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final action = _actionFor(event);
    // A held playback shortcut must unwind even if the focus changed before
    // the release. Fresh typing inside a text field remains untouched.
    if (action == PlayerAction.playPause && event is KeyUpEvent && _spaceHeld) {
      final togglePlayback = !_longSpacePress && !_textInputFocused;
      cancelHeldSpeed();
      if (togglePlayback) unawaited(controller.togglePlayPause());
      return _textInputFocused
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape && isContextMenuOpen()) {
      if (event is KeyDownEvent) onCloseContextMenu();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape && isQueueOpen()) {
      if (event is KeyDownEvent) {
        onCloseQueue();
      }
      return KeyEventResult.handled;
    }

    if (_textInputFocused) return KeyEventResult.ignored;
    if (action == PlayerAction.playPause && isControlsFocusActive()) {
      return KeyEventResult.ignored;
    }

    if (action == PlayerAction.playPause) {
      if (event is KeyDownEvent && !_spaceHeld) {
        _spaceHeld = true;
        _longSpacePress = false;
        _spaceTimer?.cancel();
        _spaceTimer = Timer(_spaceHoldDelay, () {
          if (_isDisposed || !_spaceHeld) return;
          _longSpacePress = true;
          _rateBeforeHold = controller.rate;
          if (!controller.isPlaying) {
            unawaited(controller.togglePlayPause());
          }
          unawaited(controller.setRate(2));
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent && _spaceHeld) return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final queueOwnsFocus = isQueueFocusActive();
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyO) {
      onOpenFiles();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyL) {
      onOpenUrl();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyM &&
        hasLibraryRepository) {
      onOpenLibrary();
      return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.contextMenu:
        onOpenContextMenu();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.f10:
        if (HardwareKeyboard.instance.isShiftPressed) {
          onOpenContextMenu();
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.delete:
        if (getFocusedQueueEntryId() case final entryId?
            when isQueueFocusActive()) {
          unawaited(onRemoveQueueEntry(entryId));
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.f11:
        if (isDesktopWindow) {
          onToggleFullscreen();
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.escape:
        if (isFullscreen()) {
          unawaited(onSetFullscreen(false));
          return KeyEventResult.handled;
        }
        break;
      default:
        break;
    }

    if (action == null) return KeyEventResult.ignored;
    switch (action) {
      case PlayerAction.playPause:
        // Held-state handling above owns the play/pause shortcut.
        return KeyEventResult.ignored;
      case PlayerAction.seekBackward:
      case PlayerAction.seekForward:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        final stepSeconds = getSeekStepSeconds();
        final step = action == PlayerAction.seekForward
            ? stepSeconds
            : -stepSeconds;
        unawaited(controller.seekRelative(Duration(seconds: step)));
        onShowControls();
        return KeyEventResult.handled;
      case PlayerAction.volumeUp:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        onAdjustVolume(5);
        onShowControls();
        return KeyEventResult.handled;
      case PlayerAction.volumeDown:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        onAdjustVolume(-5);
        onShowControls();
        return KeyEventResult.handled;
      case PlayerAction.mute:
        onToggleMute();
        return KeyEventResult.handled;
      case PlayerAction.queue:
        onToggleQueue();
        return KeyEventResult.handled;
      case PlayerAction.playbackInfo:
        onShowPlaybackInfo();
        return KeyEventResult.handled;
      case PlayerAction.fullscreen:
        if (!isDesktopWindow) return KeyEventResult.ignored;
        onToggleFullscreen();
        return KeyEventResult.handled;
      case PlayerAction.miniPlayer:
        if (!isNativeWindow) return KeyEventResult.ignored;
        onToggleMiniPlayer();
        return KeyEventResult.handled;
      case PlayerAction.subtitleEarlier:
        unawaited(onAdjustDelay(audio: false, later: false));
        return KeyEventResult.handled;
      case PlayerAction.subtitleLater:
        unawaited(onAdjustDelay(audio: false, later: true));
        return KeyEventResult.handled;
      case PlayerAction.audioEarlier:
        unawaited(onAdjustDelay(audio: true, later: false));
        return KeyEventResult.handled;
      case PlayerAction.audioLater:
        unawaited(onAdjustDelay(audio: true, later: true));
        return KeyEventResult.handled;
    }
  }

  void dispose() {
    _isDisposed = true;
    _spaceTimer?.cancel();
  }
}
