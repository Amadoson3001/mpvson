import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_theme.dart';
import '../../../core/components/app_dialog.dart';
import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../domain/models/player_hotkeys.dart';
import 'settings_shared_widgets.dart';

class ShortcutsSettingsSection extends StatelessWidget {
  const ShortcutsSettingsSection({super.key, required this.preferences});

  final AppPreferencesRepository preferences;

  Future<void> _rebind(
    BuildContext context,
    PlayerHotkeys hotkeys,
    PlayerAction action,
  ) async {
    final binding = await showDialog<HotkeyBinding>(
      context: context,
      builder: (_) => HotkeyCaptureDialog(
        action: action,
        initial: hotkeys.bindingFor(action),
        hotkeys: hotkeys,
      ),
    );
    if (binding != null) await preferences.setHotkey(action, binding);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final current = preferences.preferences;
      final hotkeys = current.hotkeys;

      return SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsCardGroup(
              title: 'Seek & sync steps',
              children: [
                DropdownSettingTile<int>(
                  icon: Icons.timer_outlined,
                  label: 'Arrow seek step',
                  value: current.seekStepSeconds,
                  items: DesktopPreferences.seekStepOptions
                      .map(
                        (sec) => DropdownMenuItem(
                          value: sec,
                          child: Text('$sec seconds'),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) unawaited(preferences.setSeekStep(val));
                  },
                ),
                DropdownSettingTile<int>(
                  icon: Icons.sync_rounded,
                  label: 'Delay sync step',
                  value: current.syncStepMs,
                  items: DesktopPreferences.syncStepOptions
                      .map(
                        (ms) =>
                            DropdownMenuItem(value: ms, child: Text('$ms ms')),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) unawaited(preferences.setSyncStep(val));
                  },
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'Keyboard hotkeys',
              description:
                  'Click any shortcut binding to capture a new key combination.',
              trailing: TextButton.icon(
                key: const ValueKey('reset-hotkeys'),
                onPressed: () => unawaited(preferences.resetHotkeys()),
                icon: const Icon(Icons.restore_rounded, size: 15),
                label: const Text('Reset hotkeys'),
              ),
              children: [
                for (final action in PlayerAction.values)
                  HotkeyRowTile(
                    key: ValueKey<String>('hotkey-${action.name}'),
                    action: action,
                    binding: hotkeys.bindingFor(action),
                    onPressed: () =>
                        unawaited(_rebind(context, hotkeys, action)),
                  ),
              ],
            ),
            SettingsCardGroup(
              title: 'Mouse & system shortcuts',
              children: const [
                ShortcutRow(
                  keys: 'Mouse wheel',
                  action: 'Adjust volume up or down',
                ),
                ShortcutRow(
                  keys: 'Left click video',
                  action: 'Toggle play / pause',
                ),
                ShortcutRow(
                  keys: 'Double click video',
                  action: 'Toggle full screen',
                ),
                ShortcutRow(
                  keys: 'Right click video',
                  action: 'Open player context menu',
                ),
                ShortcutRow(keys: 'Ctrl + O', action: 'Open files dialog'),
                ShortcutRow(
                  keys: 'Ctrl + L',
                  action: 'Open network stream URL',
                ),
                ShortcutRow(keys: 'Ctrl + M', action: 'Open media library'),
                ShortcutRow(keys: 'F11', action: 'Toggle full screen'),
                ShortcutRow(
                  keys: 'Escape',
                  action: 'Dismiss menu / exit full screen',
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class HotkeyRowTile extends StatelessWidget {
  const HotkeyRowTile({
    super.key,
    required this.action,
    required this.binding,
    required this.onPressed,
  });

  final PlayerAction action;
  final HotkeyBinding binding;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              action.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(80, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            child: Text(
              binding.label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ShortcutRow extends StatelessWidget {
  const ShortcutRow({super.key, required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              keys,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              action,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HotkeyCaptureDialog extends StatefulWidget {
  const HotkeyCaptureDialog({
    super.key,
    required this.action,
    required this.initial,
    required this.hotkeys,
  });

  final PlayerAction action;
  final HotkeyBinding initial;
  final PlayerHotkeys hotkeys;

  @override
  State<HotkeyCaptureDialog> createState() => _HotkeyCaptureDialogState();
}

class _HotkeyCaptureDialogState extends State<HotkeyCaptureDialog> {
  static final Set<LogicalKeyboardKey> _nonBindingKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
  };

  final FocusNode _focusNode = FocusNode(debugLabel: 'Hotkey capture');
  HotkeyBinding? _captured;
  PlayerAction? _conflict;

  @override
  void initState() {
    super.initState();
    _captured = widget.initial;
    _conflict = widget.hotkeys.actionBoundTo(
      widget.initial,
      excluding: widget.action,
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_nonBindingKeys.contains(key)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final binding = HotkeyBinding.key(
      key,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
    setState(() {
      _captured = binding;
      _conflict = widget.hotkeys.actionBoundTo(
        binding,
        excluding: widget.action,
      );
    });
    return KeyEventResult.handled;
  }

  void _restoreDefault() {
    final binding = PlayerHotkeys.defaults.bindingFor(widget.action);
    setState(() {
      _captured = binding;
      _conflict = widget.hotkeys.actionBoundTo(
        binding,
        excluding: widget.action,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final captured = _captured;
    final conflict = _conflict;
    final theme = Theme.of(context);

    return AppDialog(
      maxWidth: 440,
      title: Text('Shortcut for ${widget.action.label}'),
      content: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Press your desired key combination. Escape cancels.'),
            const SizedBox(height: AppSpace.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                vertical: AppSpace.inputV,
                horizontal: AppSpace.inputH,
              ),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadii.control),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                captured?.label ?? 'Press keys…',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            if (conflict != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Text(
                  'Currently assigned to “${conflict.label}”. Choose another shortcut.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _restoreDefault, child: const Text('Default')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: captured == null || conflict != null
              ? null
              : () => Navigator.of(context).pop(captured),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
