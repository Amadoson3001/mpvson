import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Player commands that can be rebound from Settings > Shortcuts.
enum PlayerAction {
  playPause,
  seekBackward,
  seekForward,
  previousTrack,
  nextTrack,
  volumeUp,
  volumeDown,
  mute,
  fullscreen,
  queue,
  playbackInfo,
  miniPlayer,
  cycleSubtitle,
  cycleAudio,
  subtitleEarlier,
  subtitleLater,
  audioEarlier,
  audioLater,
  speedDown,
  speedUp,
  speedReset,
  frameStepBackward,
  frameStepForward,
  screenshot,
}

extension PlayerActionDetails on PlayerAction {
  String get label => switch (this) {
    PlayerAction.playPause => 'Play or pause',
    PlayerAction.seekBackward => 'Seek backward',
    PlayerAction.seekForward => 'Seek forward',
    PlayerAction.previousTrack => 'Previous in queue',
    PlayerAction.nextTrack => 'Next in queue',
    PlayerAction.volumeUp => 'Volume up',
    PlayerAction.volumeDown => 'Volume down',
    PlayerAction.mute => 'Mute or unmute',
    PlayerAction.fullscreen => 'Toggle fullscreen',
    PlayerAction.queue => 'Show or hide the queue',
    PlayerAction.playbackInfo => 'Playback information',
    PlayerAction.miniPlayer => 'Mini player',
    PlayerAction.cycleSubtitle => 'Cycle subtitles',
    PlayerAction.cycleAudio => 'Cycle audio track',
    PlayerAction.subtitleEarlier => 'Subtitles earlier',
    PlayerAction.subtitleLater => 'Subtitles later',
    PlayerAction.audioEarlier => 'Audio earlier',
    PlayerAction.audioLater => 'Audio later',
    PlayerAction.speedDown => 'Decrease speed',
    PlayerAction.speedUp => 'Increase speed',
    PlayerAction.speedReset => 'Reset speed',
    PlayerAction.frameStepBackward => 'Previous frame',
    PlayerAction.frameStepForward => 'Next frame',
    PlayerAction.screenshot => 'Save screenshot',
  };
}

