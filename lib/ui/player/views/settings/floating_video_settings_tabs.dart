import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../domain/models/playback_settings.dart';
import '../../../core/app_theme.dart';
import '../../../core/toast/app_toast.dart';
import '../../player_controller.dart';
import 'settings_shared_widgets.dart';

class FloatingAudioSubsTab extends StatelessWidget {
  const FloatingAudioSubsTab({
    super.key,
    required this.controller,
    required this.draft,
    required this.pickSubtitle,
    required this.onChangeDraft,
    required this.onCommit,
  });

  final PlayerController controller;
  final PlaybackSettings draft;
  final Future<String?> Function() pickSubtitle;
  final ValueChanged<PlaybackSettings> onChangeDraft;
  final ValueChanged<PlaybackSettings> onCommit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCardGroup(
          title: 'Subtitles',
          children: [
            TrackSettingTile<SubtitleTrack>(
              icon: Icons.subtitles_rounded,
              label: 'Subtitle track',
              tracks: controller.subtitleTracks,
              selected: controller.currentSubtitleTrack,
              trackLabel: (t) => formatTrackLabel(t.id, t.title, t.language),
              onSelected: (t) => unawaited(controller.setSubtitleTrack(t)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                ),
                icon: const Icon(Icons.file_open_rounded, size: 16),
                label: const Text('Load external subtitle...'),
                onPressed: () async {
                  String? path;
                  try {
                    path = await pickSubtitle();
                  } catch (_) {
                    if (context.mounted) {
                      AppToast.show(
                        context,
                        'The file picker could not be opened.',
                        tone: AppToastTone.danger,
                      );
                    }
                    return;
                  }
                  if (path == null || path.isEmpty) return;
                  try {
                    await controller.loadSubtitle(path);
                  } catch (_) {
                    if (context.mounted) {
                      AppToast.show(
                        context,
                        'Mpvson could not load that subtitle file.',
                        tone: AppToastTone.danger,
                      );
                    }
                  }
                },
              ),
            ),
            ModernSliderTile(
              key: const ValueKey('video-subtitle-delay'),
              label: 'Subtitle sync offset',
              value: draft.subtitleDelaySeconds,
              min: -5,
              max: 5,
              divisions: 100,
              formatValue: formatSecondsValue,
              onChanged: (val) =>
                  onChangeDraft(draft.copyWith(subtitleDelaySeconds: val)),
              onChangeEnd: (val) =>
                  onCommit(draft.copyWith(subtitleDelaySeconds: val)),
            ),
          ],
        ),
        SettingsCardGroup(
          title: 'Audio',
          children: [
            TrackSettingTile<AudioTrack>(
              icon: Icons.audiotrack_rounded,
              label: 'Audio track',
              tracks: controller.audioTracks,
              selected: controller.currentAudioTrack,
              trackLabel: (t) => formatTrackLabel(t.id, t.title, t.language),
              onSelected: (t) => unawaited(controller.setAudioTrack(t)),
            ),
            ModernSliderTile(
              key: const ValueKey('video-audio-delay'),
              label: 'Audio sync offset',
              value: draft.audioDelaySeconds,
              min: -5,
              max: 5,
              divisions: 100,
              formatValue: formatSecondsValue,
              onChanged: (val) =>
                  onChangeDraft(draft.copyWith(audioDelaySeconds: val)),
              onChangeEnd: (val) =>
                  onCommit(draft.copyWith(audioDelaySeconds: val)),
            ),
          ],
        ),
      ],
    );
  }
}

class FloatingPictureTab extends StatelessWidget {
  const FloatingPictureTab({
    super.key,
    required this.draft,
    required this.onChangeDraft,
    required this.onCommit,
  });

  final PlaybackSettings draft;
  final ValueChanged<PlaybackSettings> onChangeDraft;
  final ValueChanged<PlaybackSettings> onCommit;

