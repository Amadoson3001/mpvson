part of 'settings_dialog.dart';

class _ResumeBehaviorSettings extends StatelessWidget {
  const _ResumeBehaviorSettings({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final settings = controller.playbackSettings;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Resume behavior'),
          _SettingAnchor(
            id: 'resume-behavior',
            child: SizedBox(
              width: double.infinity,
              child: DropdownButton<ResumeBehavior>(
                isExpanded: true,
                value: settings.resumeBehavior,
                items: const [
                  DropdownMenuItem(
                    value: ResumeBehavior.automatic,
                    child: Text('Resume automatically'),
                  ),
                  DropdownMenuItem(
                    value: ResumeBehavior.ask,
                    child: Text('Ask each time'),
                  ),
                  DropdownMenuItem(
                    value: ResumeBehavior.startOver,
                    child: Text('Start from the beginning'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    unawaited(
                      controller.setPlaybackSettings(
                        controller.playbackSettings.copyWith(
                          resumeBehavior: value,
                        ),
                      ),
                    );
                  }
                },
                underline: const SizedBox.shrink(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 33, bottom: 8),
            child: Text(
              switch (settings.resumeBehavior) {
                ResumeBehavior.automatic =>
                  'Continue from the saved position when media is reopened.',
                ResumeBehavior.ask =>
                  'Choose whether to continue or start over each time.',
                ResumeBehavior.startOver =>
                  'Start each reopened item from the beginning.',
              },
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
            ),
          ),
        ],
      );
    },
  );
}

class _SubtitleAppearanceSettings extends StatefulWidget {
  const _SubtitleAppearanceSettings({required this.controller});

  final PlayerController controller;

