import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/services/yt_dlp_resolver.dart';
import '../../../../domain/models/playback_settings.dart';
import '../../../../utils/file_utils.dart';
import '../../../core/app_theme.dart';
import '../../../core/toast/app_toast.dart';
import '../../player_controller.dart';
import 'settings_shared_widgets.dart';

typedef YtDlpStatusChecker = Future<YtDlpStatus> Function(String? customPath);
typedef YtDlpExecutablePicker = Future<String?> Function();

class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({
    super.key,
    required this.controller,
    required this.pickSubtitle,
    this.embedded = false,
    this.appPreferences,
    this.checkYtDlpStatus,
    this.pickYtDlpExecutable,
    this.onOpenAppFolder,
  });

  final PlayerController controller;
  final Future<String?> Function() pickSubtitle;

  /// True when these settings render inline in the library shell rather than
  /// in their own dialog route. Only a dialog route may be popped here.
  final bool embedded;
  final AppPreferencesRepository? appPreferences;
  final YtDlpStatusChecker? checkYtDlpStatus;
  final YtDlpExecutablePicker? pickYtDlpExecutable;
  final VoidCallback? onOpenAppFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsCardGroup(
              title: 'Queue & session',
              children: [
                SettingsSwitchTile(
                  key: const ValueKey('auto-play-next-video-toggle'),
                  icon: Icons.smart_display_rounded,
                  title: 'Auto-play next video',
                  subtitle:
                      'Automatically starts the next video when the current one finishes.',
                  value: controller.autoPlayNextVideo,
                  onChanged: controller.setAutoPlayNextVideo,
                ),
                SettingsSwitchTile(
                  key: const ValueKey('auto-play-next-audio-toggle'),
                  icon: Icons.queue_music_rounded,
                  title: 'Auto-play next audio',
                  subtitle:
                      'Automatically starts the next audio track when the current one finishes.',
                  value: controller.autoPlayNextAudio,
                  onChanged: controller.setAutoPlayNextAudio,
                ),
                SettingsSwitchTile(
                  icon: Icons.shuffle_rounded,
                  title: 'Shuffle queue',
                  subtitle: 'Plays queue tracks and videos in random order.',
                  value: controller.shuffle,
                  onChanged: (_) => unawaited(controller.toggleShuffle()),
                ),
                SettingsSwitchTile(
                  key: const ValueKey('save-network-urls-toggle'),
                  icon: Icons.cloud_sync_outlined,
                  title: 'Save network URLs between sessions',
                  subtitle:
                      'Stores stream URLs with security tokens so network media stays in recent history.',
                  value: controller.saveNetworkUrls,
                  onChanged: (val) =>
                      unawaited(controller.setSaveNetworkUrls(val)),
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'Transport tuning',
              children: [
                DropdownSettingTile<double>(
                  icon: Icons.speed_rounded,
                  label: 'Playback speed',
                  value: nearestPlaybackRate(controller.rate),
                  items: const <double>[0.5, 0.75, 1, 1.25, 1.5, 2]
                      .map(
                        (rate) => DropdownMenuItem(
                          value: rate,
                          child: Text(rate == 1 ? '1.0× (Normal)' : '$rate×'),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) unawaited(controller.setRate(val));
                  },
                ),
                DropdownSettingTile<String>(
                  icon: Icons.repeat_rounded,
                  label: 'Repeat mode',
                  value: controller.repeatMode,
                  items: const [
                    DropdownMenuItem(value: 'off', child: Text('Off')),
                    DropdownMenuItem(value: 'all', child: Text('Repeat queue')),
                    DropdownMenuItem(
                      value: 'one',
                      child: Text('Repeat current'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) unawaited(_setRepeat(val));
                  },
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'Media tracks',
              children: [
                TrackSettingTile<AudioTrack>(
                  icon: Icons.audiotrack_rounded,
                  label: 'Audio track',
                  tracks: controller.audioTracks,
                  selected: controller.currentAudioTrack,
                  trackLabel: (t) =>
                      formatTrackLabel(t.id, t.title, t.language),
                  onSelected: (t) => unawaited(controller.setAudioTrack(t)),
                ),
                TrackSettingTile<SubtitleTrack>(
                  icon: Icons.subtitles_rounded,
                  label: 'Subtitle track',
                  tracks: controller.subtitleTracks,
                  selected: controller.currentSubtitleTrack,
                  trackLabel: (t) =>
                      formatTrackLabel(t.id, t.title, t.language),
                  onSelected: (t) => unawaited(controller.setSubtitleTrack(t)),
                ),
                ListTile(
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.note_add_outlined,
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: Text(
                    'Load external subtitle…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                  onTap: () async {
                    final route = ModalRoute.of(context);
                    final navigator = Navigator.maybeOf(context);
                    final toastContext = navigator?.context ?? context;
                    String? path;
                    try {
                      path = await pickSubtitle();
                    } catch (_) {
                      if (!toastContext.mounted) return;
                      AppToast.show(
                        toastContext,
                        'The file picker could not be opened.',
                        tone: AppToastTone.danger,
                      );
                      return;
                    }
                    if (path == null || path.isEmpty) return;
                    // Close the settings sheet once after a successful pick,
                    // only when mounted in its own dialog route.
                    if (!embedded &&
                        navigator != null &&
                        (route?.isCurrent ?? false) &&
                        navigator.canPop()) {
                      navigator.pop();
                    }
                    try {
                      await controller.loadSubtitle(path);
                    } catch (_) {
                      if (!toastContext.mounted) return;
                      AppToast.show(
                        toastContext,
                        'Mpvson could not load that subtitle file.',
                        tone: AppToastTone.danger,
                      );
                    }
                  },
                ),
              ],
            ),
            _StreamingSettingsCard(
              appPreferences: appPreferences,
              checkYtDlpStatus: checkYtDlpStatus,
              pickYtDlpExecutable: pickYtDlpExecutable,
              onOpenAppFolder: onOpenAppFolder,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setRepeat(String target) => controller.setRepeatMode(target);
}

class VideoAudioSettingsSection extends StatefulWidget {
  const VideoAudioSettingsSection({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<VideoAudioSettingsSection> createState() =>
      _VideoAudioSettingsSectionState();
}

class _VideoAudioSettingsSectionState extends State<VideoAudioSettingsSection> {
  late PlaybackSettings _draft = widget.controller.playbackSettings;

  /// The last value this section pushed to the controller, so an echo of our
  /// own commit is not mistaken for an external edit.
  PlaybackSettings? _lastSent;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant VideoAudioSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
    _adoptControllerSettings();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  /// Keeps the draft in step with edits made elsewhere (floating panel,
  /// hotkeys, another settings surface).
  void _handleControllerChanged() {
    if (!mounted) return;
    _adoptControllerSettings();
  }

  void _adoptControllerSettings() {
    final current = widget.controller.playbackSettings;
    if (current == _lastSent || current == _draft) return;
    setState(() {
      _draft = current;
      _lastSent = current;
    });
  }

  void _changeDraft(PlaybackSettings value) {
    setState(() => _draft = value.normalized());
  }

  void _commit(PlaybackSettings value) {
    final normalized = value.normalized();
    setState(() {
      _draft = normalized;
      _lastSent = normalized;
    });
    unawaited(widget.controller.setPlaybackSettings(normalized));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsCardGroup(
            title: 'Rendering engine',
            children: [
              DropdownSettingTile<PlaybackQualityPreset>(
                icon: Icons.high_quality_rounded,
                label: 'Video quality profile',
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
                    _commit(_draft.copyWith(qualityPreset: preset));
                  }
                },
              ),
              SettingsSwitchTile(
                icon: Icons.memory_rounded,
                title: 'Prefer hardware decoding',
                subtitle:
                    'Offloads video decoding to the dedicated GPU when compatible codecs are available.',
                value: _draft.preferHardwareDecoding,
                onChanged: (val) =>
                    _commit(_draft.copyWith(preferHardwareDecoding: val)),
              ),
              SettingsSwitchTile(
                icon: Icons.speed_rounded,
                title: 'RAM preservation',
                subtitle:
                    'Limits network streaming buffer sizes to reduce memory footprint.',
                value: _draft.ramPreservation,
                onChanged: (val) =>
                    _commit(_draft.copyWith(ramPreservation: val)),
              ),
            ],
          ),
          SettingsCardGroup(
            title: 'Picture calibration',
            children: [
              ModernSliderTile(
                key: const ValueKey('playback-brightness'),
                label: 'Brightness',
                value: _draft.brightness,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: formatColorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(brightness: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(brightness: val)),
              ),
              ModernSliderTile(
                key: const ValueKey('playback-contrast'),
                label: 'Contrast',
                value: _draft.contrast,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: formatColorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(contrast: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(contrast: val)),
              ),
              ModernSliderTile(
                key: const ValueKey('playback-saturation'),
                label: 'Saturation',
                value: _draft.saturation,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: formatColorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(saturation: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(saturation: val)),
              ),
              ModernSliderTile(
                key: const ValueKey('playback-gamma'),
                label: 'Gamma',
                value: _draft.gamma,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: formatColorValue,
                onChanged: (val) => _changeDraft(_draft.copyWith(gamma: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(gamma: val)),
              ),
            ],
          ),
          SettingsCardGroup(
            title: 'Timing offsets',
            children: [
              ModernSliderTile(
                key: const ValueKey('playback-audio-delay'),
                label: 'Audio delay',
                value: _draft.audioDelaySeconds.clamp(-10, 10),
                min: -10,
                max: 10,
                divisions: 200,
                formatValue: formatSecondsValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(audioDelaySeconds: val)),
                onChangeEnd: (val) =>
                    _commit(_draft.copyWith(audioDelaySeconds: val)),
              ),
              ModernSliderTile(
                key: const ValueKey('playback-subtitle-delay'),
                label: 'Subtitle delay',
                value: _draft.subtitleDelaySeconds.clamp(-10, 10),
                min: -10,
                max: 10,
                divisions: 200,
                formatValue: formatSecondsValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(subtitleDelaySeconds: val)),
                onChangeEnd: (val) =>
                    _commit(_draft.copyWith(subtitleDelaySeconds: val)),
              ),
            ],
          ),
          if (widget.controller.playbackSettingsError case final error?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Some settings could not be applied by mpv: $error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('reset-playback-settings'),
              onPressed: () => _commit(PlaybackSettings.defaults),
              icon: const Icon(Icons.restart_alt_rounded, size: 17),
              label: const Text('Reset picture & timing'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingSettingsCard extends StatefulWidget {
  const _StreamingSettingsCard({
    this.appPreferences,
    this.checkYtDlpStatus,
    this.pickYtDlpExecutable,
    this.onOpenAppFolder,
  });

  final AppPreferencesRepository? appPreferences;
  final YtDlpStatusChecker? checkYtDlpStatus;
  final YtDlpExecutablePicker? pickYtDlpExecutable;
  final VoidCallback? onOpenAppFolder;

  @override
  State<_StreamingSettingsCard> createState() => _StreamingSettingsCardState();
}

class _StreamingSettingsCardState extends State<_StreamingSettingsCard> {
  YtDlpStatus? _status;
  bool _checking = false;
  int _probeGeneration = 0;

  String? get _customPath => widget.appPreferences?.preferences.ytDlpPath;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void didUpdateWidget(covariant _StreamingSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appPreferences != widget.appPreferences) {
      unawaited(_probe());
    }
  }

  Future<void> _probe({String? customPathOverride}) async {
    final generation = ++_probeGeneration;
    final path = customPathOverride ?? _customPath;
    setState(() => _checking = true);
    YtDlpStatus result;
    try {
      if (widget.checkYtDlpStatus != null) {
        result = await widget.checkYtDlpStatus!(path);
      } else {
        final resolved = YtDlpResolver.resolveDefaultExecutablePath(
          customPath: path,
        );
        result = await YtDlpResolver(
          executablePath: resolved,
        ).checkAvailability();
      }
    } catch (error) {
      result = YtDlpStatus(
        availability: YtDlpAvailability.failed,
        executablePath: path,
        message: 'Could not check yt-dlp: $error',
      );
    }
    if (!mounted || generation != _probeGeneration) return;
    setState(() {
      _status = result;
      _checking = false;
    });
  }

  Future<void> _chooseExecutable() async {
    final prefs = widget.appPreferences;
    String? picked;
    try {
      if (widget.pickYtDlpExecutable != null) {
        picked = await widget.pickYtDlpExecutable!();
      } else {
        final typeGroup = XTypeGroup(
          label: 'yt-dlp executable',
          extensions: Platform.isWindows ? const ['exe'] : const <String>[],
        );
        final file = await openFile(
          acceptedTypeGroups: Platform.isWindows ? [typeGroup] : const [],
        );
        picked = file?.path;
      }
    } catch (_) {
      if (mounted) {
        AppToast.show(
          context,
          'The file picker could not be opened.',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    if (picked == null || picked.trim().isEmpty) return;
    final trimmed = picked.trim();
    if (prefs != null) {
      await prefs.setYtDlpPath(trimmed);
    }
    if (!mounted) return;
    await _probe(customPathOverride: trimmed);
  }

  Future<void> _resetExecutable() async {
    final prefs = widget.appPreferences;
    if (prefs != null) {
      await prefs.setYtDlpPath(null);
    }
    if (!mounted) return;
    await _probe(customPathOverride: '');
  }

  Future<void> _openAppFolder() async {
    if (widget.onOpenAppFolder != null) {
      widget.onOpenAppFolder!();
      return;
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final ok = await showInFolder(exeDir);
    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open the application folder.',
        tone: AppToastTone.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.appPreferences;
    if (prefs == null) {
      return _buildCard(context, null);
    }
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => _buildCard(context, prefs.preferences),
    );
  }

  Widget _buildCard(BuildContext context, DesktopPreferences? desktopPrefs) {
    final palette = context.palette;
    final customPath = desktopPrefs?.ytDlpPath;
    final status = _status;

    final (String badgeText, Color badgeColor) = switch (status?.availability) {
      _ when _checking => ('Checking…', palette.mutedText),
      YtDlpAvailability.available => (
        status?.version != null && status!.version!.isNotEmpty
            ? 'Detected (${status.version})'
            : 'Detected',
        AppTheme.success,
      ),
      YtDlpAvailability.outdated => (
        status?.version != null && status!.version!.isNotEmpty
            ? 'Outdated (${status.version})'
            : 'Outdated',
        AppTheme.warning,
      ),
      YtDlpAvailability.missing => ('Missing', palette.danger),
      YtDlpAvailability.failed => ('Unavailable', palette.danger),
      null => ('Not checked', palette.mutedText),
    };

    final resolvedLabel =
        customPath ??
        status?.executablePath ??
        YtDlpResolver.defaultExecutablePath;

    return SettingsCardGroup(
      title: 'Streaming & yt-dlp',
      description:
          'Configure link resolution and default stream quality for web videos.',
      children: [
        if (desktopPrefs != null && widget.appPreferences != null)
          DropdownSettingTile<PreferredStreamQuality>(
            key: const ValueKey('preferred-stream-quality'),
            icon: Icons.high_quality_rounded,
            label: 'Default stream quality',
            value: desktopPrefs.preferredStreamQuality,
            items: PreferredStreamQuality.values
                .map(
                  (q) => DropdownMenuItem<PreferredStreamQuality>(
                    value: q,
                    child: Text(q.label),
                  ),
                )
                .toList(),
            onChanged: (q) {
              if (q != null) {
                unawaited(widget.appPreferences!.setPreferredStreamQuality(q));
              }
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 18, color: palette.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'yt-dlp resolver',
                      style: palette.rowPrimary.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Container(
                    key: const ValueKey('yt-dlp-status-badge'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: badgeColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      badgeText,
                      style: palette.metadata.copyWith(
                        color: badgeColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey('yt-dlp-refresh'),
                    tooltip: 'Re-check yt-dlp',
                    onPressed: _checking ? null : () => unawaited(_probe()),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Text(
                  resolvedLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: palette.rowSecondary,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Wrap(
                  spacing: AppSpace.xs,
                  runSpacing: AppSpace.xs,
                  children: [
                    if (widget.appPreferences != null ||
                        widget.pickYtDlpExecutable != null)
                      OutlinedButton.icon(
                        key: const ValueKey('yt-dlp-choose'),
                        onPressed: () => unawaited(_chooseExecutable()),
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: Text(
                          Platform.isWindows
                              ? 'Choose yt-dlp.exe…'
                              : 'Choose yt-dlp…',
                        ),
                      ),
                    if (customPath != null && customPath.isNotEmpty)
                      TextButton.icon(
                        key: const ValueKey('yt-dlp-reset'),
                        onPressed: () => unawaited(_resetExecutable()),
                        icon: const Icon(Icons.restore_rounded, size: 16),
                        label: const Text('Reset'),
                      ),
                    TextButton.icon(
                      key: const ValueKey('yt-dlp-open-folder'),
                      onPressed: () => unawaited(_openAppFolder()),
                      icon: const Icon(Icons.launch_rounded, size: 16),
                      label: const Text('Open app folder'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
