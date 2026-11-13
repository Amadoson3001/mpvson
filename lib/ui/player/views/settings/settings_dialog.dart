import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/repositories/media_library_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import '../../../../data/services/engine_update_service.dart';
import '../../../../data/services/update_service.dart';
import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../../core/components/app_dialog.dart';
import '../../player_controller.dart';
import 'settings_animation_section.dart';
import 'settings_appearance_section.dart';
import 'settings_desktop_section.dart';
import 'settings_empty_fallbacks.dart';
import 'settings_library_section.dart';
import 'settings_playback_section.dart';
import 'settings_player_controls_section.dart';
import 'settings_shortcuts_section.dart';
import 'settings_update_section.dart';

export 'settings_library_section.dart' show LibraryFoldersView;

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
    SettingsSection.appearance => 'Theme, accent, and control size.',
    SettingsSection.animation => 'Motion for panels, sheets, and video.',
    SettingsSection.playerControls => 'Bar layout, blur, and seek bar.',
    SettingsSection.playback => 'Repeat, speed, and media tracks.',
    SettingsSection.videoAudio => 'Quality, color, and timing.',
    SettingsSection.desktopIntegration => 'File opening and power.',
    SettingsSection.mediaLibrary => 'Indexed folders and scan status.',
    SettingsSection.shortcuts => 'Keyboard and mouse bindings.',
    SettingsSection.about => 'Version, engine, and updates.',
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
    if (widget.useRail) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 200,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.palette.background,
                border: Border(
                  right: BorderSide(color: context.palette.border, width: 1),
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
        Divider(height: 1, color: context.palette.border),
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

    return ColoredBox(
      color: context.palette.background,
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
    final palette = context.palette;
    final labelStyle = palette.rowPrimary.copyWith(
      color: selected ? palette.text : palette.muted,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );

    return Semantics(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadii.control),
          hoverColor: palette.hover.withValues(alpha: 0.55),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 12 : 14,
              vertical: wide ? 8 : 7,
            ),
            decoration: BoxDecoration(
              color: selected ? palette.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Row(
              mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(
                  section.icon,
                  size: 18,
                  color: selected ? palette.text : palette.muted,
                ),
                const SizedBox(width: 10),
                if (wide)
                  Expanded(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle,
                    ),
                  )
                else
                  Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
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
    final palette = context.palette;
    return ColoredBox(
      color: palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 22, 28, 4),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.label,
                      style: palette.albumTitle.copyWith(fontSize: 20),
                    ),
                    const SizedBox(height: 4),
                    Text(section.description, style: palette.rowSecondary),
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

/// A modern, desktop-first settings experience featuring fluid navigation,
/// dynamic accent & theme personalization, and responsive controls.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.pickSubtitle,
    this.appPreferences,
    this.desktopIntegration,
    this.libraryRepository,
    this.pickDirectory,
    this.showMediaLibrary = false,
    this.embedded = false,
    this.onClose,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final Future<String?> Function() pickSubtitle;
  final AppPreferencesRepository? appPreferences;
  final DesktopIntegrationService? desktopIntegration;
  final MediaLibraryRepository? libraryRepository;
  final Future<String?> Function()? pickDirectory;
  final bool showMediaLibrary;
  final bool embedded;
  final VoidCallback? onClose;

  static Future<void> show({
    required BuildContext context,
    required PlayerController controller,
    required UpdateService updates,
    required EngineUpdateService engineUpdates,
    required Future<String?> Function() pickSubtitle,
    AppPreferencesRepository? appPreferences,
    DesktopIntegrationService? desktopIntegration,
    MediaLibraryRepository? libraryRepository,
    Future<String?> Function()? pickDirectory,
    bool showMediaLibrary = false,
    VoidCallback? onClose,
  }) => AppDialog.show<void>(
    context: context,
    builder: (_) => SettingsDialog(
      controller: controller,
      updates: updates,
      engineUpdates: engineUpdates,
      pickSubtitle: pickSubtitle,
      appPreferences: appPreferences,
      desktopIntegration: desktopIntegration,
      libraryRepository: libraryRepository,
      pickDirectory: pickDirectory,
      showMediaLibrary: showMediaLibrary,
      onClose: onClose,
    ),
  );

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  AppPreferencesRepository? _fallbackPreferences;
  DesktopIntegrationService? _fallbackDesktopIntegration;
  MediaLibraryRepository? _fallbackLibraryRepository;

  AppPreferencesRepository get _preferences =>
      widget.appPreferences ??
      (_fallbackPreferences ??= AppPreferencesRepository());

  DesktopIntegrationService get _desktopIntegration =>
      widget.desktopIntegration ??
      (_fallbackDesktopIntegration ??= EmptyDesktopIntegrationService());

  MediaLibraryRepository get _libraryRepository =>
      widget.libraryRepository ??
      (_fallbackLibraryRepository ??= EmptyMediaLibraryRepository());

  @override
  void initState() {
    super.initState();
    if (widget.appPreferences == null) {
      unawaited(_preferences.load());
    }
  }

  @override
  void dispose() {
    _fallbackPreferences?.dispose();
    _fallbackDesktopIntegration?.dispose();
    _fallbackLibraryRepository?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return _buildBody(context);
    }

    return AppDialog(
      maxWidth: 840,
      maxHeight: 720,
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final screenHeight = MediaQuery.sizeOf(context).height;
      final availableWidth = constraints.maxWidth;
      final availableHeight = constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : screenHeight - 48;
      final dialogWidth = widget.embedded
          ? availableWidth
          : availableWidth.isFinite
          ? (availableWidth < 840 ? availableWidth : 840.0)
          : 840.0;
      final dialogHeight = widget.embedded
          ? availableHeight
          : (availableHeight < 720 ? availableHeight : 720.0);
      final useRail = availableWidth >= 700;
      final compactViewport = dialogHeight <= 540;

      return ColoredBox(
        color: context.palette.background,
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Column(
            children: [
              if (!widget.embedded) ...[
                SizedBox(
                  height: AppLayout.settingsHeaderHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Settings',
                        style: context.palette.sectionTitle.copyWith(
                          fontSize: AppType.body,
                        ),
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, color: context.palette.border),
              ],
              Expanded(
                child: SettingsDialogView(
                  controller: widget.controller,
                  updates: widget.updates,
                  engineUpdates: widget.engineUpdates,
                  pickSubtitle: widget.pickSubtitle,
                  preferences: _preferences,
                  desktopIntegration: _desktopIntegration,
                  libraryRepository: _libraryRepository,
                  pickDirectory: widget.pickDirectory,
                  showMediaLibrary: widget.showMediaLibrary,
                  embedded: widget.embedded,
                  compactViewport: compactViewport,
                  useRail: useRail,
                ),
              ),
              if (!widget.embedded) ...[
                Divider(height: 1, color: context.palette.border),
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed:
                            widget.onClose ?? () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
