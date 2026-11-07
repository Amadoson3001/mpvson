import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/app_theme.dart';
import '../../../core/toast/app_toast.dart';
import '../../../../domain/models/playback_settings.dart';
import '../../player_controller.dart';
import 'settings_shared_widgets.dart';

class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({
    super.key,
    required this.controller,
    required this.pickSubtitle,
  });

  final PlayerController controller;
  final Future<String?> Function() pickSubtitle;

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
                    String? path;
                    try {
                      path = await pickSubtitle();
                    } catch (_) {
                      AppToast.show(
                        navigator?.context ?? context,
                        'The file picker could not be opened.',
                        tone: AppToastTone.danger,
                      );
                      return;
                    }
                    if (path == null || path.isEmpty) return;
                    // Close the settings sheet only after a successful pick,
                    // and only while this route is still the current one and
                    // can actually be popped.
                    if (navigator != null &&
                        (route?.isCurrent ?? false) &&
                        navigator.canPop()) {
                      navigator.pop();
                    }
                    try {
                      await controller.loadSubtitle(path);
                    } catch (_) {
                      AppToast.show(
                        navigator?.context ?? context,
                        'Mpvson could not load that subtitle file.',
                        tone: AppToastTone.danger,
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setRepeat(String target) async {
    for (var i = 0; i < 3 && controller.repeatMode != target; i++) {
      await controller.cycleRepeat();
    }
  }
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

  void _changeDraft(PlaybackSettings value) {
    setState(() => _draft = value.normalized());
  }

  void _commit(PlaybackSettings value) {
    final normalized = value.normalized();
    setState(() => _draft = normalized);
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
                value: _draft.audioDelaySeconds,
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
                value: _draft.subtitleDelaySeconds,
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
