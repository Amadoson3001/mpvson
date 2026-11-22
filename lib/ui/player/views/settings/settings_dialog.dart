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
import 'settings_shared_widgets.dart' show SettingsIconChip;
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
    SettingsSection.playback => 'Auto-play, repeat, speed, and tracks.',
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

  int _previousIndex = 0;

  void _selectSection(SettingsSection section) {
    if (_section == section) return;
    setState(() {
      _previousIndex = _section.index;
      _section = section;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final title = Padding(
      padding: EdgeInsets.fromLTRB(
        widget.useRail ? 24 : 20,
        widget.embedded ? 24 : 8,
        20,
        widget.useRail ? 8 : 4,
      ),
      child: widget.embedded
          ? Semantics(
              header: true,
              child: Text('Settings', style: palette.pageTitle),
            )
          : const SizedBox.shrink(),
    );
    final pane = SettingsContentPane(
      section: _section,
      previousIndex: _previousIndex,
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
    );

    if (widget.useRail) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 248,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.embedded
                    ? Colors.transparent
                    : palette.background,
                border: Border(
                  right: BorderSide(
                    color: palette.border.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  Expanded(
                    child: SettingsNavigation(
                      key: const ValueKey('settings-navigation-rail'),
                      section: _section,
                      wide: true,
                      showMediaLibrary: !widget.embedded,
                      onSelected: _selectSection,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: pane),
        ],
      );
    }

    return Column(
      children: [
        if (widget.embedded) title,
        SettingsNavigation(
          key: const ValueKey('settings-top-navigation'),
          section: _section,
          wide: false,
          showMediaLibrary: !widget.embedded,
          onSelected: _selectSection,
        ),
        Divider(height: 1, color: palette.border),
        Expanded(child: pane),
      ],
    );
  }
}

const List<(String, List<SettingsSection>)> _navGroups = [
  (
    'Personalize',
    [
      SettingsSection.appearance,
      SettingsSection.animation,
      SettingsSection.playerControls,
    ],
  ),
  (
    'Playback',
    [
      SettingsSection.playback,
      SettingsSection.videoAudio,
      SettingsSection.shortcuts,
    ],
  ),
  (
    'System',
    [
      SettingsSection.desktopIntegration,
      SettingsSection.mediaLibrary,
      SettingsSection.about,
    ],
  ),
];

const double _navItemHeight = 42;
const double _navItemGap = 2;
const double _navLabelHeight = 30;
const double _navGroupGap = 12;

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

  bool _visible(SettingsSection item) =>
      showMediaLibrary || item != SettingsSection.mediaLibrary;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    if (!wide) {
      return ColoredBox(
        color: palette.background,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in SettingsSection.values.where(_visible))
                SettingsNavigationItem(
                  section: item,
                  selected: item == section,
                  wide: false,
                  onPressed: () => onSelected(item),
                ),
            ],
          ),
        ),
      );
    }

    var y = 0.0;
    double? indicatorTop;
    final children = <Widget>[];
    var firstGroup = true;
    for (final (label, sections) in _navGroups) {
      final visible = sections.where(_visible).toList();
      if (visible.isEmpty) continue;
      if (!firstGroup) y += _navGroupGap;
      firstGroup = false;
      children.add(
        Positioned(
          top: y,
          left: 12,
          right: 12,
          height: _navLabelHeight,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                label,
                style: palette.metadata.copyWith(
                  color: palette.muted.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
      y += _navLabelHeight;
      for (final item in visible) {
        if (item == section) indicatorTop = y;
        children.add(
          Positioned(
            top: y,
            left: 0,
            right: 0,
            height: _navItemHeight,
            child: SettingsNavigationItem(
              section: item,
              selected: item == section,
              wide: true,
              onPressed: () => onSelected(item),
            ),
          ),
        );
        y += _navItemHeight + _navItemGap;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: SizedBox(
        height: y,
        child: Stack(
          children: [
            if (indicatorTop != null)
              AnimatedPositioned(
                duration: AppMotion.duration(context, AppMotion.spatialDefault),
                curve: AppMotion.spatialProgressCurve,
                top: indicatorTop,
                left: 0,
                right: 0,
                height: _navItemHeight,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadii.artwork),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 3,
                        height: 18,
                        margin: const EdgeInsets.only(left: 1),
                        decoration: BoxDecoration(
                          color: palette.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ...children,
          ],
        ),
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
    final radius = BorderRadius.circular(AppRadii.artwork);
    final color = selected ? palette.text : palette.muted;
    final labelStyle = palette.rowPrimary.copyWith(
      color: color,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
    final duration = AppMotion.duration(context, AppMotion.standard);

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: palette.hover.withValues(alpha: selected ? 0.0 : 0.5),
          splashColor: palette.accent.withValues(alpha: 0.10),
          highlightColor: Colors.transparent,
          child: AnimatedContainer(
            duration: duration,
            curve: AppMotion.standardCurve,
            padding: EdgeInsets.only(
              left: wide ? 14 : 14,
              right: 12,
              top: wide ? 0 : 8,
              bottom: wide ? 0 : 8,
            ),
            decoration: BoxDecoration(
              color: !wide && selected
                  ? palette.accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: radius,
            ),
            child: Row(
              mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
              children: [
                TweenAnimationBuilder<Color?>(
                  duration: duration,
                  tween: ColorTween(
                    end: selected ? palette.accent : palette.muted,
                  ),
                  builder: (context, c, _) =>
                      Icon(section.icon, size: 19, color: c),
                ),
                const SizedBox(width: 12),
                if (wide)
                  Expanded(
                    child: AnimatedDefaultTextStyle(
                      duration: duration,
                      style: labelStyle,
                      child: Text(
                        section.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
    this.previousIndex = 0,
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
  final int previousIndex;
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
          AnimatedSwitcher(
            duration: AppMotion.duration(context, AppMotion.standard),
            switchInCurve: AppMotion.enter,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: Padding(
              key: ValueKey<SettingsSection>(section),
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Row(
                    children: [
                      SettingsIconChip(icon: section.icon, size: 44),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.label,
                              style: palette.albumTitle.copyWith(
                                fontSize: AppType.title,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              section.description,
                              style: palette.rowSecondary,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: AppSectionReveal(
              key: ValueKey<SettingsSection>(section),
              duration: AppMotion.emphasized,
              beginOffset: Offset(
                0,
                section.index >= previousIndex ? 0.03 : -0.03,
              ),
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
                  appPreferences: preferences,
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
