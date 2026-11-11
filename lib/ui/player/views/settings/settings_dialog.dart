import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/repositories/media_library_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import '../../../../data/services/engine_update_service.dart';
import '../../../../data/services/update_service.dart';
import '../../../core/app_motion.dart';
import '../../player_controller.dart';
import 'settings_animation_section.dart';
import 'settings_appearance_section.dart';
import 'settings_desktop_section.dart';
import 'settings_library_section.dart';
import 'settings_playback_section.dart';
import 'settings_player_controls_section.dart';
import 'settings_shortcuts_section.dart';
import 'settings_update_section.dart';

enum SettingsSection {
  appearance,
  animation,
  playerControls,
  playback,
  videoAudio,
  shortcuts,
  desktopIntegration,
  mediaLibrary,
  about,
}

extension SettingsSectionX on SettingsSection {
  String get label => switch (this) {
    SettingsSection.appearance => 'Appearance',
    SettingsSection.animation => 'Animation',
    SettingsSection.playerControls => 'Player controls',
    SettingsSection.playback => 'Playback',
    SettingsSection.videoAudio => 'Video & audio',
    SettingsSection.desktopIntegration => 'Desktop & system',
    SettingsSection.mediaLibrary => 'Media library',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.about => 'About & engine',
  };

  String get description => switch (this) {
    SettingsSection.appearance =>
      'Customize themes, dynamic accents, and control density.',
    SettingsSection.animation =>
      'Choose how panels and the video move, with a simple off switch for older PCs.',
    SettingsSection.playerControls =>
      'Customize control bar style, glass blur, opacity, seekbar, and layout.',
    SettingsSection.playback =>
      'Manage playback behaviors, repeat, speed, and media tracks.',
    SettingsSection.videoAudio =>
      'Fine-tune video quality, color calibration, and timing delays.',
    SettingsSection.desktopIntegration =>
      'Configure file opening behavior and OS power settings.',
    SettingsSection.mediaLibrary =>
      'Manage indexed folders and monitor library status.',
    SettingsSection.shortcuts =>
      'Rebind player hotkeys and review mouse shortcuts.',
    SettingsSection.about =>
      'Inspect application version, engine build, and check for updates.',
  };

  IconData get icon => switch (this) {
    SettingsSection.appearance => Icons.palette_outlined,
    SettingsSection.animation => Icons.slow_motion_video_rounded,
    SettingsSection.playerControls => Icons.tune_rounded,
    SettingsSection.playback => Icons.play_circle_outline_rounded,
    SettingsSection.videoAudio => Icons.video_settings_rounded,
    SettingsSection.desktopIntegration => Icons.desktop_windows_rounded,
    SettingsSection.mediaLibrary => Icons.folder_copy_rounded,
    SettingsSection.shortcuts => Icons.keyboard_alt_outlined,
    SettingsSection.about => Icons.info_outline_rounded,
  };
}

class SettingsDialogView extends StatefulWidget {
  const SettingsDialogView({
    super.key,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.pickSubtitle,
    required this.preferences,
    required this.desktopIntegration,
    required this.libraryRepository,
    this.pickDirectory,
    this.showMediaLibrary = false,
    this.embedded = false,
    this.compactViewport = false,
    this.useRail = true,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final Future<String?> Function() pickSubtitle;
  final AppPreferencesRepository preferences;
  final DesktopIntegrationService desktopIntegration;
  final MediaLibraryRepository libraryRepository;
  final Future<String?> Function()? pickDirectory;
  final bool showMediaLibrary;
  final bool embedded;
  final bool compactViewport;
  final bool useRail;

  @override
  State<SettingsDialogView> createState() => _SettingsDialogViewState();
}

class _SettingsDialogViewState extends State<SettingsDialogView> {
  late SettingsSection _section = widget.showMediaLibrary
      ? SettingsSection.mediaLibrary
      : SettingsSection.appearance;

  void _selectSection(SettingsSection section) {
    if (_section == section) return;
    setState(() => _section = section);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.useRail) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 216,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.35,
                    ),
                    width: 1,
                  ),
                ),
              ),
              child: SettingsNavigation(
                key: const ValueKey('settings-navigation-rail'),
                section: _section,
                wide: true,
                showMediaLibrary: !widget.embedded,
                onSelected: _selectSection,
              ),
            ),
          ),
          Expanded(
            child: SettingsContentPane(
              section: _section,
              controller: widget.controller,
              updates: widget.updates,
              engineUpdates: widget.engineUpdates,
              pickSubtitle: widget.pickSubtitle,
              embedded: widget.embedded,
              compactViewport: widget.compactViewport,
              preferences: widget.preferences,
              desktopIntegration: widget.desktopIntegration,
              libraryRepository: widget.libraryRepository,
              pickDirectory: widget.pickDirectory,
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        SettingsNavigation(
          key: const ValueKey('settings-top-navigation'),
          section: _section,
          wide: false,
          showMediaLibrary: !widget.embedded,
          onSelected: _selectSection,
        ),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
        Expanded(
          child: SettingsContentPane(
            section: _section,
            controller: widget.controller,
            updates: widget.updates,
            engineUpdates: widget.engineUpdates,
            pickSubtitle: widget.pickSubtitle,
            embedded: widget.embedded,
            compactViewport: widget.compactViewport,
            preferences: widget.preferences,
            desktopIntegration: widget.desktopIntegration,
            libraryRepository: widget.libraryRepository,
            pickDirectory: widget.pickDirectory,
          ),
        ),
      ],
    );
  }
}

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    super.key,
    required this.section,
    required this.wide,
    required this.onSelected,
    this.showMediaLibrary = true,
  });

  final SettingsSection section;
  final bool wide;
  final bool showMediaLibrary;
  final ValueChanged<SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = SettingsSection.values
        .where(
          (item) => showMediaLibrary || item != SettingsSection.mediaLibrary,
        )
        .map(
          (item) => SettingsNavigationItem(
            section: item,
            selected: item == section,
            wide: wide,
            onPressed: () => onSelected(item),
          ),
        )
        .toList();

    if (wide) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[item, const SizedBox(height: 2)],
          ],
        ),
      );
    }

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: items),
      ),
    );
  }
}

