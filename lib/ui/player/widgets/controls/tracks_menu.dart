import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../ui/core/app_theme.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';

/// Quick audio and subtitle track switcher in the bottom playback control strip.
class TracksMenu extends StatelessWidget {
  const TracksMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
    this.onLoadSubtitle,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;
  final VoidCallback? onLoadSubtitle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sizing = PlayerControlStyle.of(context);
        final subtitleTracks = _realSubtitleTracks(controller.subtitleTracks);
        final audioTracks = _realAudioTracks(controller.audioTracks);
        final currentSub = controller.currentSubtitleTrack;
        final currentAudio = controller.currentAudioTrack;
        final subtitleActive =
            (currentSub.id != 'no' && currentSub.id != 'auto') ||
            (currentSub.id == 'auto' && subtitleTracks.isNotEmpty);
        final accent = Theme.of(context).colorScheme.primary;
        final style = sizing.buttonStyle;

        return Semantics(
          label: 'Audio and subtitles',
          button: true,
          child: PopupMenuButton<_TracksMenuSelection>(
            key: const ValueKey('tracks-menu-button'),
            tooltip: 'Audio & subtitles',
            padding: EdgeInsets.zero,
            position: PopupMenuPosition.over,
            style: subtitleActive
                ? style.copyWith(
                    foregroundColor: WidgetStatePropertyAll(accent),
                  )
                : style,
            iconSize: sizing.iconSize,
            icon: Icon(
              subtitleActive
                  ? Icons.closed_caption_rounded
                  : Icons.closed_caption_outlined,
            ),
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
            onOpened: () => onMenuVisibilityChanged?.call(true),
            onCanceled: () => onMenuVisibilityChanged?.call(false),
            onSelected: (selection) {
              onMenuVisibilityChanged?.call(false);
              switch (selection) {
                case _SubtitleTrackChoice(:final track):
                  unawaited(controller.setSubtitleTrack(track));
                case _AudioTrackChoice(:final track):
                  unawaited(controller.setAudioTrack(track));
                case _LoadExternalSubtitle():
                  onLoadSubtitle?.call();
              }
            },
            itemBuilder: (context) => _buildItems(
              context,
              subtitleTracks: subtitleTracks,
              audioTracks: audioTracks,
              currentSub: currentSub,
              currentAudio: currentAudio,
              accent: accent,
            ),
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<_TracksMenuSelection>> _buildItems(
    BuildContext context, {
    required List<SubtitleTrack> subtitleTracks,
    required List<AudioTrack> audioTracks,
    required SubtitleTrack currentSub,
    required AudioTrack currentAudio,
    required Color accent,
  }) {
    final palette = context.palette;
    final items = <PopupMenuEntry<_TracksMenuSelection>>[
      PopupMenuItem<_TracksMenuSelection>(
        enabled: false,
        height: 28,
        child: Text(
          'Subtitles',
          style: palette.metadata.copyWith(
            fontWeight: FontWeight.w600,
            color: palette.mutedText,
          ),
        ),
      ),
      PopupMenuItem<_TracksMenuSelection>(
        value: _SubtitleTrackChoice(SubtitleTrack.no()),
        child: _TrackMenuRow(
          label: 'Off',
          selected: currentSub.id == 'no',
          accent: accent,
        ),
      ),
      for (final track in subtitleTracks)
        PopupMenuItem<_TracksMenuSelection>(
          value: _SubtitleTrackChoice(track),
          child: _TrackMenuRow(
            label: _trackLabel(track.id, track.title, track.language),
            selected: currentSub.id == track.id,
            accent: accent,
          ),
        ),
      if (onLoadSubtitle != null)
        const PopupMenuItem<_TracksMenuSelection>(
          value: _LoadExternalSubtitle(),
          child: Row(
            children: [
              Icon(Icons.note_add_outlined, size: 17),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Load external subtitle…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ];

    if (audioTracks.isNotEmpty) {
      items.add(const PopupMenuDivider());
      items.add(
        PopupMenuItem<_TracksMenuSelection>(
          enabled: false,
          height: 28,
          child: Text(
            'Audio track',
            style: palette.metadata.copyWith(
              fontWeight: FontWeight.w600,
              color: palette.mutedText,
            ),
          ),
        ),
      );
      for (final track in audioTracks) {
        items.add(
          PopupMenuItem<_TracksMenuSelection>(
            value: _AudioTrackChoice(track),
            child: _TrackMenuRow(
              label: _trackLabel(track.id, track.title, track.language),
              selected: currentAudio.id == track.id,
              accent: accent,
            ),
          ),
        );
      }
    }

    return items;
  }

  static List<SubtitleTrack> _realSubtitleTracks(List<SubtitleTrack> tracks) =>
      [
        for (final t in tracks)
          if (t.id != 'auto' && t.id != 'no') t,
      ];

  static List<AudioTrack> _realAudioTracks(List<AudioTrack> tracks) => [
    for (final t in tracks)
      if (t.id != 'auto' && t.id != 'no') t,
  ];

  static String _trackLabel(String id, String? rawTitle, String? rawLanguage) {
    final title = (rawTitle ?? '').trim();
    final language = (rawLanguage ?? '').trim();
    if (title.isEmpty && language.isEmpty) return 'Track $id';
    if (title.isEmpty) return language;
    if (language.isEmpty) return title;
    return '$title ($language)';
  }
}

class _TrackMenuRow extends StatelessWidget {
  const _TrackMenuRow({
    required this.label,
    required this.selected,
    required this.accent,
  });

  final String label;
  final bool selected;
  final Color accent;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_rounded, size: 18, color: accent),
        ],
      ],
    ),
  );
}

sealed class _TracksMenuSelection {
  const _TracksMenuSelection();
}

final class _SubtitleTrackChoice extends _TracksMenuSelection {
  const _SubtitleTrackChoice(this.track);
  final SubtitleTrack track;
}

final class _AudioTrackChoice extends _TracksMenuSelection {
  const _AudioTrackChoice(this.track);
  final AudioTrack track;
}

final class _LoadExternalSubtitle extends _TracksMenuSelection {
  const _LoadExternalSubtitle();
}