/// One key combination bound to a [PlayerAction].
@immutable
class HotkeyBinding {
  const HotkeyBinding({
    required this.keyId,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  HotkeyBinding.key(
    LogicalKeyboardKey key, {
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  }) : keyId = key.keyId;

  final int keyId;
  final bool ctrl;
  final bool alt;
  final bool shift;

  bool matches(
    LogicalKeyboardKey key, {
    required bool ctrl,
    required bool alt,
    required bool shift,
  }) =>
      key.keyId == keyId &&
      this.ctrl == ctrl &&
      this.alt == alt &&
      this.shift == shift;

  String get label {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    var name = switch (key) {
      LogicalKeyboardKey.space => 'Space',
      LogicalKeyboardKey.arrowLeft => '←',
      LogicalKeyboardKey.arrowRight => '→',
      LogicalKeyboardKey.arrowUp => '↑',
      LogicalKeyboardKey.arrowDown => '↓',
      LogicalKeyboardKey.pageUp => 'PgUp',
      LogicalKeyboardKey.pageDown => 'PgDn',
      LogicalKeyboardKey.backspace => 'Backspace',
      LogicalKeyboardKey.minus => '-',
      LogicalKeyboardKey.equal => '=',
      LogicalKeyboardKey.comma => ',',
      LogicalKeyboardKey.period => '.',
      LogicalKeyboardKey.tab => 'Tab',
      LogicalKeyboardKey.enter => 'Enter',
      _ => key?.keyLabel ?? '',
    };
    if (name.length == 1) name = name.toUpperCase();
    if (name.trim().isEmpty) name = key?.debugName ?? 'Key $keyId';
    return [
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      name,
    ].join(' + ');
  }

  static HotkeyBinding? tryParse(Object? value) {
    if (value is! Map) return null;
    final key = value['key'];
    if (key is! int || key <= 0) return null;
    return HotkeyBinding(
      keyId: key,
      ctrl: value['ctrl'] == true,
      alt: value['alt'] == true,
      shift: value['shift'] == true,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': keyId,
    'ctrl': ctrl,
    'alt': alt,
    'shift': shift,
  };

  @override
  bool operator ==(Object other) =>
      other is HotkeyBinding &&
      other.keyId == keyId &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(keyId, ctrl, alt, shift);

  @override
  String toString() => 'HotkeyBinding($label)';
}

/// Key combinations for every remappable player action.
///
/// Bindings are keyed by logical key id so the same shortcut label keeps
/// working across sessions. Unknown or invalid entries fall back to defaults.
@immutable
class PlayerHotkeys {
  PlayerHotkeys._(Map<PlayerAction, HotkeyBinding> bindings)
    : _bindings = Map<PlayerAction, HotkeyBinding>.unmodifiable(bindings);

  /// Merges [bindings] over the defaults.
  factory PlayerHotkeys([
    Map<PlayerAction, HotkeyBinding> bindings = const {},
  ]) => PlayerHotkeys._(<PlayerAction, HotkeyBinding>{
    ...defaults._bindings,
    ...bindings,
  });

  static final PlayerHotkeys defaults = PlayerHotkeys._(_defaultBindings());

  static Map<PlayerAction, HotkeyBinding>
  _defaultBindings() => <PlayerAction, HotkeyBinding>{
    PlayerAction.playPause: HotkeyBinding.key(LogicalKeyboardKey.space),
    PlayerAction.seekBackward: HotkeyBinding.key(LogicalKeyboardKey.arrowLeft),
    PlayerAction.seekForward: HotkeyBinding.key(LogicalKeyboardKey.arrowRight),
    PlayerAction.previousTrack: HotkeyBinding.key(LogicalKeyboardKey.pageUp),
    PlayerAction.nextTrack: HotkeyBinding.key(LogicalKeyboardKey.pageDown),
    PlayerAction.volumeUp: HotkeyBinding.key(LogicalKeyboardKey.arrowUp),
    PlayerAction.volumeDown: HotkeyBinding.key(LogicalKeyboardKey.arrowDown),
    PlayerAction.mute: HotkeyBinding.key(LogicalKeyboardKey.keyM),
    PlayerAction.fullscreen: HotkeyBinding.key(LogicalKeyboardKey.keyF),
    PlayerAction.queue: HotkeyBinding.key(LogicalKeyboardKey.keyP),
    PlayerAction.playbackInfo: HotkeyBinding.key(LogicalKeyboardKey.keyI),
    PlayerAction.miniPlayer: HotkeyBinding.key(
      LogicalKeyboardKey.keyI,
      shift: true,
    ),
    PlayerAction.cycleSubtitle: HotkeyBinding.key(LogicalKeyboardKey.keyV),
    PlayerAction.cycleAudio: HotkeyBinding.key(LogicalKeyboardKey.keyB),
    PlayerAction.subtitleEarlier: HotkeyBinding.key(LogicalKeyboardKey.keyZ),
    PlayerAction.subtitleLater: HotkeyBinding.key(
      LogicalKeyboardKey.keyZ,
      shift: true,
    ),
    PlayerAction.audioEarlier: HotkeyBinding.key(
      LogicalKeyboardKey.bracketLeft,
    ),
    PlayerAction.audioLater: HotkeyBinding.key(LogicalKeyboardKey.bracketRight),
    PlayerAction.speedDown: HotkeyBinding.key(LogicalKeyboardKey.minus),
    PlayerAction.speedUp: HotkeyBinding.key(LogicalKeyboardKey.equal),
    PlayerAction.speedReset: HotkeyBinding.key(LogicalKeyboardKey.backspace),
    PlayerAction.frameStepBackward: HotkeyBinding.key(LogicalKeyboardKey.comma),
    PlayerAction.frameStepForward: HotkeyBinding.key(LogicalKeyboardKey.period),
    PlayerAction.screenshot: HotkeyBinding.key(LogicalKeyboardKey.keyS),
  };

  final Map<PlayerAction, HotkeyBinding> _bindings;

  HotkeyBinding bindingFor(PlayerAction action) =>
      _bindings[action] ?? defaults._bindings[action]!;

  /// Returns a copy where [binding] is assigned to [action].
  ///
  /// Callers are expected to reject combinations already reported by
  /// [actionBoundTo] so every action keeps a distinct key.
  PlayerHotkeys withBinding(PlayerAction action, HotkeyBinding binding) {
    final next = Map<PlayerAction, HotkeyBinding>.from(_bindings);
    next[action] = binding;
    return PlayerHotkeys(next);
  }

  /// The action currently using [binding], excluding [excluding].
  PlayerAction? actionBoundTo(
    HotkeyBinding binding, {
    PlayerAction? excluding,
  }) {
    for (final action in PlayerAction.values) {
      if (action == excluding) continue;
      if (bindingFor(action) == binding) return action;
    }
    return null;
  }

  factory PlayerHotkeys.fromJson(Object? value) {
    final overrides = <PlayerAction, HotkeyBinding>{};
    if (value is Map) {
      for (final action in PlayerAction.values) {
        final binding = HotkeyBinding.tryParse(value[action.name]);
        if (binding != null) overrides[action] = binding;
      }
      // Avoid duplicate bindings when upgrading saved preferences from older
      // versions where a newly introduced action's default key was already bound.
      final used = Set<HotkeyBinding>.from(overrides.values);
      for (final action in PlayerAction.values) {
        if (overrides.containsKey(action)) continue;
        final fallback = defaults._bindings[action]!;
        if (!used.add(fallback)) {
          final shifted = HotkeyBinding(
            keyId: fallback.keyId,
            ctrl: fallback.ctrl,
            alt: fallback.alt,
            shift: !fallback.shift,
          );
          if (used.add(shifted)) {
            overrides[action] = shifted;
          } else {
            final ctrlShifted = HotkeyBinding(
              keyId: fallback.keyId,
              ctrl: true,
              alt: fallback.alt,
              shift: true,
            );
            used.add(ctrlShifted);
            overrides[action] = ctrlShifted;
          }
        }
      }
    }
    return PlayerHotkeys(overrides);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    for (final entry in _bindings.entries) entry.key.name: entry.value.toJson(),
  };

  /// Resolves the action bound to [key], preferring an exact modifier match.
  ///
  /// When only an extra Shift is held, unshifted bindings still match so
  /// Shift+Arrow keeps seeking and Shift+Space keeps toggling playback.
  PlayerAction? actionFor(
    LogicalKeyboardKey key, {
    required bool ctrl,
    required bool alt,
    required bool shift,
  }) {
    PlayerAction? shiftedFallback;
    for (final action in PlayerAction.values) {
      final binding = bindingFor(action);
      if (binding.keyId != key.keyId) continue;
      if (binding.matches(key, ctrl: ctrl, alt: alt, shift: shift)) {
        return action;
      }
      if (shift &&
          !binding.shift &&
          binding.ctrl == ctrl &&
          binding.alt == alt) {
        shiftedFallback ??= action;
      }
    }
    return shiftedFallback;
  }
}