  @override
  State<_SubtitleAppearanceSettings> createState() =>
      _SubtitleAppearanceSettingsState();
}

class _SubtitleAppearanceSettingsState
    extends State<_SubtitleAppearanceSettings> {
  PlaybackSettings _draft = PlaybackSettings.defaults;
  bool _dragging = false;

  PlaybackSettings get _settings =>
      _dragging ? _draft : widget.controller.playbackSettings;

  void _preview(PlaybackSettings value) {
    setState(() {
      _dragging = true;
      _draft = value;
    });
  }

  void _apply(PlaybackSettings Function(PlaybackSettings) change) {
    final value = change(widget.controller.playbackSettings).normalized();
    setState(() {
      _dragging = false;
      _draft = value;
    });
    unawaited(widget.controller.setPlaybackSettings(value));
  }

  void _reset() => _apply((current) {
    const defaults = PlaybackSettings.defaults;
    return current.copyWith(
      subtitleFont: defaults.subtitleFont,
      subtitleFontSize: defaults.subtitleFontSize,
      subtitleColor: defaults.subtitleColor,
      subtitleOutlineSize: defaults.subtitleOutlineSize,
      subtitleBackgroundOpacity: defaults.subtitleBackgroundOpacity,
      subtitlePosition: defaults.subtitlePosition,
    );
  });

  Widget _anchor(String id, Widget child) =>
      _SettingAnchor(id: id, child: child);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final settings = _settings;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(title: 'Subtitle appearance'),
          const Text(
            'Preview the player style. Subtitle files may include styling of their own.',
          ),
          const SizedBox(height: 10),
          _SubtitlePreview(settings: settings),
          const SizedBox(height: 14),
          _anchor(
            'subtitle-font',
            _SubtitleTextField(
              key: const ValueKey('subtitle-font-input'),
              label: 'Font family',
              value: settings.subtitleFont,
              hint: 'For example, sans-serif',
              resetValue: PlaybackSettings.defaults.subtitleFont,
              validator: (value) => value.trim().isEmpty
                  ? 'Enter a font family.'
                  : value.trim().length > 80
                  ? 'Use 80 characters or fewer.'
                  : null,
              onCommit: (value) => _apply(
                (current) => current.copyWith(subtitleFont: value.trim()),
              ),
            ),
          ),
          _anchor(
            'subtitle-font-size',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SubtitleNumberField(
                  key: const ValueKey('subtitle-font-size-input'),
                  label: 'Text size',
                  value: settings.subtitleFontSize,
                  minimum: 12,
                  maximum: 120,
                  resetValue: PlaybackSettings.defaults.subtitleFontSize,
                  onCommit: (value) => _apply(
                    (current) => current.copyWith(subtitleFontSize: value),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 12, bottom: 6),
                  child: Text('Scales with video size.'),
                ),
              ],
            ),
          ),
          _anchor(
            'subtitle-color',
            _SubtitleTextField(
              key: const ValueKey('subtitle-color-input'),
              label: 'Text color',
              value: settings.subtitleColor,
              hint: '#FFFFFF',
              resetValue: PlaybackSettings.defaults.subtitleColor,
              validator: (value) =>
                  RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value.trim())
                  ? null
                  : 'Enter a color as #RRGGBB.',
              onCommit: (value) => _apply(
                (current) =>
                    current.copyWith(subtitleColor: value.trim().toUpperCase()),
              ),
              trailing: _ColorSwatch(value: settings.subtitleColor),
            ),
          ),
          _anchor(
            'subtitle-outline',
            _SubtitleNumberField(
              key: const ValueKey('subtitle-outline-input'),
              label: 'Outline width',
              value: settings.subtitleOutlineSize,
              minimum: 0,
              maximum: 10,
              resetValue: PlaybackSettings.defaults.subtitleOutlineSize,
              onCommit: (value) => _apply(
                (current) => current.copyWith(subtitleOutlineSize: value),
              ),
            ),
          ),
          _anchor(
            'subtitle-background-opacity',
            _SubtitleSlider(
              key: const ValueKey('subtitle-background-opacity'),
              label: 'Background opacity',
              value: settings.subtitleBackgroundOpacity,
              minimum: 0,
              maximum: 1,
              formatValue: (value) => '${(value * 100).round()}%',
              resetValue: PlaybackSettings.defaults.subtitleBackgroundOpacity,
              onChanged: (value) => _preview(
                widget.controller.playbackSettings.copyWith(
                  subtitleBackgroundOpacity: value,
                ),
              ),
              onChangeEnd: (value) => _apply(
                (current) => current.copyWith(subtitleBackgroundOpacity: value),
              ),
            ),
          ),
          _anchor(
            'subtitle-position',
            _SubtitleSlider(
              key: const ValueKey('subtitle-position'),
              label: 'Vertical position',
              value: settings.subtitlePosition,
              minimum: 0,
              maximum: 100,
              formatValue: (value) => '${value.round()}% from top',
              resetValue: PlaybackSettings.defaults.subtitlePosition,
              onChanged: (value) => _preview(
                widget.controller.playbackSettings.copyWith(
                  subtitlePosition: value,
                ),
              ),
              onChangeEnd: (value) => _apply(
                (current) => current.copyWith(subtitlePosition: value),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('reset-subtitle-appearance'),
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Reset subtitle appearance'),
            ),
          ),
        ],
      );
    },
  );
}

class _SubtitlePreview extends StatelessWidget {
  const _SubtitlePreview({required this.settings});

  final PlaybackSettings settings;