  @override
  Widget build(BuildContext context) {
    final hasColorOffset =
        draft.brightness != 0 ||
        draft.contrast != 0 ||
        draft.saturation != 0 ||
        draft.gamma != 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCardGroup(
          title: 'Acceleration & profile',
          children: [
            SettingsSwitchTile(
              icon: Icons.memory_rounded,
              title: 'Hardware decoding',
              subtitle: 'Offloads video decoding to dedicated GPU.',
              value: draft.preferHardwareDecoding,
              onChanged: (val) =>
                  onCommit(draft.copyWith(preferHardwareDecoding: val)),
            ),
            DropdownSettingTile<PlaybackQualityPreset>(
              icon: Icons.high_quality_rounded,
              label: 'Quality profile',
              value: draft.qualityPreset,
              items: PlaybackQualityPreset.values
                  .map((p) => DropdownMenuItem(value: p, child: Text(p.label)))
                  .toList(),
              onChanged: (p) {
                if (p != null) onCommit(draft.copyWith(qualityPreset: p));
              },
            ),
          ],
        ),
        SettingsCardGroup(
          title: 'Color calibration',
          trailing: hasColorOffset
              ? TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => onCommit(
                    draft.copyWith(
                      brightness: 0,
                      contrast: 0,
                      saturation: 0,
                      gamma: 0,
                    ),
                  ),
                  child: const Text('Reset', style: TextStyle(fontSize: 12)),
                )
              : null,
          children: [
            ModernSliderTile(
              label: 'Brightness',
              value: draft.brightness,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: formatColorValue,
              onChanged: (val) =>
                  onChangeDraft(draft.copyWith(brightness: val)),
              onChangeEnd: (val) => onCommit(draft.copyWith(brightness: val)),
            ),
            ModernSliderTile(
              label: 'Contrast',
              value: draft.contrast,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: formatColorValue,
              onChanged: (val) => onChangeDraft(draft.copyWith(contrast: val)),
              onChangeEnd: (val) => onCommit(draft.copyWith(contrast: val)),
            ),
            ModernSliderTile(
              label: 'Saturation',
              value: draft.saturation,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: formatColorValue,
              onChanged: (val) =>
                  onChangeDraft(draft.copyWith(saturation: val)),
              onChangeEnd: (val) => onCommit(draft.copyWith(saturation: val)),
            ),
            ModernSliderTile(
              label: 'Gamma',
              value: draft.gamma,
              min: -100,
              max: 100,
              divisions: 200,
              formatValue: formatColorValue,
              onChanged: (val) => onChangeDraft(draft.copyWith(gamma: val)),
              onChangeEnd: (val) => onCommit(draft.copyWith(gamma: val)),
            ),
          ],
        ),
      ],
    );
  }
}

class FloatingPlaybackTab extends StatelessWidget {
  const FloatingPlaybackTab({
    super.key,
    required this.controller,
    required this.draft,
    required this.accent,
    required this.onCommit,
  });

  final PlayerController controller;
  final PlaybackSettings draft;
  final Color accent;
  final ValueChanged<PlaybackSettings> onCommit;

  Future<void> _setRepeat(String target) async {
    for (var i = 0; i < 3 && controller.repeatMode != target; i++) {
      await controller.cycleRepeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCardGroup(
          title: 'Playback speed',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      for (final speed in speeds.take(3))
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _SpeedPill(
                              speed: speed,
                              selected: (controller.rate - speed).abs() < 0.05,
                              accent: accent,
                              onTap: () => unawaited(controller.setRate(speed)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final speed in speeds.skip(3))
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _SpeedPill(
                              speed: speed,
                              selected: (controller.rate - speed).abs() < 0.05,
                              accent: accent,
                              onTap: () => unawaited(controller.setRate(speed)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          title: 'Queue & repeat',
          children: [
            DropdownSettingTile<String>(
              icon: Icons.repeat_rounded,
              label: 'Repeat mode',
              value: controller.repeatMode,
              items: const [
                DropdownMenuItem(value: 'off', child: Text('Off')),
                DropdownMenuItem(value: 'all', child: Text('Repeat queue')),
                DropdownMenuItem(value: 'one', child: Text('Repeat current')),
              ],
              onChanged: (val) {
                if (val != null) unawaited(_setRepeat(val));
              },
            ),
            SettingsSwitchTile(
              icon: Icons.shuffle_rounded,
              title: 'Shuffle queue',
              subtitle: 'Plays queue items in random order.',
              value: controller.shuffle,
              onChanged: (_) => unawaited(controller.toggleShuffle()),
            ),
            SettingsSwitchTile(
              icon: Icons.speed_rounded,
              title: 'RAM preservation',
              subtitle: 'Limits stream buffer to reduce memory usage.',
              value: draft.ramPreservation,
              onChanged: (val) =>
                  onCommit(draft.copyWith(ramPreservation: val)),
            ),
            SettingsSwitchTile(
              icon: Icons.cloud_sync_outlined,
              title: 'Save network URLs',
              subtitle: 'Preserves stream URLs with security tokens.',
              value: controller.saveNetworkUrls,
              onChanged: (val) => unawaited(controller.setSaveNetworkUrls(val)),
            ),
          ],
        ),
      ],
    );
  }
}

class _SpeedPill extends StatelessWidget {
  const _SpeedPill({
    required this.speed,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final double speed;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = speed == 1.0 ? '1.0× (Normal)' : '$speed×';

    return Material(
      color: selected
          ? accent.withValues(alpha: 0.16)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(
              color: selected
                  ? accent
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? accent : theme.colorScheme.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
