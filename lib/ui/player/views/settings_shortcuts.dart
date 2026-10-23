part of 'settings_dialog.dart';

class _ShortcutsSettings extends StatelessWidget {
  const _ShortcutsSettings({required this.preferences, this.heading});

  final AppPreferencesRepository preferences;
  final Widget? heading;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final overrides = preferences.preferences.shortcutOverrides;
      final validation = validateShortcutOverrides(overrides);
      final bindings = resolvePlayerShortcuts(overrides);
      return SingleChildScrollView(
        key: const PageStorageKey<String>('settings-shortcuts'),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?heading,
            Text(
              'Select a shortcut to change it. Typing in a text field and '
              'using focused sliders or queue controls keeps their normal keys.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (validation != null) ...[
              const SizedBox(height: 10),
              Text(
                'Some saved shortcuts are invalid. Default bindings are active.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            _SettingAnchor(
              id: 'keyboard-shortcuts',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final action in PlayerShortcutAction.values)
                    _ShortcutBindingTile(
                      action: action,
                      binding: bindings[action]!,
                      fixedBindings: fixedPlayerShortcuts[action] ?? const {},
                      overridden: overrides.containsKey(action.name),
                      onChange: () =>
                          _captureShortcut(context, action, overrides),
                      onReset: overrides.containsKey(action.name)
                          ? () {
                              final next = Map<String, String>.of(overrides)
                                ..remove(action.name);
                              _saveOverrides(context, next);
                            }
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SettingAnchor(
              id: 'mouse-controls',
              child: Text(
                'Mouse: scroll to change volume, click to pause or resume, '
                'double-click for fullscreen, and right-click for the player menu.'
                '${bindings[PlayerShortcutAction.playPause] == 'Space' ? ' Hold Space for temporary 2x speed.' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: overrides.isEmpty
                    ? null
                    : () => _saveOverrides(context, const {}),
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Restore defaults'),
              ),
            ),
          ],
        ),
      );
    },
  );

  void _saveOverrides(BuildContext context, Map<String, String> overrides) {
    final reason = validateShortcutOverrides(overrides);
    if (reason != null) {
      unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Shortcut conflict'),
            content: Text(
              '$reason Reset the conflicting shortcuts together in Changed settings, or restore all shortcut defaults.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      );
      return;
    }
    unawaited(preferences.setShortcutOverrides(overrides));
  }

  Future<void> _captureShortcut(
    BuildContext context,
    PlayerShortcutAction action,
    Map<String, String> currentOverrides,
  ) async {
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('Change ${shortcutActionLabel(action).toLowerCase()}'),
            content: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  Navigator.of(dialogContext).pop();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.tab) {
                  return KeyEventResult.ignored;
                }
                final binding = playerShortcutFromEvent(
                  event,
                  control: HardwareKeyboard.instance.isControlPressed,
                  alt: HardwareKeyboard.instance.isAltPressed,
                  shift: HardwareKeyboard.instance.isShiftPressed,
                  meta: HardwareKeyboard.instance.isMetaPressed,
                );
                if (binding == null) {
                  setDialogState(
                    () => error = 'Use a key, not a modifier alone.',
                  );
                  return KeyEventResult.handled;
                }
                final next = Map<String, String>.of(currentOverrides)
                  ..[action.name] = binding;
                final reason = validateShortcutOverrides(next);
                if (reason != null) {
                  setDialogState(() => error = reason);
                  return KeyEventResult.handled;
                }
                Navigator.of(dialogContext).pop(binding);
                return KeyEventResult.handled;
              },
              child: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Press a key or combination. Escape and Tab stay reserved.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
    if (value == null || !context.mounted) return;
    final next = Map<String, String>.of(currentOverrides)
      ..[action.name] = value;
    if (value == defaultShortcutBindings[action]) next.remove(action.name);
    await preferences.setShortcutOverrides(next);
  }
}

class _ShortcutBindingTile extends StatelessWidget {
  const _ShortcutBindingTile({
    required this.action,
    required this.binding,
    required this.fixedBindings,
    required this.overridden,
    required this.onChange,
    required this.onReset,
  });

  final PlayerShortcutAction action;
  final String binding;
  final Set<String> fixedBindings;
  final bool overridden;
  final VoidCallback onChange;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final suffix = fixedBindings.isEmpty
        ? null
        : 'Also ${fixedBindings.join(' or ')}';
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(action.label),
        if (suffix != null)
          Text(
            suffix,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
          ),
      ],
    );
    final controls = Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton(onPressed: onChange, child: Text(binding)),
        if (overridden)
          IconButton(
            tooltip: 'Restore default for ${action.label.toLowerCase()}',
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt_rounded),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          if (constraints.maxWidth < 680 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [description, const SizedBox(height: 6), controls],
            );
          }
          return Row(
            children: [
              Expanded(child: description),
              const SizedBox(width: 12),
              Flexible(child: controls),
            ],
          );
        },
      ),
    );
  }
}
