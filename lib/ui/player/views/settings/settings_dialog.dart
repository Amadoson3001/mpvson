import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/repositories/media_library_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import '../../../../data/services/engine_update_service.dart';
import '../../../../data/services/update_service.dart';
import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../player_controller.dart';
import 'settings_appearance_section.dart';
import 'settings_desktop_section.dart';
import 'settings_library_section.dart';
import 'settings_playback_section.dart';
import 'settings_shortcuts_section.dart';
import 'settings_update_section.dart';

enum SettingsSection {
  appearance,
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
    SettingsSection.playback => Icons.play_circle_outline_rounded,
    SettingsSection.videoAudio => Icons.tune_rounded,
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
            width: 224,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: theme.colorScheme.outlineVariant,
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
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: SettingsContentPane(
            section: _section,
            controller: widget.controller,
            updates: widget.updates,
            engineUpdates: widget.engineUpdates,
            pickSubtitle: widget.pickSubtitle,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[item, const SizedBox(height: 3)],
          ],
        ),
      );
    }

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          borderRadius: BorderRadius.circular(AppRadii.control),
          hoverColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 10 : 12,
              vertical: wide ? 8 : 6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: wide && selected
                  ? Border(left: BorderSide(color: accent, width: 3))
                  : null,
            ),
            child: Row(
              mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: selected
                        ? accent.withValues(alpha: 0.20)
                        : theme.colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.4,
                          ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    section.icon,
                    size: 16,
                    color: selected
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                if (wide)
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? accent : theme.colorScheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  )
                else
                  Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected ? accent : theme.colorScheme.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(40, 14, 40, 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
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
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            section.description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
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
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.standard),
              reverseDuration: AppMotion.duration(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              layoutBuilder: (currentChild, previousChildren) => Stack(
                fit: StackFit.expand,
                children: [...previousChildren, ?currentChild],
              ),
              transitionBuilder: (child, animation) {
                if (AppMotion.reduce(context)) return child;
                return FadeTransition(opacity: animation, child: child);
              },
              child: KeyedSubtree(
                key: ValueKey<SettingsSection>(section),
                child: switch (section) {
                  SettingsSection.appearance => AppearanceSettingsSection(
                    controller: controller,
                    compactViewport: compactViewport,
                    appPreferences: preferences,
                  ),
                  SettingsSection.playback => PlaybackSettingsSection(
                    controller: controller,
                    pickSubtitle: pickSubtitle,
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
          ),
        ],
      ),
    );
  }
}
