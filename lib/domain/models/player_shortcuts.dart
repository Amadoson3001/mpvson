import 'package:flutter/services.dart';

enum PlayerShortcutAction {
  playPause,
  seekBackward,
  seekForward,
  volumeUp,
  volumeDown,
  mute,
  fullscreen,
  toggleQueue,
  playbackInfo,
  openFiles,
  openUrl,
  contextMenu,
  removeQueueItem,
}

extension PlayerShortcutActionDetails on PlayerShortcutAction {
  String get label => switch (this) {
    PlayerShortcutAction.playPause => 'Play or pause',
    PlayerShortcutAction.seekBackward => 'Seek backward 5 seconds',
    PlayerShortcutAction.seekForward => 'Seek forward 5 seconds',
    PlayerShortcutAction.volumeUp => 'Increase volume',
    PlayerShortcutAction.volumeDown => 'Decrease volume',
    PlayerShortcutAction.mute => 'Mute or unmute',
    PlayerShortcutAction.fullscreen => 'Toggle fullscreen',
    PlayerShortcutAction.toggleQueue => 'Show or hide the queue',
    PlayerShortcutAction.playbackInfo => 'Show playback information',
    PlayerShortcutAction.openFiles => 'Open files',
    PlayerShortcutAction.openUrl => 'Open a URL',
    PlayerShortcutAction.contextMenu => 'Open the player menu',
    PlayerShortcutAction.removeQueueItem => 'Remove the focused queue item',
  };
}

/// Canonical shortcut strings use Ctrl, Alt, Shift, Meta, Space, ArrowLeft,
/// ArrowRight, ArrowUp, ArrowDown, F1-F12, ContextMenu, Delete, A-Z, 0-9.
/// Modifiers appear in Ctrl, Alt, Shift, Meta order.
const Map<PlayerShortcutAction, String> defaultPlayerShortcuts = {
  PlayerShortcutAction.playPause: 'Space',
  PlayerShortcutAction.seekBackward: 'ArrowLeft',
  PlayerShortcutAction.seekForward: 'ArrowRight',
  PlayerShortcutAction.volumeUp: 'ArrowUp',
  PlayerShortcutAction.volumeDown: 'ArrowDown',
  PlayerShortcutAction.mute: 'M',
  PlayerShortcutAction.fullscreen: 'F',
  PlayerShortcutAction.toggleQueue: 'P',
  PlayerShortcutAction.playbackInfo: 'I',
  PlayerShortcutAction.openFiles: 'Ctrl+O',
  PlayerShortcutAction.openUrl: 'Ctrl+L',
  PlayerShortcutAction.contextMenu: 'Shift+F10',
  PlayerShortcutAction.removeQueueItem: 'Delete',
};

const Map<PlayerShortcutAction, String> defaultShortcutBindings =
    defaultPlayerShortcuts;

String shortcutActionLabel(PlayerShortcutAction action) => action.label;

/// Secondary bindings kept fixed for compatibility and system conventions.
const Map<PlayerShortcutAction, Set<String>> fixedPlayerShortcuts = {
  PlayerShortcutAction.fullscreen: {'F11'},
  PlayerShortcutAction.contextMenu: {'ContextMenu'},
};

const Map<String, LogicalKeyboardKey> _namedKeys = {
  'Space': LogicalKeyboardKey.space,
  'ArrowLeft': LogicalKeyboardKey.arrowLeft,
  'ArrowRight': LogicalKeyboardKey.arrowRight,
  'ArrowUp': LogicalKeyboardKey.arrowUp,
  'ArrowDown': LogicalKeyboardKey.arrowDown,
  'Delete': LogicalKeyboardKey.delete,
  'Backspace': LogicalKeyboardKey.backspace,
  'Enter': LogicalKeyboardKey.enter,
  'Escape': LogicalKeyboardKey.escape,
  'Tab': LogicalKeyboardKey.tab,
  'ContextMenu': LogicalKeyboardKey.contextMenu,
  'F1': LogicalKeyboardKey.f1,
  'F2': LogicalKeyboardKey.f2,
  'F3': LogicalKeyboardKey.f3,
  'F4': LogicalKeyboardKey.f4,
  'F5': LogicalKeyboardKey.f5,
  'F6': LogicalKeyboardKey.f6,
  'F7': LogicalKeyboardKey.f7,
  'F8': LogicalKeyboardKey.f8,
  'F9': LogicalKeyboardKey.f9,
  'F10': LogicalKeyboardKey.f10,
  'F11': LogicalKeyboardKey.f11,
  'F12': LogicalKeyboardKey.f12,
};