class SettingsNavigationItem extends StatelessWidget {
  const SettingsNavigationItem({
    super.key,
    required this.section,
    required this.selected,
    required this.wide,
    required this.onPressed,
  });

  final SettingsSection section;
  final bool selected;
  final bool wide;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Semantics(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          hoverColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 12 : 14,
              vertical: wide ? 9 : 8,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(
                  section.icon,
                  size: 18,
                  color: selected
                      ? accent
                      : theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.85,
                        ),
                ),
                const SizedBox(width: 12),
                if (wide)
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected
                            ? (theme.brightness == Brightness.dark
                                  ? Colors.white
                                  : theme.colorScheme.onSurface)
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        fontSize: 13.5,
                      ),
                    ),
                  )
                else
                  Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected
                          ? (theme.brightness == Brightness.dark
                                ? Colors.white
                                : theme.colorScheme.onSurface)
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      fontSize: 13.5,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsContentPane extends StatelessWidget {
  const SettingsContentPane({
    super.key,
    required this.section,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.pickSubtitle,
    required this.compactViewport,
    required this.preferences,
    required this.desktopIntegration,
    required this.libraryRepository,
    this.pickDirectory,
    this.embedded = false,
  });

  final SettingsSection section;
  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final Future<String?> Function() pickSubtitle;
  final bool compactViewport;
  final AppPreferencesRepository preferences;
  final DesktopIntegrationService desktopIntegration;
  final MediaLibraryRepository libraryRepository;
  final Future<String?> Function()? pickDirectory;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 8),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            section.label,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                              fontSize: 22,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            section.description,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.85),
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey<SettingsSection>(section),
              child: switch (section) {
                SettingsSection.appearance => AppearanceSettingsSection(
                  controller: controller,
                  compactViewport: compactViewport,
                  appPreferences: preferences,
                ),
                SettingsSection.animation => AnimationSettingsSection(
                  appPreferences: preferences,
                ),
                SettingsSection.playerControls => PlayerControlsSettingsSection(
                  appPreferences: preferences,
                  controller: controller,
                  compactViewport: compactViewport,
                ),
                SettingsSection.playback => PlaybackSettingsSection(
                  controller: controller,
                  pickSubtitle: pickSubtitle,
                  embedded: embedded,
                ),
                SettingsSection.videoAudio => VideoAudioSettingsSection(
                  controller: controller,
                ),
                SettingsSection.desktopIntegration =>
                  DesktopIntegrationSettingsSection(
                    preferences: preferences,
                    desktopIntegration: desktopIntegration,
                  ),
                SettingsSection.mediaLibrary => MediaLibrarySettingsSection(
                  libraryRepository: libraryRepository,
                  pickDirectory: pickDirectory,
                ),
                SettingsSection.shortcuts => ShortcutsSettingsSection(
                  preferences: preferences,
                ),
                SettingsSection.about => AboutSettingsSection(
                  updates: updates,
                  engineUpdates: engineUpdates,
                  engineVersion: controller.engineVersion,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}