  @override
  Widget build(BuildContext context) {
    final color = _subtitleColor(settings.subtitleColor);
    final position = settings.subtitlePosition.clamp(0, 100) / 50 - 1;
    final scale = (settings.subtitleFontSize / 55).clamp(.55, 1.8);
    final outline = settings.subtitleOutlineSize;
    return Container(
      key: const ValueKey('subtitle-live-preview'),
      height: 148,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff253141),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.border),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                height: 46,
                color: Colors.white.withValues(alpha: .035),
              ),
            ),
          ),
          Align(
            alignment: Alignment(0, position),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(
                  alpha: settings.subtitleBackgroundOpacity,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'A sample subtitle',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontFamily: settings.subtitleFont,
                  fontFamilyFallback: [
                    Theme.of(context).textTheme.bodyMedium?.fontFamily ??
                        'Segoe UI',
                    'Noto Sans',
                    'DejaVu Sans',
                  ],
                  fontSize: (16 * scale).clamp(12, 30),
                  height: 1.2,
                  shadows: outline <= 0
                      ? null
                      : [
                          for (final offset in const [
                            Offset(-1, -1),
                            Offset(1, -1),
                            Offset(-1, 1),
                            Offset(1, 1),
                          ])
                            Shadow(
                              color: Colors.black,
                              blurRadius: outline,
                              offset: offset,
                            ),
                        ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleTextField extends StatefulWidget {
  const _SubtitleTextField({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
    required this.resetValue,
    required this.validator,
    required this.onCommit,
    this.trailing,
  });

  final String label;
  final String value;
  final String hint;
  final String resetValue;
  final String? Function(String value) validator;
  final ValueChanged<String> onCommit;
  final Widget? trailing;

  @override
  State<_SubtitleTextField> createState() => _SubtitleTextFieldState();
}

class _SubtitleTextFieldState extends State<_SubtitleTextField> {
  late final TextEditingController _edit = TextEditingController(
    text: widget.value,
  );
  String? _error;

  @override
  void didUpdateWidget(covariant _SubtitleTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_edit.value.composing.isValid) {
      _edit.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  void _commit() {
    final error = widget.validator(_edit.text);
    setState(() => _error = error);
    if (error == null) widget.onCommit(_edit.text);
  }

  void _reset() {
    _edit.text = widget.resetValue;
    setState(() => _error = null);
    widget.onCommit(widget.resetValue);
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _edit,
                decoration: InputDecoration(
                  labelText: widget.label,
                  hintText: widget.hint,
                  errorText: _error,
                  suffixIcon: widget.trailing,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commit(),
                onTapOutside: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Reset ${widget.label.toLowerCase()}',
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SubtitleNumberField extends StatefulWidget {
  const _SubtitleNumberField({
    super.key,
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.resetValue,
    required this.onCommit,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final double resetValue;
  final ValueChanged<double> onCommit;

  @override
  State<_SubtitleNumberField> createState() => _SubtitleNumberFieldState();
}

class _SubtitleNumberFieldState extends State<_SubtitleNumberField> {
  late final TextEditingController _edit = TextEditingController(
    text: _format(widget.value),
  );
  String? _error;

  static String _format(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toString();

  @override
  void didUpdateWidget(covariant _SubtitleNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_edit.value.composing.isValid) {
      _edit.text = _format(widget.value);
    }
  }

  void _commit() {
    final value = double.tryParse(_edit.text.trim());
    if (value == null ||
        !value.isFinite ||
        value < widget.minimum ||
        value > widget.maximum) {
      setState(
        () => _error =
            'Enter a value from ${_format(widget.minimum)} to ${_format(widget.maximum)}.',
      );
      return;
    }
    setState(() => _error = null);
    _edit.text = _format(value);
    widget.onCommit(value);
  }

  void _reset() {
    _edit.text = _format(widget.resetValue);
    setState(() => _error = null);
    widget.onCommit(widget.resetValue);
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _edit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _commit(),
            onTapOutside: (_) => _commit(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Reset ${widget.label.toLowerCase()}',
          onPressed: _reset,
          icon: const Icon(Icons.restart_alt_rounded),
        ),
      ],
    ),
  );
}

class _SubtitleSlider extends StatelessWidget {
  const _SubtitleSlider({
    super.key,
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.formatValue,
    required this.resetValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final String Function(double) formatValue;
  final double resetValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            formatValue(value),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          IconButton(
            tooltip: 'Reset ${label.toLowerCase()}',
            onPressed: () => onChangeEnd(resetValue),
            icon: const Icon(Icons.restart_alt_rounded),
          ),
        ],
      ),
      Slider(
        value: value.clamp(minimum, maximum),
        min: minimum,
        max: maximum,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    ],
  );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(10),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _subtitleColor(value),
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.border),
      ),
      child: const SizedBox(width: 16, height: 16),
    ),
  );
}

Color _subtitleColor(String value) {
  final normalized = value.replaceFirst('#', '');
  final parsed = int.tryParse(normalized, radix: 16);
  return parsed == null ? Colors.white : Color(0xff000000 | parsed);
}

class _LanguagePreferences extends StatefulWidget {
  const _LanguagePreferences({required this.controller});

  final PlayerController controller;

  @override
  State<_LanguagePreferences> createState() => _LanguagePreferencesState();
}

class _LanguagePreferencesState extends State<_LanguagePreferences> {
  late final _audio = TextEditingController(
    text: widget.controller.playbackSettings.preferredAudioLanguages,
  );
  late final _subtitles = TextEditingController(
    text: widget.controller.playbackSettings.preferredSubtitleLanguages,
  );
  String? _audioError;
  String? _subtitleError;

  Widget _anchor(String id, Widget child) =>
      _SettingAnchor(id: id, child: child);

  void _commit({required bool audio}) {
    final edit = audio ? _audio : _subtitles;
    final value = edit.text.split(',').map((tag) => tag.trim()).toList();
    final invalid = value.where((tag) {
      if (tag.isEmpty) return false;
      final candidate = PlaybackSettings(
        preferredAudioLanguages: audio ? tag : '',
        preferredSubtitleLanguages: audio ? '' : tag,
      ).normalized();
      return (audio
              ? candidate.preferredAudioLanguages
              : candidate.preferredSubtitleLanguages)
          .isEmpty;
    });
    final error = invalid.isEmpty
        ? null
        : 'Use language codes separated by commas, such as en, ja, pt-BR.';
    setState(() {
      if (audio) {
        _audioError = error;
      } else {
        _subtitleError = error;
      }
    });
    if (error != null) return;
    final settings = widget.controller.playbackSettings;
    unawaited(
      widget.controller.setPlaybackSettings(
        settings.copyWith(
          preferredAudioLanguages: audio
              ? value.where((tag) => tag.isNotEmpty).join(', ')
              : settings.preferredAudioLanguages,
          preferredSubtitleLanguages: audio
              ? settings.preferredSubtitleLanguages
              : value.where((tag) => tag.isNotEmpty).join(', '),
        ),
      ),
    );
  }

  void _resetLanguage({required bool audio}) {
    final settings = widget.controller.playbackSettings;
    if (audio) {
      _audio.clear();
      setState(() => _audioError = null);
      unawaited(
        widget.controller.setPlaybackSettings(
          settings.copyWith(preferredAudioLanguages: ''),
        ),
      );
    } else {
      _subtitles.clear();
      setState(() => _subtitleError = null);
      unawaited(
        widget.controller.setPlaybackSettings(
          settings.copyWith(preferredSubtitleLanguages: ''),
        ),
      );
    }
  }

  @override
  void dispose() {
    _audio.dispose();
    _subtitles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 22),
      const _SectionHeading(title: 'Future media'),
      const Text(
        'List preferred language codes in priority order, separated by commas.',
      ),
      const SizedBox(height: 8),
      _anchor(
        'preferred-audio-languages',
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('preferred-audio-languages'),
                controller: _audio,
                decoration: InputDecoration(
                  labelText: 'Audio language priority',
                  hintText: 'en, ja, pt-BR',
                  errorText: _audioError,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commit(audio: true),
                onTapOutside: (_) => _commit(audio: true),
              ),
            ),
            IconButton(
              tooltip: 'Reset audio language priority',
              onPressed: () => _resetLanguage(audio: true),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      _anchor(
        'preferred-subtitle-languages',
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('preferred-subtitle-languages'),
                controller: _subtitles,
                decoration: InputDecoration(
                  labelText: 'Subtitle language priority',
                  hintText: 'en, ja, pt-BR',
                  errorText: _subtitleError,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commit(audio: false),
                onTapOutside: (_) => _commit(audio: false),
              ),
            ),
            IconButton(
              tooltip: 'Reset subtitle language priority',
              onPressed: () => _resetLanguage(audio: false),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
      ),
    ],
  );
}
