part of 'settings_dialog.dart';

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.controller,
    required this.compactViewport,
    this.heading,
  });

  final PlayerController controller;
  final bool compactViewport;
  final Widget? heading;

  @override
  Widget build(BuildContext context) {
    final compact = controller.controlDensity == ControlDensity.compact;
    final settingDescription = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Control size',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppTheme.secondaryText,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          'Compact uses smaller buttons and leaves more room for the seek bar.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
    final selector = SegmentedButton<ControlDensity>(
      key: const ValueKey('control-density-selector'),
      segments: const [
        ButtonSegment<ControlDensity>(
          value: ControlDensity.compact,
          label: Text('Compact'),
        ),
        ButtonSegment<ControlDensity>(
          value: ControlDensity.normal,
          label: Text('Normal'),
        ),
      ],
      selected: {controller.controlDensity},
      showSelectedIcon: false,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppTheme.accent
              : AppTheme.card;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppTheme.accentForeground
              : AppTheme.secondaryText;
        }),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return const BorderSide(color: AppTheme.accent, width: 2);
          }
          return const BorderSide(color: AppTheme.border);
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      onSelectionChanged: (selection) {
        controller.setControlDensity(selection.first);
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 520;
        return SingleChildScrollView(
          key: const PageStorageKey<String>('settings-appearance'),
          padding: EdgeInsets.fromLTRB(
            18,
            compactViewport ? 6 : 14,
            18,
            compactViewport ? 8 : 18,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?heading,
              if (stacked)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    settingDescription,
                    const SizedBox(height: 10),
                    _SettingAnchor(id: 'control-size', child: selector),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: settingDescription),
                    const SizedBox(width: 12),
                    _SettingAnchor(id: 'control-size', child: selector),
                  ],
                ),
              SizedBox(height: compactViewport ? 8 : 18),
              Container(
                padding: EdgeInsets.all(compactViewport ? 8 : 12),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live preview',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppTheme.secondaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: compactViewport ? 6 : 10),
                    ExcludeSemantics(
                      child: _ControlBarPreview(
                        compact: compact,
                        compactViewport: compactViewport,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ControlBarPreview extends StatelessWidget {
  const _ControlBarPreview({
    required this.compact,
    required this.compactViewport,
  });

  final bool compact;
  final bool compactViewport;

  @override
  Widget build(BuildContext context) {
    final buttonSize = compact ? 32.0 : 44.0;
    final iconSize = compact ? 18.0 : 22.0;
    final previewHeight = compactViewport
        ? (compact ? 66.0 : 86.0)
        : (compact ? 148.0 : 168.0);
    final barHeight = compact
        ? (compactViewport ? 50.0 : 60.0)
        : (compactViewport ? 70.0 : 88.0);

    return Container(
      key: const ValueKey('control-density-preview'),
      height: previewHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: barHeight,
            child: Center(
              child: Icon(
                Icons.movie_outlined,
                size: compactViewport ? 16 : 18,
                color: AppTheme.muted.withValues(alpha: 0.32),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: barHeight,
              color: AppTheme.surface,
              padding: EdgeInsets.fromLTRB(
                compact ? 8 : (compactViewport ? 14 : 22),
                compact
                    ? (compactViewport ? 4 : 8)
                    : (compactViewport ? 8 : 16),
                compact ? 8 : (compactViewport ? 14 : 22),
                compact
                    ? (compactViewport ? 4 : 6)
                    : (compactViewport ? 8 : 12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(
                    value: 0.38,
                    minHeight: compact ? 4 : 3,
                    backgroundColor: AppTheme.border,
                    color: AppTheme.accent,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.skip_previous_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: buttonSize,
                              height: buttonSize,
                              decoration: const BoxDecoration(
                                color: AppTheme.accent,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: iconSize + 2,
                                color: AppTheme.accentForeground,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.skip_next_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.volume_up_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: compact ? 52 : (compactViewport ? 56 : 72),
                              child: const LinearProgressIndicator(
                                value: 0.7,
                                minHeight: 3,
                                backgroundColor: AppTheme.border,
                                color: AppTheme.secondaryText,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(4),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              Icons.queue_music_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.fullscreen_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings({required this.controller, this.heading});
  final PlayerController controller;
  final Widget? heading;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const PageStorageKey<String>('settings-playback'),
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?heading,
        const _SectionHeading(title: 'Playback behavior'),
        _ResumeBehaviorSettings(controller: controller),
        const Divider(height: 1),
        _SettingAnchor(
          id: 'shuffle',
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Shuffle'),
            subtitle: const Text('Play queued videos in a shuffled order'),
            value: controller.shuffle,
            onChanged: (_) => unawaited(controller.toggleShuffle()),
          ),
        ),
        const Divider(height: 1),
        _SettingAnchor(
          id: 'speed',
          child: _RateSetting(controller: controller),
        ),
        const Divider(height: 1),
        _SettingAnchor(
          id: 'repeat',
          child: _DropdownSetting<String>(
            icon: Icons.repeat_rounded,
            label: 'Repeat',
            value: controller.repeatMode,
            items: const [
              DropdownMenuItem(value: 'off', child: Text('Off')),
              DropdownMenuItem(value: 'all', child: Text('Queue')),
              DropdownMenuItem(value: 'one', child: Text('Current video')),
            ],
            onChanged: (v) {
              if (v != null) unawaited(controller.setRepeatMode(v));
            },
          ),
        ),
      ],
    ),
  );
}

class _RateSetting extends StatefulWidget {
  const _RateSetting({required this.controller});
  final PlayerController controller;
  @override
  State<_RateSetting> createState() => _RateSettingState();
}

class _RateSettingState extends State<_RateSetting> {
  late final TextEditingController _edit = TextEditingController(
    text: widget.controller.rate.toString(),
  );
  String? _error;
  late final FocusNode _focus = FocusNode()..addListener(_handleFocusChange);
  bool _skipBlurCommit = false;
  String get _currentText => widget.controller.rate.toString();
  String _startText = '';
  void _handleFocusChange() {
    if (_focus.hasFocus) {
      _startText = _edit.text;
      return;
    }
    if (_skipBlurCommit) {
      _skipBlurCommit = false;
      return;
    }
    if (_edit.text != _startText) _commit();
  }

  void _commit() {
    final value = double.tryParse(_edit.text.trim());
    if (value == null || !value.isFinite || value < .25 || value > 4) {
      setState(() => _error = 'Enter a speed from 0.25× to 4×.');
      return;
    }
    setState(() => _error = null);
    _edit.text = value.toString();
    _startText = _edit.text;
    unawaited(widget.controller.setRate(value));
  }

  @override
  void dispose() {
    _focus.dispose();
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.speed_rounded,
              color: AppTheme.secondaryText,
              size: 21,
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('Playback speed')),
            SizedBox(
              width: 96,
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    _skipBlurCommit = true;
                    _edit.text = _currentText;
                    setState(() => _error = null);
                    _focus.unfocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey('playback-speed-input'),
                  controller: _edit,
                  focusNode: _focus,
                  textAlign: TextAlign.end,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: '×',
                  ),
                  onSubmitted: (_) => _commit(),
                  onEditingComplete: _commit,
                  onTapOutside: (_) =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Apply speed',
              onPressed: _commit,
              icon: const Icon(Icons.check_rounded),
            ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (widget.controller.error?.contains('playback speed') == true)
          Text(
            widget.controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}

class _AudioSubtitleSettings extends StatefulWidget {
  const _AudioSubtitleSettings({
    required this.controller,
    required this.pickSubtitle,
    this.heading,
  });
  final PlayerController controller;
  final Future<String?> Function() pickSubtitle;
  final Widget? heading;
  @override
  State<_AudioSubtitleSettings> createState() => _AudioSubtitleSettingsState();
}

class _AudioSubtitleSettingsState extends State<_AudioSubtitleSettings> {
  bool _loading = false;
  String? _message;
  Future<void> _pick() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final path = await widget.pickSubtitle();
      if (path == null || path.isEmpty) return;
      final ok = await widget.controller.loadSubtitle(path);
      if (mounted && !ok) {
        setState(
          () => _message =
              widget.controller.error ?? 'Could not load the subtitle file.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = 'Could not open the subtitle picker. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => SingleChildScrollView(
      key: const PageStorageKey<String>('settings-audio-subtitles'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?widget.heading,
          const _SectionHeading(title: 'Current media'),
          const Text('Choose tracks for what is playing now.'),
          const SizedBox(height: 8),
          _SettingAnchor(
            id: 'audio-track',
            child: _TrackSetting<AudioTrack>(
              icon: Icons.audiotrack_rounded,
              label: 'Audio',
              tracks: widget.controller.audioTracks,
              selected: widget.controller.currentAudioTrack,
              trackLabel: (t) => _trackLabel(t.id, t.title, t.language),
              onSelected: (t) => unawaited(widget.controller.setAudioTrack(t)),
            ),
          ),
          const SizedBox(height: 20),
          _SettingAnchor(
            id: 'subtitle-track',
            child: _TrackSetting<SubtitleTrack>(
              icon: Icons.subtitles_rounded,
              label: 'Subtitles',
              tracks: widget.controller.subtitleTracks,
              selected: widget.controller.currentSubtitleTrack,
              trackLabel: (t) => _trackLabel(t.id, t.title, t.language),
              onSelected: (t) =>
                  unawaited(widget.controller.setSubtitleTrack(t)),
            ),
          ),
          const Divider(height: 1),
          _SettingAnchor(
            id: 'load-subtitle',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 48,
              leading: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.note_add_outlined),
              title: Text(
                _loading ? 'Loading subtitle…' : 'Load subtitle file',
              ),
              enabled:
                  widget.controller.hasMedia &&
                  widget.controller.isVideo &&
                  !_loading,
              onTap:
                  _loading ||
                      !widget.controller.hasMedia ||
                      !widget.controller.isVideo
                  ? null
                  : _pick,
            ),
          ),
          if (!widget.controller.hasMedia || !widget.controller.isVideo)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                'Load a video before selecting an external subtitle.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
              ),
            ),
          const SizedBox(height: 20),
          const _SectionHeading(title: 'Timing'),
          _DelaySettings(controller: widget.controller),
          const SizedBox(height: 20),
          _SubtitleAppearanceSettings(controller: widget.controller),
          _LanguagePreferences(controller: widget.controller),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class _DelaySettings extends StatefulWidget {
  const _DelaySettings({required this.controller});
  final PlayerController controller;
  @override
  State<_DelaySettings> createState() => _DelaySettingsState();
}

class _DelaySettingsState extends State<_DelaySettings> {
  late double _audioDraft =
      widget.controller.playbackSettings.audioDelaySeconds;
  late double _subtitleDraft =
      widget.controller.playbackSettings.subtitleDelaySeconds;
  bool _audioDragging = false;
  bool _subtitleDragging = false;

  void _changeAudio(double value) => setState(() {
    _audioDragging = true;
    _audioDraft = value;
  });
  void _changeSubtitle(double value) => setState(() {
    _subtitleDragging = true;
    _subtitleDraft = value;
  });

  void _commitAudio(double value) {
    setState(() {
      _audioDraft = value;
      _audioDragging = false;
    });
    unawaited(
      widget.controller.setPlaybackSettings(
        widget.controller.playbackSettings.copyWith(audioDelaySeconds: value),
      ),
    );
  }

  void _commitSubtitle(double value) {
    setState(() {
      _subtitleDraft = value;
      _subtitleDragging = false;
    });
    unawaited(
      widget.controller.setPlaybackSettings(
        widget.controller.playbackSettings.copyWith(
          subtitleDelaySeconds: value,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_audioDragging) {
      _audioDraft = widget.controller.playbackSettings.audioDelaySeconds;
    }
    if (!_subtitleDragging) {
      _subtitleDraft = widget.controller.playbackSettings.subtitleDelaySeconds;
    }
    return Column(
      children: [
        _SettingAnchor(
          id: 'audio-delay',
          child: _PlaybackSettingSlider(
            key: const ValueKey('playback-audio-delay'),
            label: 'Audio delay',
            value: _audioDraft,
            min: -10,
            max: 10,
            divisions: 200,
            formatValue: _secondsValue,
            onChanged: _changeAudio,
            onChangeEnd: _commitAudio,
            onReset: () => _commitAudio(0),
          ),
        ),
        _SettingAnchor(
          id: 'subtitle-delay',
          child: _PlaybackSettingSlider(
            key: const ValueKey('playback-subtitle-delay'),
            label: 'Subtitle delay',
            value: _subtitleDraft,
            min: -10,
            max: 10,
            divisions: 200,
            formatValue: _secondsValue,
            onChanged: _changeSubtitle,
            onChangeEnd: _commitSubtitle,
            onReset: () => _commitSubtitle(0),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(() {
                _audioDraft = 0;
                _subtitleDraft = 0;
                _audioDragging = false;
                _subtitleDragging = false;
              });
              unawaited(
                widget.controller.setPlaybackSettings(
                  widget.controller.playbackSettings.copyWith(
                    audioDelaySeconds: 0,
                    subtitleDelaySeconds: 0,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Reset timing'),
          ),
        ),
      ],
    );
  }
}

class _VideoSettings extends StatefulWidget {
  const _VideoSettings({required this.controller, this.heading});

  final PlayerController controller;
  final Widget? heading;

  @override
  State<_VideoSettings> createState() => _VideoSettingsState();
}

class _VideoSettingsState extends State<_VideoSettings> {
  late PlaybackSettings _draft = widget.controller.playbackSettings;
  bool _sliderChanging = false;

  void _changeDraft(PlaybackSettings value) {
    _sliderChanging = true;
    setState(() => _draft = value.normalized());
  }

  void _applyLatest(PlaybackSettings Function(PlaybackSettings) update) {
    final normalized = update(widget.controller.playbackSettings).normalized();
    _sliderChanging = false;
    setState(() => _draft = normalized);
    unawaited(widget.controller.setPlaybackSettings(normalized));
  }

  @override
  Widget build(BuildContext context) {
    if (!_sliderChanging) _draft = widget.controller.playbackSettings;
    return SingleChildScrollView(
      key: const PageStorageKey<String>('settings-video'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?widget.heading,
          const _SectionHeading(title: 'Video quality'),
          _SettingAnchor(
            id: 'quality',
            child: _DropdownSetting<PlaybackQualityPreset>(
              icon: Icons.high_quality_rounded,
              label: 'Quality preset',
              value: _draft.qualityPreset,
              items: PlaybackQualityPreset.values
                  .map(
                    (preset) => DropdownMenuItem<PlaybackQualityPreset>(
                      value: preset,
                      child: Text(preset.label),
                    ),
                  )
                  .toList(),
              onChanged: (preset) {
                if (preset != null) {
                  _applyLatest((s) => s.copyWith(qualityPreset: preset));
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 33, bottom: 4),
            child: Text(
              switch (_draft.qualityPreset) {
                PlaybackQualityPreset.performance =>
                  'Uses faster scaling for lower GPU load.',
                PlaybackQualityPreset.balanced =>
                  'Balances scaling detail and playback cost.',
                PlaybackQualityPreset.quality =>
                  'Uses sharper scaling and debanding; GPU load may increase.',
              },
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
            ),
          ),
          _SettingAnchor(
            id: 'hardware-decoding',
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer hardware decoding'),
              subtitle: const Text(
                'Use a supported GPU decoder when available. Turn off to use the '
                'software decoder.',
              ),
              value: _draft.preferHardwareDecoding,
              onChanged: (value) => _applyLatest(
                (s) => s.copyWith(preferHardwareDecoding: value),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _SectionHeading(title: 'Picture'),
          _SettingAnchor(
            id: 'brightness',
            child: _PlaybackSettingSlider(
              key: const ValueKey('playback-brightness'),
              label: 'Brightness',
              value: _draft.brightness,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: _colorValue,
              onChanged: (value) => _changeDraft(
                widget.controller.playbackSettings.copyWith(brightness: value),
              ),
              onChangeEnd: (value) =>
                  _applyLatest((s) => s.copyWith(brightness: value)),
              onReset: () => _applyLatest((s) => s.copyWith(brightness: 0)),
            ),
          ),
          _SettingAnchor(
            id: 'contrast',
            child: _PlaybackSettingSlider(
              key: const ValueKey('playback-contrast'),
              label: 'Contrast',
              value: _draft.contrast,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: _colorValue,
              onChanged: (value) => _changeDraft(
                widget.controller.playbackSettings.copyWith(contrast: value),
              ),
              onChangeEnd: (value) =>
                  _applyLatest((s) => s.copyWith(contrast: value)),
              onReset: () => _applyLatest((s) => s.copyWith(contrast: 0)),
            ),
          ),
          _SettingAnchor(
            id: 'saturation',
            child: _PlaybackSettingSlider(
              key: const ValueKey('playback-saturation'),
              label: 'Saturation',
              value: _draft.saturation,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: _colorValue,
              onChanged: (value) => _changeDraft(
                widget.controller.playbackSettings.copyWith(saturation: value),
              ),
              onChangeEnd: (value) =>
                  _applyLatest((s) => s.copyWith(saturation: value)),
              onReset: () => _applyLatest((s) => s.copyWith(saturation: 0)),
            ),
          ),
          _SettingAnchor(
            id: 'gamma',
            child: _PlaybackSettingSlider(
              key: const ValueKey('playback-gamma'),
              label: 'Gamma',
              value: _draft.gamma,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: _colorValue,
              onChanged: (value) => _changeDraft(
                widget.controller.playbackSettings.copyWith(gamma: value),
              ),
              onChangeEnd: (value) =>
                  _applyLatest((s) => s.copyWith(gamma: value)),
              onReset: () => _applyLatest((s) => s.copyWith(gamma: 0)),
            ),
          ),
          if (widget.controller.playbackSettingsError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Some settings were not confirmed by the playback engine: $error',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('reset-playback-settings'),
              onPressed: () {
                _applyLatest(
                  (current) => current.copyWith(
                    qualityPreset: PlaybackSettings.defaults.qualityPreset,
                    preferHardwareDecoding:
                        PlaybackSettings.defaults.preferHardwareDecoding,
                    brightness: 0,
                    contrast: 0,
                    saturation: 0,
                    gamma: 0,
                  ),
                );
              },
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset video settings'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackSettingSlider extends StatefulWidget {
  const _PlaybackSettingSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatValue,
    required this.onChanged,
    required this.onChangeEnd,
    this.onReset,
  });
  final String label;
  final double value, min, max;
  final int divisions;
  final String Function(double) formatValue;
  final ValueChanged<double> onChanged, onChangeEnd;
  final VoidCallback? onReset;
  @override
  State<_PlaybackSettingSlider> createState() => _PlaybackSettingSliderState();
}

class _PlaybackSettingSliderState extends State<_PlaybackSettingSlider> {
  late final TextEditingController _edit = TextEditingController(
    text: widget.value.toStringAsFixed(_precision),
  );
  int get _precision {
    final step = (widget.max - widget.min) / widget.divisions;
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    return 2;
  }

  late final FocusNode _focus = FocusNode()..addListener(_focusChanged);
  double _editStart = 0;
  String _editStartText = '';
  bool _skipBlurCommit = false;
  String? _error;
  void _focusChanged() {
    if (_focus.hasFocus) {
      _editStart = widget.value;
      _editStartText = _edit.text;
      return;
    }
    if (_skipBlurCommit) {
      _skipBlurCommit = false;
      return;
    }
    if (_edit.text != _editStartText) _commit();
  }

  @override
  void didUpdateWidget(covariant _PlaybackSettingSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focus.hasFocus) {
      _edit.text = widget.value.toStringAsFixed(_precision);
      _editStart = widget.value;
    }
  }

  void _commit() {
    final raw = double.tryParse(_edit.text.trim());
    if (raw == null ||
        !raw.isFinite ||
        raw < widget.min ||
        raw > widget.max ||
        (_precision == 0 && raw != raw.roundToDouble())) {
      setState(
        () => _error =
            'Enter a value from ${widget.formatValue(widget.min)} to ${widget.formatValue(widget.max)}.',
      );
      return;
    }
    setState(() => _error = null);
    _edit.text = raw.toStringAsFixed(_precision);
    _editStart = raw;
    widget.onChanged(raw);
    widget.onChangeEnd(raw);
  }

  @override
  void dispose() {
    _focus.dispose();
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 2),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 78,
              child: Semantics(
                label: '${widget.label} value',
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      _skipBlurCommit = true;
                      _edit.text = _editStart.toStringAsFixed(_precision);
                      setState(() => _error = null);
                      _focus.unfocus();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: ValueKey(
                      '${widget.key ?? widget.label}-numeric-input',
                    ),
                    controller: _edit,
                    focusNode: _focus,
                    textAlign: TextAlign.end,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      suffixText: widget.label.toLowerCase().contains('delay')
                          ? 's'
                          : null,
                    ),
                    onSubmitted: (_) => _commit(),
                    onEditingComplete: _commit,
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
              ),
            ),
            if (widget.onReset != null)
              IconButton(
                tooltip: 'Reset ${widget.label.toLowerCase()}',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onReset,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
              ),
          ],
        ),
        if (_error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        SliderOverlay(
          child: Slider(
            value: widget.value.clamp(widget.min, widget.max).toDouble(),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: widget.formatValue(widget.value),
            semanticFormatterCallback: (v) =>
                '${widget.label} ${widget.formatValue(v)}',
            onChanged: widget.onChanged,
            onChangeEnd: widget.onChangeEnd,
          ),
        ),
      ],
    ),
  );
}

String _colorValue(double value) =>
    value == 0 ? '0' : '${value > 0 ? '+' : ''}${value.toStringAsFixed(0)}';

String _secondsValue(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} s';

class _GeneralSettings extends StatefulWidget {
  const _GeneralSettings({
    required this.controller,
    required this.preferences,
    required this.desktopIntegration,
    this.pickExportPath,
    this.pickImportPath,
    this.heading,
  });
  final PlayerController controller;
  final AppPreferencesRepository preferences;
  final DesktopIntegrationService? desktopIntegration;
  final Future<String?> Function()? pickExportPath;
  final Future<String?> Function()? pickImportPath;
  final Widget? heading;
  @override
  State<_GeneralSettings> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends State<_GeneralSettings> {
  bool _launcherFailed = false;
  bool _openingDefaults = false;
  Future<void> _openDefaults() async {
    final service = widget.desktopIntegration;
    if (service == null || _openingDefaults) return;
    setState(() {
      _openingDefaults = true;
      _launcherFailed = false;
    });
    try {
      final accepted = await service.openDefaultAppsSettings();
      if (mounted) {
        setState(() {
          _launcherFailed = !accepted;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _launcherFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _openingDefaults = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.preferences,
    builder: (context, _) {
      final prefs = widget.preferences;
      final loaded = prefs.isLoaded;
      final saving = prefs.isSaving;
      final current = prefs.preferences.openBehavior;
      return SingleChildScrollView(
        key: const PageStorageKey<String>('settings-general'),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?widget.heading,
            const _SectionHeading(title: 'Opening files'),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Choose what happens when opening files during playback.',
              ),
            ),
            _SettingAnchor(
              id: 'open-behavior',
              child: RadioGroup<OpenBehaviorPreference>(
                groupValue: current,
                onChanged: (v) {
                  if (loaded && !saving && v != null) {
                    unawaited(prefs.setOpenBehavior(v));
                  }
                },
                child: Column(
                  children: [
                    RadioListTile<OpenBehaviorPreference>(
                      key: const ValueKey('open-behavior-keep-playing'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Keep playing and add to queue'),
                      subtitle: const Text(
                        'Add opened media without interrupting playback',
                      ),
                      value: OpenBehaviorPreference.keepPlayingAndEnqueue,
                    ),
                    RadioListTile<OpenBehaviorPreference>(
                      key: const ValueKey('open-behavior-play-now'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Play new files now'),
                      subtitle: const Text(
                        'Interrupt playback and start the new files',
                      ),
                      value: OpenBehaviorPreference.playNewFilesNow,
                    ),
                    RadioListTile<OpenBehaviorPreference>(
                      key: const ValueKey('open-behavior-ask-every-time'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Ask every time'),
                      subtitle: const Text('Choose what to do each time'),
                      value: OpenBehaviorPreference.askEveryTime,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 28),
            const _SectionHeading(title: 'Power and system'),
            _SettingAnchor(
              id: 'keep-awake',
              child: SwitchListTile.adaptive(
                key: const ValueKey('keep-awake-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep computer awake during playback'),
                subtitle: const Text(
                  'Prevents sleep while video playback is active',
                ),
                value: prefs.preferences.keepAwakeDuringPlayback,
                onChanged: !loaded || saving
                    ? null
                    : (v) => unawaited(prefs.setKeepAwake(v)),
              ),
            ),
            const Divider(height: 28),
            const _SectionHeading(title: 'System integration'),
            _SettingAnchor(
              id: 'default-apps',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('File associations'),
                subtitle: const Text(
                  'Manage file types and autoplay in your operating system',
                ),
                trailing: OutlinedButton.icon(
                  key: const ValueKey('default-apps-button'),
                  onPressed:
                      widget.desktopIntegration == null || _openingDefaults
                      ? null
                      : _openDefaults,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(_openingDefaults ? 'Opening…' : 'Default apps'),
                ),
              ),
            ),
            if (widget.desktopIntegration == null || _launcherFailed)
              Text(
                widget.desktopIntegration == null
                    ? 'System integration is unavailable.'
                    : 'Could not open system settings. Open your operating '
                          'system’s default-app settings to choose Mpvson.',
                style: TextStyle(
                  color: _launcherFailed
                      ? Theme.of(context).colorScheme.error
                      : AppTheme.secondaryText,
                ),
              ),
            const Divider(height: 28),
            const _SectionHeading(title: 'Backup and restore'),
            _SettingsTransferControls(
              controller: widget.controller,
              preferences: widget.preferences,
              pickExportPath: widget.pickExportPath,
              pickImportPath: widget.pickImportPath,
            ),
          ],
        ),
      );
    },
  );
}

class _MediaLibrarySettings extends StatelessWidget {
  const _MediaLibrarySettings({
    required this.libraryRepository,
    this.pickDirectory,
    this.heading,
  });

  final MediaLibraryRepository? libraryRepository;
  final Future<String?> Function()? pickDirectory;
  final Widget? heading;

  @override
  Widget build(BuildContext context) {
    final repository = libraryRepository;
    if (repository == null) {
      return SingleChildScrollView(
        key: const PageStorageKey<String>('settings-media-library-unavailable'),
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?heading,
            const Text(
              'The media library is unavailable in this player session.',
            ),
          ],
        ),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository,
        repository.scanStatusListenable,
      ]),
      builder: (context, _) {
        final folders = repository.folders;
        final status = repository.scanStatus;

        return SingleChildScrollView(
          key: const PageStorageKey<String>('settings-media-library'),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?heading,
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _SettingAnchor(
                    id: 'library-folders',
                    child: _LibraryActionButton(
                      key: const ValueKey('add-folder-button'),
                      label: 'Add folder',
                      icon: Icons.create_new_folder_outlined,
                      enabled: repository.isReady && !status.isScanning,
                      action: () async {
                        final path = await (pickDirectory != null
                            ? pickDirectory!()
                            : getDirectoryPath());
                        if (path != null && path.isNotEmpty) {
                          await repository.addFolder(path);
                        }
                      },
                    ),
                  ),
                  _LibraryActionButton(
                    key: const ValueKey('rescan-all-button'),
                    label: 'Rescan all folders',
                    icon: Icons.refresh_rounded,
                    enabled: repository.isReady && !status.isScanning,
                    action: repository.rescanAll,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (!repository.isReady)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    repository.initializationError ??
                        'Preparing the media library…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: repository.initializationError == null
                          ? AppTheme.secondaryText
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              _SettingAnchor(
                id: 'library-scan',
                child: Container(
                  key: const ValueKey('library-scan-progress'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        runSpacing: 6,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              if (status.isScanning) ...[
                                const Icon(
                                  Icons.sync_rounded,
                                  size: 16,
                                  color: AppTheme.accent,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Scanning library...',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.accent,
                                      ),
                                ),
                              ] else ...[
                                Icon(
                                  status.phase == ScanPhase.error
                                      ? Icons.error_outline_rounded
                                      : Icons.check_circle_outline_rounded,
                                  size: 16,
                                  color: status.phase == ScanPhase.error
                                      ? Theme.of(context).colorScheme.error
                                      : AppTheme.secondaryText,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  status.phase == ScanPhase.error
                                      ? 'Scan needs attention'
                                      : 'Scan idle',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: AppTheme.secondaryText),
                                ),
                              ],
                            ],
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              Text(
                                'Discovered: ${status.discoveredCount}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Enriched: ${status.enrichedCount}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (status.isScanning) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: status.totalToEnrich > 0
                              ? (status.enrichedCount / status.totalToEnrich)
                                    .clamp(0.0, 1.0)
                              : null,
                          backgroundColor: AppTheme.border,
                          color: AppTheme.accent,
                        ),
                      ],
                      if (status.isScanning)
                        Align(
                          alignment: Alignment.centerRight,
                          child: _LibraryActionButton(
                            label: 'Cancel scan',
                            icon: Icons.stop_rounded,
                            enabled: true,
                            action: repository.cancelScan,
                          ),
                        ),
                      if (status.errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Scan failed: ${status.errorMessage}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const _SectionHeading(title: 'Library folders'),
              if (folders.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(
                        Icons.folder_open_rounded,
                        size: 36,
                        color: AppTheme.secondaryText.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No folders added yet',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Add a media folder to index video and audio files.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.secondaryText.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: folders.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        folder.isAvailable
                            ? Icons.folder_rounded
                            : Icons.folder_off_rounded,
                        color: folder.isAvailable
                            ? AppTheme.accent
                            : Theme.of(context).colorScheme.error,
                      ),
                      title: Tooltip(
                        message: folder.path,
                        child: Text(
                          folder.path,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: folder.isAvailable
                                    ? AppTheme.primaryText
                                    : AppTheme.secondaryText,
                              ),
                        ),
                      ),
                      subtitle: Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          Text(
                            folder.isAvailable ? 'Available' : 'Unavailable',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: folder.isAvailable
                                      ? AppTheme.secondaryText
                                      : Theme.of(context).colorScheme.error,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${folder.fileCount} ${folder.fileCount == 1 ? 'file' : 'files'}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppTheme.secondaryText),
                          ),
                        ],
                      ),
                      trailing: _LibraryActionButton(
                        key: ValueKey('remove-folder-${folder.path}'),
                        label: 'Remove',
                        icon: Icons.delete_outline_rounded,
                        enabled: repository.isReady && !status.isScanning,
                        action: () =>
                            _confirmRemove(context, repository, folder.path),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    MediaLibraryRepository repository,
    String path,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove library folder?'),
        content: Text(
          'Remove $path from the indexed folders? The source files will stay on your computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove folder'),
          ),
        ],
      ),
    );
    if (confirmed == true) await repository.removeFolder(path);
  }
}

class _LibraryActionButton extends StatefulWidget {
  const _LibraryActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.action,
  });
  final String label;
  final IconData icon;
  final bool enabled;
  final Future<void> Function() action;
  @override
  State<_LibraryActionButton> createState() => _LibraryActionButtonState();
}

class _LibraryActionButtonState extends State<_LibraryActionButton> {
  bool _busy = false;
  String? _error;
  Future<void> _run() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.action();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              '${widget.label} failed. Check the folder and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      OutlinedButton.icon(
        onPressed: !widget.enabled || _busy ? null : _run,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(widget.icon, size: 18),
        label: Text(_busy ? 'Working…' : widget.label),
      ),
      if (_error != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: !widget.enabled || _busy ? null : _run,
              child: const Text('Retry'),
            ),
          ],
        ),
    ],
  );
}

class _HistoryPrivacySettings extends StatefulWidget {
  const _HistoryPrivacySettings({required this.controller, this.heading});
  final PlayerController controller;
  final Widget? heading;
  @override
  State<_HistoryPrivacySettings> createState() =>
      _HistoryPrivacySettingsState();
}

class _HistoryPrivacySettingsState extends State<_HistoryPrivacySettings> {
  String? _urlError;
  bool _urlBusy = false;
  Future<void> _setUrls(bool value) async {
    if (_urlBusy) return;
    setState(() {
      _urlBusy = true;
      _urlError = null;
    });
    try {
      final saved = await widget.controller.setSaveNetworkUrls(value);
      if (mounted && !saved) {
        setState(
          () => _urlError =
              widget.controller.error ??
              'Could not save the network URL setting.',
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _urlError = 'Could not save the network URL setting.');
      }
    } finally {
      if (mounted) setState(() => _urlBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => SingleChildScrollView(
      key: const PageStorageKey<String>('settings-history-privacy'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ?widget.heading,
          HistorySettings(
            controller: widget.controller,
            embedded: true,
            anchorBuilder: (id, child) => _SettingAnchor(id: id, child: child),
          ),
          const Divider(height: 28),
          _SettingAnchor(
            id: 'save-network-urls',
            child: SwitchListTile.adaptive(
              key: const ValueKey('save-network-urls-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Save network URLs between sessions'),
              subtitle: const Text(
                'Save complete stream URLs, including any access tokens, on '
                'this computer so network media can return in the queue. '
                'Turning this off removes saved URLs. History recording is '
                'controlled separately.',
              ),
              value: widget.controller.saveNetworkUrls,
              onChanged: _urlBusy ? null : _setUrls,
            ),
          ),
          if (_urlBusy) const Text('Saving changes…'),
          if (_urlError != null)
            Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _urlError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _urlBusy
                        ? null
                        : () => _setUrls(widget.controller.saveNetworkUrls),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: AppTheme.secondaryText,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _DropdownSetting<T> extends StatelessWidget {
  const _DropdownSetting({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label, selected $value',
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppTheme.secondaryText, size: 21),
              const SizedBox(width: 12),
              Text(label),
            ],
          ),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(8),
            items: items,
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

class _TrackSetting<T> extends StatelessWidget {
  const _TrackSetting({
    required this.icon,
    required this.label,
    required this.tracks,
    required this.selected,
    required this.trackLabel,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final List<T> tracks;
  final T? selected;
  final String Function(T) trackLabel;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    T? selectedValue;
    for (final track in tracks) {
      if (track == selected) {
        selectedValue = track;
        break;
      }
    }

    final currentDisplay = selectedValue != null
        ? trackLabel(selectedValue)
        : 'Unavailable';

    return Semantics(
      label: '$label track, selected $currentDisplay',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AppTheme.secondaryText, size: 21),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
            DropdownButton<T>(
              value: selectedValue,
              hint: const Text('Unavailable'),
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(8),
              items: tracks.map<DropdownMenuItem<T>>((track) {
                final itemText = trackLabel(track);
                final isSelected = track == selectedValue;
                return DropdownMenuItem<T>(
                  value: track,
                  child: Semantics(
                    selected: isSelected,
                    label: isSelected ? '$itemText, selected' : itemText,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(itemText, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                );
              }).toList(),
              onChanged: tracks.isEmpty
                  ? null
                  : (track) {
                      if (track != null) onSelected(track);
                    },
            ),
          ],
        ),
      ),
    );
  }
}

String _trackLabel(String id, String? rawTitle, String? rawLanguage) {
  if (id == 'auto') return 'Automatic';
  if (id == 'no') return 'Off';
  final title = (rawTitle ?? '').trim();
  final language = (rawLanguage ?? '').trim();
  if (title.isEmpty && language.isEmpty) return 'Track $id';
  if (title.isEmpty) return language;
  if (language.isEmpty) return title;
  return '$title ($language)';
}