const List<String> _modifierOrder = ['Ctrl', 'Alt', 'Shift', 'Meta'];
const Set<String> _reservedKeyNames = {'Escape', 'Tab'};

class PlayerShortcut {
  const PlayerShortcut({required this.keyName, required this.modifiers});

  final String keyName;
  final Set<String> modifiers;

  String get canonical => [
    for (final modifier in _modifierOrder)
      if (modifiers.contains(modifier)) modifier,
    keyName,
  ].join('+');

  LogicalKeyboardKey? get logicalKey =>
      _namedKeys[keyName] ?? _letterOrDigitKey(keyName);
}

/// Parse and normalize a canonical shortcut string. Returns null for unknown
/// keys, duplicate modifiers, and modifier-only values.
PlayerShortcut? parsePlayerShortcut(String raw) {
  final parts = raw.split('+').map((part) => part.trim()).toList();
  if (parts.isEmpty || parts.any((part) => part.isEmpty)) return null;
  final keyName = _canonicalKeyName(parts.last);
  if (keyName == null) return null;
  final modifiers = <String>{};
  for (final part in parts.take(parts.length - 1)) {
    final modifier = switch (part.toLowerCase()) {
      'ctrl' || 'control' => 'Ctrl',
      'alt' || 'option' => 'Alt',
      'shift' => 'Shift',
      'meta' || 'cmd' || 'command' || 'super' => 'Meta',
      _ => null,
    };
    if (modifier == null || !modifiers.add(modifier)) return null;
  }
  final result = PlayerShortcut(keyName: keyName, modifiers: modifiers);
  // Parsing accepts arbitrary modifier ordering and returns a stable form.
  return result;
}

String? normalizePlayerShortcut(String raw) =>
    parsePlayerShortcut(raw)?.canonical;

/// Return a human-readable conflict or reserved-key reason, or null when the
/// complete override map is valid. Maps are validated atomically so shortcut
/// swaps work without exposing a partial binding set.
String? validateShortcutOverrides(Map<String, String> overrides) {
  final actionByName = {
    for (final action in PlayerShortcutAction.values) action.name: action,
  };
  for (final name in overrides.keys) {
    if (!actionByName.containsKey(name)) {
      return 'Unknown shortcut action: $name';
    }
  }

  final effective = Map<PlayerShortcutAction, String>.of(
    defaultPlayerShortcuts,
  );
  for (final name in overrides.keys) {
    effective.remove(actionByName[name]!);
  }
  final assigned = <PlayerShortcutAction, String>{};
  for (final entry in overrides.entries) {
    final action = actionByName[entry.key]!;
    final parsed = parsePlayerShortcut(entry.value);
    if (parsed == null) return 'Choose a single key or key combination.';
    if (parsed.keyName == 'Space' && action != PlayerShortcutAction.playPause) {
      return 'Space is reserved for play, pause, and hold-to-play at 2×.';
    }
    if (_reservedKeyNames.contains(parsed.keyName)) {
      return '${parsed.keyName} is reserved for navigation or dismissal.';
    }
    if (parsed.canonical == 'Ctrl+F') {
      return 'Ctrl+F is reserved for settings search.';
    }
    if (action == PlayerShortcutAction.removeQueueItem &&
        parsed.modifiers.isEmpty &&
        _isPrintable(parsed.keyName)) {
      return 'Removing queue items requires a non-printing key or a modifier.';
    }
    assigned[action] = parsed.canonical;
  }
  effective.addAll(assigned);

  final ownerByKey = <String, PlayerShortcutAction>{};
  for (final action in PlayerShortcutAction.values) {
    final binding = effective[action];
    if (binding == null) continue;
    final previous = ownerByKey[binding];
    if (previous != null && previous != action) {
      return '${_labelFor(previous)} and ${_labelFor(action)} use $binding.';
    }
    ownerByKey[binding] = action;
  }
  for (final entry in fixedPlayerShortcuts.entries) {
    for (final binding in entry.value) {
      final previous = ownerByKey[binding];
      if (previous != null && previous != entry.key) {
        return '$binding is reserved for ${_labelFor(entry.key)}.';
      }
    }
  }
  return null;
}

