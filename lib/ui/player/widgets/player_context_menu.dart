import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../player_controller.dart';

/// A native-feeling context menu for the video surface.
///
/// The wrapper only handles secondary clicks. The child remains responsible
/// for its primary gestures, pointer wheel, and double-click behavior.
class PlayerContextMenu extends StatelessWidget {
  const PlayerContextMenu({
    super.key,
    required this.playerController,
    required this.menuController,
    required this.child,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onToggleQueue,
    required this.onSettings,
    required this.onLoadSubtitle,
    required this.onToggleMute,
    required this.onAdjustVolume,
    required this.onMenuVisibilityChanged,
    this.onFullscreen,
    this.isFullscreen = false,
    this.queueOpen = false,
  });

  final PlayerController playerController;
  final MenuController menuController;
  final Widget child;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final VoidCallback onToggleQueue;
  final VoidCallback onSettings;
  final VoidCallback onLoadSubtitle;
  final VoidCallback onToggleMute;

  /// Receives a signed adjustment in volume percentage points.
  final ValueChanged<double> onAdjustVolume;
  final ValueChanged<bool> onMenuVisibilityChanged;
  final VoidCallback? onFullscreen;
  final bool isFullscreen;
  final bool queueOpen;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playerController,
    builder: (context, _) => Stack(
      fit: StackFit.passthrough,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapDown: (details) {
            menuController.open(position: details.localPosition);
          },
          onTapDown: (_) {
            if (menuController.isOpen) menuController.close();
          },
          child: child,
        ),
        Positioned(
          left: 0,
          top: 0,
          child: MenuAnchor(
            controller: menuController,
            consumeOutsideTap: false,
            animated: !AppMotion.reduce(context),
            style: _popupMenuStyle,
            onOpen: () => onMenuVisibilityChanged(true),
            onClose: () => onMenuVisibilityChanged(false),
            menuChildren: _menuChildren(context),
            builder: (context, controller, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    ),
  );

  List<Widget> _menuChildren(BuildContext context) {
    final canPlay = playerController.current != null;
    final canSeek =
        playerController.hasMedia && playerController.duration > Duration.zero;
    final hasMedia = playerController.hasMedia;
    final accent = Theme.of(context).colorScheme.primary;

    return [
      _menuAction(
        icon: playerController.isPlaying
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        animateLeadingIcon: !AppMotion.reduce(context),
        label: playerController.isPlaying ? 'Pause' : 'Play',
        trailing: 'Space',
        onPressed: canPlay
            ? () => unawaited(playerController.togglePlayPause())
            : null,
      ),
      _submenu(
        context,
        icon: Icons.fast_forward_rounded,
        label: 'Seek',
        children: [
          _menuAction(
            icon: Icons.replay_10_rounded,
            label: 'Back 10 seconds',
            onPressed: canSeek
                ? () => unawaited(
                    playerController.seekRelative(const Duration(seconds: -10)),
                  )
                : null,
          ),
          _menuAction(
            icon: Icons.forward_10_rounded,
            label: 'Forward 10 seconds',
            onPressed: canSeek
                ? () => unawaited(
                    playerController.seekRelative(const Duration(seconds: 10)),
                  )
                : null,
          ),
        ],
      ),
      _submenu(
        context,
        icon: Icons.speed_rounded,
        label: 'Playback speed',
        children: _speedOptions(accent),
      ),
      _submenu(
        context,
        icon: Icons.audiotrack_rounded,
        label: 'Audio',
        children: _audioOptions(hasMedia, accent),
      ),
      _submenu(
        context,
        icon: Icons.subtitles_rounded,
        label: 'Subtitles',
        children: _subtitleOptions(hasMedia, accent),
      ),
      _submenu(
        context,
        icon: Icons.volume_up_rounded,
        label: 'Volume',
        children: [
          _menuAction(
            icon: Icons.add_rounded,
            label: 'Increase volume',
            trailing: '+5',
            onPressed: () => onAdjustVolume(5),
          ),
          _menuAction(
            icon: Icons.remove_rounded,
            label: 'Decrease volume',
            trailing: '−5',
            onPressed: () => onAdjustVolume(-5),
          ),
          const _MenuDivider(),
          _menuAction(
            icon: playerController.volume <= 0
                ? Icons.volume_up_rounded
                : Icons.volume_off_rounded,
            label: playerController.volume <= 0 ? 'Unmute' : 'Mute',
            trailing: 'M',
            onPressed: onToggleMute,
          ),
        ],
      ),
      const _MenuDivider(),
      _submenu(
        context,
        icon: Icons.folder_open_rounded,
        label: 'Open',
        children: [
          _menuAction(
            icon: Icons.video_file_outlined,
            label: 'Files',
            trailing: 'Ctrl+O',
            onPressed: onOpenFiles,
          ),
          _menuAction(
            icon: Icons.link_rounded,
            label: 'URL',
            trailing: 'Ctrl+L',
            onPressed: onOpenUrl,
          ),
        ],
      ),
      _menuAction(
        icon: queueOpen ? Icons.view_sidebar_rounded : Icons.queue_play_next,
        label: queueOpen ? 'Hide queue' : 'Show queue',
        trailing: 'P',
        onPressed: onToggleQueue,
      ),
      if (onFullscreen != null)
        _menuAction(
          icon: isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          label: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
          trailing: 'F11',
          onPressed: onFullscreen,
        ),
      _menuAction(
        icon: Icons.settings_outlined,
        label: 'Settings',
        onPressed: onSettings,
      ),
    ];
  }

  List<Widget> _speedOptions(Color accent) => [
    for (final rate in _playbackRates)
      _menuAction(
        icon: null,
        label: _speedLabel(rate),
        checked: (playerController.rate - rate).abs() < 0.01,
        accent: accent,
        onPressed: () => unawaited(playerController.setRate(rate)),
      ),
  ];

  List<Widget> _audioOptions(bool hasMedia, Color accent) {
    if (!hasMedia) return const [];

    final tracks = _audioTrackOptions(playerController.audioTracks);
    return [
      for (final track in tracks)
        _menuAction(
          icon: null,
          label: _trackLabel(track.id, track.title, track.language),
          checked: playerController.currentAudioTrack.id == track.id,
          accent: accent,
          onPressed: () => unawaited(playerController.setAudioTrack(track)),
        ),
    ];
  }

  List<Widget> _subtitleOptions(bool hasMedia, Color accent) {
    if (!hasMedia) {
      return [
        _menuAction(
          icon: Icons.note_add_outlined,
          label: 'Load subtitle file',
          onPressed: null,
        ),
      ];
    }

    final tracks = _subtitleTrackOptions(playerController.subtitleTracks);
    return [
      for (final track in tracks)
        _menuAction(
          icon: null,
          label: _trackLabel(track.id, track.title, track.language),
          checked: playerController.currentSubtitleTrack.id == track.id,
          accent: accent,
          onPressed: () => unawaited(playerController.setSubtitleTrack(track)),
        ),
      const _MenuDivider(),
      _menuAction(
        icon: Icons.note_add_outlined,
        label: 'Load subtitle file',
        onPressed: onLoadSubtitle,
      ),
    ];
  }

  static SubmenuButton _submenu(
    BuildContext context, {
    required IconData icon,
    required String label,
    required List<Widget> children,
  }) => SubmenuButton(
    animated: !AppMotion.reduce(context),
    style: _submenuButtonStyle,
    menuStyle: _submenuPopupMenuStyle,
    leadingIcon: Icon(icon, size: 19),
    menuChildren: children,
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );

  static MenuItemButton _menuAction({
    required IconData? icon,
    required String label,
    required VoidCallback? onPressed,
    String? trailing,
    bool checked = false,
    Color? accent,
    bool animateLeadingIcon = false,
  }) => MenuItemButton(
    onPressed: onPressed,
    semanticsLabel: checked ? '$label, selected' : label,
    style: _menuItemButtonStyle,
    leadingIcon: SizedBox(
      width: 20,
      child: _leadingMenuIcon(icon, animated: animateLeadingIcon),
    ),
    trailingIcon: SizedBox(
      width: 48,
      child: Align(
        alignment: Alignment.centerRight,
        child: checked
            ? Icon(Icons.check_rounded, size: 17, color: accent)
            : Text(
                trailing ?? '',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppTheme.muted,
                  fontSize: AppType.caption,
                ),
              ),
      ),
    ),
    child: Semantics(
      checked: checked,
      selected: checked,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  static Widget? _leadingMenuIcon(IconData? icon, {required bool animated}) {
    if (icon == null) return null;
    if (!animated) return Icon(icon, size: 18);

    return AnimatedSwitcher(
      duration: AppMotion.quick,
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: Icon(icon, key: ValueKey(icon), size: 18),
    );
  }
}

const _playbackRates = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];

final _popupMenuStyle = _menuPanelStyle(AppTheme.surface);
final _submenuPopupMenuStyle = _menuPanelStyle(AppTheme.card);

MenuStyle _menuPanelStyle(Color color) => MenuStyle(
  backgroundColor: WidgetStatePropertyAll(color),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(
    AppTheme.background.withValues(alpha: 0.55),
  ),
  elevation: const WidgetStatePropertyAll(10),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 5)),
  maximumSize: const WidgetStatePropertyAll(Size(320, 420)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.artwork),
      side: const BorderSide(color: AppTheme.border),
    ),
  ),
);

