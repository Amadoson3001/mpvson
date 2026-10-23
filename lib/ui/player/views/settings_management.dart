part of 'settings_dialog.dart';

class _ChangedSettings extends StatefulWidget {
  const _ChangedSettings({
    required this.controller,
    required this.preferences,
    this.heading,
  });
  final PlayerController controller;
  final AppPreferencesRepository preferences;
  final Widget? heading;
  @override
  State<_ChangedSettings> createState() => _ChangedSettingsState();
}

class _ChangedSettingsState extends State<_ChangedSettings> {
  final Set<String> _selected = {};
  Set<String> _lastReset = {};
  bool _busy = false;
  String? _error;
  String? _message;

  Future<void> _confirmReset(List<SettingsPreference> values) async {
    final chosen = values
        .where((value) => _selected.contains(value.id))
        .toList();
    if (chosen.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Reset ${chosen.length} ${chosen.length == 1 ? 'setting' : 'settings'}?',
        ),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Only the selected settings will return to their defaults.',
              ),
              const SizedBox(height: 12),
              for (final value in chosen)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${value.title}: ${value.currentLabel} (default: ${value.defaultLabel})',
                  ),
                ),
              if (chosen.any((value) => value.id == 'saveNetworkUrls'))
                const Text(
                  'Turning off saved network URLs removes stored URLs from this computer.',
                ),
              if (chosen.any((value) => value.id == 'historyEnabled'))
                const Text(
                  'The default history setting records new playback activity.',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset selected'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _reset(chosen.map((value) => value.id).toSet());
    }
  }

  Future<void> _reset(Set<String> ids) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _lastReset = Set.of(ids);
    });
    try {
      await resetSettingsPreferences(
        ids,
        widget.controller,
        widget.preferences,
      );
      final engineError = widget.controller.playbackSettingsError;
      if (engineError != null && ids.any((id) => id.startsWith('playback.'))) {
        throw StateError(engineError);
      }
      if (mounted) {
        setState(() {
          _selected.removeAll(ids);
          _message = 'Selected settings reset.';
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Some settings could not be applied or saved. Retry the reset.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.preferences]),
    builder: (context, _) {
      final changed = settingsPreferences(
        widget.controller,
        widget.preferences.preferences,
      ).where((value) => value.isModified).toList();
      final selected = changed
          .where((value) => _selected.contains(value.id))
          .length;
      return SingleChildScrollView(
        key: const PageStorageKey<String>('settings-changed'),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?widget.heading,
            _SettingAnchor(
              id: 'changed-settings',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    changed.isEmpty
                        ? 'All settings use their defaults.'
                        : '${changed.length} ${changed.length == 1 ? 'setting differs' : 'settings differ'} from defaults.',
                  ),
                  if (changed.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _selected.addAll(
                                    changed.map((value) => value.id),
                                  ),
                                ),
                          child: const Text('Select all'),
                        ),
                        TextButton(
                          onPressed: _busy || selected == 0
                              ? null
                              : () => setState(_selected.clear),
                          child: const Text('Clear selection'),
                        ),
                        FilledButton(
                          key: const ValueKey('reset-selected-settings'),
                          onPressed: _busy || selected == 0
                              ? null
                              : () => _confirmReset(changed),
                          child: Text(
                            _busy ? 'Resetting…' : 'Reset selected ($selected)',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final value in changed) ...[
                      CheckboxListTile(
                        key: ValueKey('changed-${value.id}'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(value.title),
                        subtitle: Text(
                          '${value.category} (${value.scope})\nCurrent: ${value.currentLabel}\nDefault: ${value.defaultLabel}',
                        ),
                        value: _selected.contains(value.id),
                        onChanged: _busy
                            ? null
                            : (selected) => setState(
                                () => selected == true
                                    ? _selected.add(value.id)
                                    : _selected.remove(value.id),
                              ),
                      ),
                      const Divider(height: 1),
                    ],
                  ],
                ],
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: AppTheme.danger),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _reset(_lastReset),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            if (_message != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _message!,
                    style: const TextStyle(color: AppTheme.success),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _SettingsTransferControls extends StatefulWidget {
  const _SettingsTransferControls({
    required this.controller,
    required this.preferences,
    this.pickExportPath,
    this.pickImportPath,
  });
  final PlayerController controller;
  final AppPreferencesRepository preferences;
  final Future<String?> Function()? pickExportPath, pickImportPath;
  @override
  State<_SettingsTransferControls> createState() =>
      _SettingsTransferControlsState();
}

class _SettingsTransferControlsState extends State<_SettingsTransferControls> {
  bool _busy = false;
  bool _failed = false;
  String? _message;
  static const _jsonType = XTypeGroup(
    label: 'Mpvson settings',
    extensions: ['json'],
  );

  SettingsBackup _capture() => SettingsBackup(
    desktop: widget.preferences.preferences,
    playbackSettings: widget.controller.playbackSettings,
    controlDensity: widget.controller.controlDensity,
    rate: widget.controller.rate,
    shuffle: widget.controller.shuffle,
    repeatMode: widget.controller.repeatMode,
  );

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = error.message;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _failed = true;
          _message =
              'Could not transfer settings. Choose a readable or writable location and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _export() async {
    final String? selected;
    if (widget.pickExportPath != null) {
      selected = await widget.pickExportPath!();
    } else {
      selected = (await getSaveLocation(
        suggestedName: 'mpvson-settings.json',
        acceptedTypeGroups: const [_jsonType],
      ))?.path;
    }
    if (selected == null || selected.isEmpty) return null;
    await File(
      selected,
    ).writeAsString(_capture().encode(), encoding: utf8, flush: true);
    return 'Settings exported.';
  }

  Future<String?> _import() async {
    final String? path;
    if (widget.pickImportPath != null) {
      path = await widget.pickImportPath!();
    } else {
      path = (await openFile(acceptedTypeGroups: const [_jsonType]))?.path;
    }
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (await file.length() > SettingsBackup.maximumBytes) {
      throw const FormatException('This settings file is too large.');
    }
    final backup = SettingsBackup.decode(
      await file.readAsString(encoding: utf8),
    );
    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import these settings?'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Replace player preferences, subtitle styling, language priorities, opening behavior, and keyboard shortcuts with the backup.',
              ),
              const SizedBox(height: 12),
              Text(
                'Control size: ${backup.controlDensity.name}\nPlayback speed: ${backup.rate}×\nSubtitle font: ${backup.playbackSettings.subtitleFont}\nSubtitle size: ${backup.playbackSettings.subtitleFontSize}\nAudio languages: ${backup.playbackSettings.preferredAudioLanguages.isEmpty ? 'Automatic' : backup.playbackSettings.preferredAudioLanguages}\nSubtitle languages: ${backup.playbackSettings.preferredSubtitleLanguages.isEmpty ? 'Automatic' : backup.playbackSettings.preferredSubtitleLanguages}\nCustom shortcuts: ${backup.desktop.shortcutOverrides.length}',
              ),
              const SizedBox(height: 12),
              const Text(
                'Your queue, library folders, playback history, saved URLs, and privacy recording choices stay as they are.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-import-settings'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import settings'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return null;
    // Validation above completes before the first mutation. Preserve local
    // navigation and recording choices rather than importing a saved session.
    final preferences = widget.preferences.preferences.copyWith(
      openBehavior: backup.desktop.openBehavior,
      clearOpenBehavior: backup.desktop.openBehavior == null,
      keepAwakeDuringPlayback: backup.desktop.keepAwakeDuringPlayback,
      shortcutOverrides: backup.desktop.shortcutOverrides,
    );
    await widget.preferences.updatePreferences(preferences);
    widget.controller.setControlDensity(backup.controlDensity);
    await widget.controller.setPlaybackSettings(backup.playbackSettings);
    await widget.controller.setRate(backup.rate);
    if (widget.controller.shuffle != backup.shuffle) {
      await widget.controller.toggleShuffle();
    }
    await widget.controller.setRepeatMode(backup.repeatMode);
    await widget.controller.saveSession();
    if (widget.preferences.saveError != null ||
        widget.controller.playbackSettingsError != null) {
      if (mounted) setState(() => _failed = true);
      return widget.preferences.saveError ??
          'Settings imported, but the playback engine could not confirm every change. Retry the affected setting.';
    }
    return 'Settings imported.';
  }

  @override
  Widget build(BuildContext context) => _SettingAnchor(
    id: 'settings-backup',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(title: 'Backup & restore'),
        const Text(
          'Move your player preferences between computers. Media, library folders, history, saved URLs, and privacy recording choices are excluded.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('export-settings'),
              onPressed: _busy ? null : () => _run(_export),
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('Export settings'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('import-settings'),
              onPressed: _busy ? null : () => _run(_import),
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: const Text('Import settings'),
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Working…'),
          ),
        if (_message != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _failed ? AppTheme.danger : AppTheme.success,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