Map<PlayerShortcutAction, String> resolvePlayerShortcuts(
  Map<String, String> overrides,
) {
  if (validateShortcutOverrides(overrides) != null) {
    return Map.unmodifiable(defaultPlayerShortcuts);
  }
  final resolved = Map<PlayerShortcutAction, String>.of(defaultPlayerShortcuts);
  for (final action in PlayerShortcutAction.values) {
    final override = overrides[action.name];
    if (override != null) {
      resolved[action] = parsePlayerShortcut(override)!.canonical;
    }
  }
  return Map.unmodifiable(resolved);
}

/// Build a canonical binding from a hardware event and its current modifiers.
String? playerShortcutFromEvent(
  KeyEvent event, {
  required bool control,
  required bool alt,
  required bool shift,
  required bool meta,
}) {
  final keyName = _keyNameFor(event.logicalKey);
  if (keyName == null) return null;
  return PlayerShortcut(
    keyName: keyName,
    modifiers: {
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Meta',
    },
  ).canonical;
}

PlayerShortcutAction? playerShortcutActionFor(
  String canonical,
  Map<PlayerShortcutAction, String> bindings,
) {
  for (final entry in bindings.entries) {
    if (entry.value == canonical) return entry.key;
    if (fixedPlayerShortcuts[entry.key]?.contains(canonical) ?? false) {
      return entry.key;
    }
  }
  return null;
}

String? _canonicalKeyName(String raw) {
  if (_namedKeys.containsKey(raw)) return raw;
  if (raw.length == 1) {
    final upper = raw.toUpperCase();
    if (_letterOrDigitKey(upper) != null) return upper;
  }
  final normalized = raw.toUpperCase();
  if (RegExp(r'^F(?:[1-9]|1[0-2])$').hasMatch(normalized)) return normalized;
  return null;
}

LogicalKeyboardKey? _letterOrDigitKey(String name) {
  if (name.length != 1) return null;
  return switch (name.toUpperCase()) {
    'A' => LogicalKeyboardKey.keyA,
    'B' => LogicalKeyboardKey.keyB,
    'C' => LogicalKeyboardKey.keyC,
    'D' => LogicalKeyboardKey.keyD,
    'E' => LogicalKeyboardKey.keyE,
    'F' => LogicalKeyboardKey.keyF,
    'G' => LogicalKeyboardKey.keyG,
    'H' => LogicalKeyboardKey.keyH,
    'I' => LogicalKeyboardKey.keyI,
    'J' => LogicalKeyboardKey.keyJ,
    'K' => LogicalKeyboardKey.keyK,
    'L' => LogicalKeyboardKey.keyL,
    'M' => LogicalKeyboardKey.keyM,
    'N' => LogicalKeyboardKey.keyN,
    'O' => LogicalKeyboardKey.keyO,
    'P' => LogicalKeyboardKey.keyP,
    'Q' => LogicalKeyboardKey.keyQ,
    'R' => LogicalKeyboardKey.keyR,
    'S' => LogicalKeyboardKey.keyS,
    'T' => LogicalKeyboardKey.keyT,
    'U' => LogicalKeyboardKey.keyU,
    'V' => LogicalKeyboardKey.keyV,
    'W' => LogicalKeyboardKey.keyW,
    'X' => LogicalKeyboardKey.keyX,
    'Y' => LogicalKeyboardKey.keyY,
    'Z' => LogicalKeyboardKey.keyZ,
    '0' => LogicalKeyboardKey.digit0,
    '1' => LogicalKeyboardKey.digit1,
    '2' => LogicalKeyboardKey.digit2,
    '3' => LogicalKeyboardKey.digit3,
    '4' => LogicalKeyboardKey.digit4,
    '5' => LogicalKeyboardKey.digit5,
    '6' => LogicalKeyboardKey.digit6,
    '7' => LogicalKeyboardKey.digit7,
    '8' => LogicalKeyboardKey.digit8,
    '9' => LogicalKeyboardKey.digit9,
    _ => null,
  };
}

String? _keyNameFor(LogicalKeyboardKey key) {
  for (final entry in _namedKeys.entries) {
    if (entry.value == key) return entry.key;
  }
  final label = key.keyLabel.toUpperCase();
  if (label.length == 1 && _letterOrDigitKey(label) != null) return label;
  return null;
}

String _labelFor(PlayerShortcutAction action) => action.label.toLowerCase();

bool _isPrintable(String keyName) => keyName.length == 1 || keyName == 'Space';