final _menuItemButtonStyle = MenuItemButton.styleFrom(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  foregroundColor: AppTheme.text,
  disabledForegroundColor: AppTheme.muted,
  minimumSize: const Size(260, 40),
  padding: const EdgeInsets.symmetric(horizontal: 10),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadii.control),
  ),
  overlayColor: AppTheme.hover,
);

final _submenuButtonStyle = SubmenuButton.styleFrom(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  foregroundColor: AppTheme.text,
  disabledForegroundColor: AppTheme.muted,
  minimumSize: const Size(260, 40),
  padding: const EdgeInsets.symmetric(horizontal: 10),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadii.control),
  ),
  overlayColor: AppTheme.hover,
);

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 9,
    child: Divider(height: 1, indent: 12, endIndent: 12),
  );
}

List<AudioTrack> _audioTrackOptions(List<AudioTrack> tracks) => [
  const AudioTrack('auto', null, null),
  const AudioTrack('no', null, null),
  for (final track in tracks)
    if (track.id != 'auto' && track.id != 'no') track,
];

List<SubtitleTrack> _subtitleTrackOptions(List<SubtitleTrack> tracks) => [
  const SubtitleTrack('auto', null, null),
  const SubtitleTrack('no', null, null),
  for (final track in tracks)
    if (track.id != 'auto' && track.id != 'no') track,
];

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

String _speedLabel(double rate) => rate == 1
    ? 'Normal'
    : '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';
