import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/control_density.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/playback_settings.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../../domain/updates/engine_update_channel.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/empty_state.dart';
import '../../core/slider_overlay.dart';
import '../player_controller.dart';
import 'update_center_dialog.dart';

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

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  _SettingsSection _section = _SettingsSection.appearance;
  AppPreferencesRepository? _fallbackPreferences;
  DesktopIntegrationService? _fallbackDesktopIntegration;
  MediaLibraryRepository? _fallbackLibraryRepository;

  AppPreferencesRepository get _preferences =>
      widget.appPreferences ??
      (_fallbackPreferences ??= AppPreferencesRepository());

  DesktopIntegrationService get _desktopIntegration =>
      widget.desktopIntegration ??
      (_fallbackDesktopIntegration ??= _EmptyDesktopIntegrationService());

  MediaLibraryRepository get _libraryRepository =>
      widget.libraryRepository ??
      (_fallbackLibraryRepository ??= _EmptyMediaLibraryRepository());

  @override
  void initState() {
    super.initState();
    if (widget.showMediaLibrary) _section = _SettingsSection.mediaLibrary;
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
    // Note: Do NOT listen to widget.controller at the root dialog level!
    // Playback position updates frequently; rebuilding the whole settings dialog
    // on every position tick wastes CPU/GPU cycles. Only child widgets listen as needed.
    if (widget.embedded) {
      return _buildBody(context);
    }

    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
      ),
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
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

      return SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            if (!widget.embedded) ...[
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    bottom: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.6),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.14,
                        ),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.settings_suggest_rounded,
                        size: 17,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Settings',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close settings',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.control),
                        ),
                      ),
                      onPressed:
                          widget.onClose ?? () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ),
              ),
            ],
            if (useRail)
              Expanded(
                child: Row(
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
                        child: _SettingsNavigation(
                          key: const ValueKey('settings-navigation-rail'),
                          section: _section,
                          wide: true,
                          showMediaLibrary: !widget.embedded,
                          onSelected: _selectSection,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _SettingsContentPane(
                        section: _section,
                        controller: widget.controller,
                        updates: widget.updates,
                        engineUpdates: widget.engineUpdates,
                        pickSubtitle: widget.pickSubtitle,
                        compactViewport: compactViewport,
                        preferences: _preferences,
                        desktopIntegration: _desktopIntegration,
                        libraryRepository: _libraryRepository,
                        pickDirectory: widget.pickDirectory,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              _SettingsNavigation(
                key: const ValueKey('settings-top-navigation'),
                section: _section,
                wide: false,
                showMediaLibrary: !widget.embedded,
                onSelected: _selectSection,
              ),
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: _SettingsContentPane(
                  section: _section,
                  controller: widget.controller,
                  updates: widget.updates,
                  engineUpdates: widget.engineUpdates,
                  pickSubtitle: widget.pickSubtitle,
                  compactViewport: compactViewport,
                  preferences: _preferences,
                  desktopIntegration: _desktopIntegration,
                  libraryRepository: _libraryRepository,
                  pickDirectory: widget.pickDirectory,
                ),
              ),
            ],
            if (!widget.embedded) ...[
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.6),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(80, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                      onPressed:
                          widget.onClose ?? () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  void _selectSection(_SettingsSection section) {
    if (_section == section) return;
    setState(() => _section = section);
  }
}

enum _SettingsSection {
  appearance,
  playback,
  videoAudio,
  shortcuts,
  desktopIntegration,
  mediaLibrary,
  about,
}

extension on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.appearance => 'Appearance',
    _SettingsSection.playback => 'Playback',
    _SettingsSection.videoAudio => 'Video & audio',
    _SettingsSection.desktopIntegration => 'Desktop & system',
    _SettingsSection.mediaLibrary => 'Media library',
    _SettingsSection.shortcuts => 'Shortcuts',
    _SettingsSection.about => 'About & engine',
  };

  String get description => switch (this) {
    _SettingsSection.appearance =>
      'Customize themes, dynamic accents, and control density.',
    _SettingsSection.playback =>
      'Manage playback behaviors, repeat, speed, and media tracks.',
    _SettingsSection.videoAudio =>
      'Fine-tune video quality, color calibration, and timing delays.',
    _SettingsSection.desktopIntegration =>
      'Configure file opening behavior and OS power settings.',
    _SettingsSection.mediaLibrary =>
      'Manage indexed folders and monitor library status.',
    _SettingsSection.shortcuts =>
      'Rebind player hotkeys and review mouse shortcuts.',
    _SettingsSection.about =>
      'Inspect application version, engine build, and check for updates.',
  };

  IconData get icon => switch (this) {
    _SettingsSection.appearance => Icons.palette_outlined,
    _SettingsSection.playback => Icons.play_circle_outline_rounded,
    _SettingsSection.videoAudio => Icons.tune_rounded,
    _SettingsSection.desktopIntegration => Icons.desktop_windows_rounded,
    _SettingsSection.mediaLibrary => Icons.folder_copy_rounded,
    _SettingsSection.shortcuts => Icons.keyboard_alt_outlined,
    _SettingsSection.about => Icons.info_outline_rounded,
  };
}

class _SettingsNavigation extends StatelessWidget {
  const _SettingsNavigation({
    super.key,
    required this.section,
    required this.wide,
    required this.onSelected,
    this.showMediaLibrary = true,
  });

  final _SettingsSection section;
  final bool wide;
  final bool showMediaLibrary;
  final ValueChanged<_SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = _SettingsSection.values
        .where(
          (item) => showMediaLibrary || item != _SettingsSection.mediaLibrary,
        )
        .map(
          (item) => _SettingsNavigationItem(
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

class _SettingsNavigationItem extends StatelessWidget {
  const _SettingsNavigationItem({
    required this.section,
    required this.selected,
    required this.wide,
    required this.onPressed,
  });

  final _SettingsSection section;
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
                    color: selected ? accent : theme.colorScheme.onSurfaceVariant,
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
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

class _SettingsContentPane extends StatelessWidget {
  const _SettingsContentPane({
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

  final _SettingsSection section;
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
                key: ValueKey<_SettingsSection>(section),
                child: switch (section) {
                  _SettingsSection.appearance => _AppearanceSettings(
                    controller: controller,
                    compactViewport: compactViewport,
                    appPreferences: preferences,
                  ),
                  _SettingsSection.playback => _PlaybackSettings(
                    controller: controller,
                    pickSubtitle: pickSubtitle,
                  ),
                  _SettingsSection.videoAudio => _VideoAudioSettings(
                    controller: controller,
                  ),
                  _SettingsSection.desktopIntegration =>
                    _DesktopIntegrationSettings(
                      preferences: preferences,
                      desktopIntegration: desktopIntegration,
                    ),
                  _SettingsSection.mediaLibrary => _MediaLibrarySettings(
                    libraryRepository: libraryRepository,
                    pickDirectory: pickDirectory,
                  ),
                  _SettingsSection.shortcuts => _ShortcutsSettings(
                    preferences: preferences,
                  ),
                  _SettingsSection.about => _AboutSettings(
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

// -----------------------------------------------------------------------------
// Shared Modern Setting Cards & Components
// -----------------------------------------------------------------------------

/// Centered content container constraining settings width to 820px
/// with generous 40px horizontal and 32px vertical padding.
class _SettingsContentContainer extends StatelessWidget {
  const _SettingsContentContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: child,
        ),
      ),
    );
  }
}

class _SettingsCardGroup extends StatelessWidget {
  const _SettingsCardGroup({
    this.title,
    this.description,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    title!,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 2),
              Text(
                description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
          ],
          Material(
            color: theme.colorScheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Appearance & Theming Section
// -----------------------------------------------------------------------------

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.controller,
    required this.compactViewport,
    this.appPreferences,
  });

  final PlayerController controller;
  final bool compactViewport;
  final AppPreferencesRepository? appPreferences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return _SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Theme Mode Cards
          if (appPreferences != null)
            ListenableBuilder(
              listenable: appPreferences!,
              builder: (context, _) {
                final currentMode = appPreferences!.preferences.themeMode;
                return _SettingsCardGroup(
                  title: 'Theme mode',
                  description: 'Select your preferred visual appearance.',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ThemeModeCard(
                              title: 'Dark',
                              icon: Icons.dark_mode_rounded,
                              selected: currentMode == ThemeMode.dark,
                              previewDark: true,
                              onTap: () => unawaited(
                                appPreferences!.setThemeMode(ThemeMode.dark),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _ThemeModeCard(
                              title: 'Light',
                              icon: Icons.light_mode_rounded,
                              selected: currentMode == ThemeMode.light,
                              previewDark: false,
                              onTap: () => unawaited(
                                appPreferences!.setThemeMode(ThemeMode.light),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _ThemeModeCard(
                              title: 'System',
                              icon: Icons.brightness_auto_rounded,
                              selected: currentMode == ThemeMode.system,
                              isSystem: true,
                              onTap: () => unawaited(
                                appPreferences!.setThemeMode(ThemeMode.system),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),

          // 2. Accent Color Palette
          if (appPreferences != null)
            ListenableBuilder(
              listenable: appPreferences!,
              builder: (context, _) {
                final prefs = appPreferences!.preferences;
                final activeId = prefs.accentPreset;
                final isArtworkSyncActive = prefs.dynamicArtworkColor;

                return _SettingsCardGroup(
                  title: 'Accent color',
                  description:
                      'Curated palettes for highlights, timeline bars, and buttons.',
                  trailing: isArtworkSyncActive
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.auto_awesome_rounded,
                                size: 13,
                                color: accent,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Overridden by active artwork',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: AnimatedOpacity(
                        duration: AppMotion.duration(context, AppMotion.quick),
                        opacity: isArtworkSyncActive ? 0.5 : 1.0,
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final preset in AppAccentPreset.all)
                              _AccentColorChip(
                                preset: preset,
                                selected: preset.id == activeId,
                                isOverridden: isArtworkSyncActive,
                                onTap: () => unawaited(
                                  appPreferences!.setAccentPreset(preset.id),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),

          // 3. Dynamic Tinting & Surface Options
          if (appPreferences != null)
            ListenableBuilder(
              listenable: appPreferences!,
              builder: (context, _) {
                final prefs = appPreferences!.preferences;
                return _SettingsCardGroup(
                  title: 'Personalization & Display',
                  children: [
                    _SettingsSwitchTile(
                      icon: Icons.auto_awesome_rounded,
                      title: 'Sync with media artwork',
                      subtitle:
                          'Extracts colors from active video thumbnails or music album covers to dynamically tint the player.',
                      value: prefs.dynamicArtworkColor,
                      onChanged: (val) => unawaited(
                        appPreferences!.setDynamicArtworkColor(val),
                      ),
                    ),
                    _SettingsSwitchTile(
                      icon: Icons.contrast_rounded,
                      title: 'OLED pure black',
                      subtitle:
                          'Renders true pitch-black surfaces in dark mode for OLED displays and battery efficiency.',
                      value: prefs.oledBlack,
                      onChanged: (val) =>
                          unawaited(appPreferences!.setOledBlack(val)),
                    ),
                    _SettingsSwitchTile(
                      icon: Icons.motion_photos_off_rounded,
                      title: 'Calm mode (Reduced motion)',
                      subtitle:
                          'Disables animations and transitions app-wide for minimal visual stimulation and low CPU usage.',
                      value: prefs.reduceMotion,
                      onChanged: (val) => unawaited(
                        appPreferences!.updatePreferences(
                          prefs.copyWith(reduceMotion: val),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),

          // 4. Control Density & Live Preview merged card
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final isCompact =
                  controller.controlDensity == ControlDensity.compact;
              return _SettingsCardGroup(
                title: 'Player control size',
                description:
                    'Compact saves vertical space; Normal gives larger touch targets.',
                trailing: SegmentedButton<ControlDensity>(
                  key: const ValueKey('control-density-selector'),
                  segments: const [
                    ButtonSegment<ControlDensity>(
                      value: ControlDensity.compact,
                      label: Text('Compact'),
                    ),
                    ButtonSegment<ControlDensity>(
                      value: ControlDensity.normal,
                      label: Text('Normal'),
                    ),
                  ],
                  selected: {controller.controlDensity},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? accent
                          : theme.colorScheme.surfaceContainer;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface;
                    }),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                  ),
                  onSelectionChanged: (selection) {
                    controller.setControlDensity(selection.first);
                  },
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: _ControlBarPreview(
                          compact: isCompact,
                          compactViewport: compactViewport,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ThemeModeCard extends StatelessWidget {
  const _ThemeModeCard({
    required this.title,
    required this.icon,
    required this.selected,
    this.previewDark = true,
    this.isSystem = false,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final bool previewDark;
  final bool isSystem;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Semantics(
      selected: selected,
      button: true,
      label: 'Theme mode $title',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(
                color: selected
                    ? accent
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                width: selected ? 1.8 : 1,
              ),
            ),
            child: Column(
              children: [
                Container(
                  height: 52,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: isSystem
                        ? null
                        : (previewDark
                            ? const Color(0xFF121215)
                            : const Color(0xFFF8FAFC)),
                    gradient: isSystem
                        ? const LinearGradient(
                            colors: [Color(0xFF121215), Color(0xFFF8FAFC)],
                            stops: [0.5, 0.5],
                          )
                        : null,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected
                          ? accent.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.4,
                            ),
                      width: 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Mini titlebar chrome with 3 window controls
                      Positioned(
                        top: 5,
                        left: 7,
                        child: Row(
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(
                                color: Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(
                                color: Color(0xFFF59E0B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Mini media stage seek line and transport dot
                      Positioned(
                        bottom: 7,
                        left: 8,
                        right: 8,
                        child: Row(
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: selected
                                    ? accent
                                    : const Color(0xFF888888),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Container(
                                height: 2.5,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? accent.withValues(alpha: 0.8)
                                      : const Color(
                                          0xFF888888,
                                        ).withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Center(
                        child: Icon(
                          icon,
                          size: 16,
                          color: selected
                              ? accent
                              : (previewDark || isSystem
                                  ? Colors.white70
                                  : Colors.black54),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected ? accent : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.check_rounded, size: 14, color: accent),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccentColorChip extends StatelessWidget {
  const _AccentColorChip({
    required this.preset,
    required this.selected,
    this.isOverridden = false,
    required this.onTap,
  });

  final AppAccentPreset preset;
  final bool selected;
  final bool isOverridden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayColor = isDark ? preset.color : preset.lightColor;
    final isColorDark =
        ThemeData.estimateBrightnessForColor(displayColor) == Brightness.dark;

    final effectiveColor = isOverridden && selected
        ? displayColor.withValues(alpha: 0.7)
        : displayColor;

    return Tooltip(
      message: isOverridden
          ? '${preset.label} (Overridden by active artwork)'
          : '${preset.label} — ${preset.description}',
      waitDuration: const Duration(milliseconds: 300),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          hoverColor: displayColor.withValues(alpha: 0.1),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? (isOverridden
                      ? displayColor.withValues(alpha: 0.08)
                      : displayColor.withValues(alpha: 0.16))
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.35,
                    ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected
                    ? (isOverridden
                        ? displayColor.withValues(alpha: 0.4)
                        : displayColor)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                width: selected ? (isOverridden ? 1.2 : 1.6) : 1,
              ),
              boxShadow: selected && !isOverridden
                  ? [
                      BoxShadow(
                        color: displayColor.withValues(alpha: 0.22),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: effectiveColor,
                    shape: BoxShape.circle,
                    boxShadow: !isOverridden
                        ? [
                            BoxShadow(
                              color: displayColor.withValues(alpha: 0.35),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: isColorDark ? Colors.white : Colors.black87,
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                Text(
                  preset.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected && !isOverridden
                        ? displayColor
                        : theme.colorScheme.onSurface,
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

class _ControlBarPreview extends StatelessWidget {
  const _ControlBarPreview({
    required this.compact,
    required this.compactViewport,
  });

  final bool compact;
  final bool compactViewport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final buttonSize = compact ? 28.0 : 36.0;
    final iconSize = compact ? 15.0 : 18.0;
    const previewHeight = 120.0;
    final barHeight = compact ? 42.0 : 52.0;

    return Container(
      key: const ValueKey('control-density-preview'),
      height: previewHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          width: 1,
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            theme.colorScheme.surfaceContainerLowest,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: barHeight,
            child: Center(
              child: Icon(
                Icons.movie_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.35,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: barHeight,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    width: 1,
                  ),
                ),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 16,
                vertical: compact ? 3 : 6,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(
                    value: 0.42,
                    minHeight: compact ? 3 : 4,
                    backgroundColor: theme.colorScheme.outlineVariant,
                    color: accent,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.skip_previous_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: buttonSize,
                              height: buttonSize,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: iconSize + 2,
                                color: theme.colorScheme.onPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.skip_next_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.volume_up_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: compact ? 44 : 60,
                              child: LinearProgressIndicator(
                                value: 0.72,
                                minHeight: 3,
                                backgroundColor:
                                    theme.colorScheme.outlineVariant,
                                color: theme.colorScheme.onSurfaceVariant,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.queue_music_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.fullscreen_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Playback Settings Section
// -----------------------------------------------------------------------------

class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings({
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
      builder: (context, _) => _SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsCardGroup(
              title: 'Queue & session',
              children: [
                _SettingsSwitchTile(
                  icon: Icons.shuffle_rounded,
                  title: 'Shuffle queue',
                  subtitle: 'Plays queue tracks and videos in random order.',
                  value: controller.shuffle,
                  onChanged: (_) => unawaited(controller.toggleShuffle()),
                ),
                _SettingsSwitchTile(
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
            _SettingsCardGroup(
              title: 'Transport tuning',
              children: [
                _DropdownSettingTile<double>(
                  icon: Icons.speed_rounded,
                  label: 'Playback speed',
                  value: _nearestRate(controller.rate),
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
                _DropdownSettingTile<String>(
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
            _SettingsCardGroup(
              title: 'Media tracks',
              children: [
                _TrackSettingTile<AudioTrack>(
                  icon: Icons.audiotrack_rounded,
                  label: 'Audio track',
                  tracks: controller.audioTracks,
                  selected: controller.currentAudioTrack,
                  trackLabel: (t) => _trackLabel(t.id, t.title, t.language),
                  onSelected: (t) => unawaited(controller.setAudioTrack(t)),
                ),
                _TrackSettingTile<SubtitleTrack>(
                  icon: Icons.subtitles_rounded,
                  label: 'Subtitle track',
                  tracks: controller.subtitleTracks,
                  selected: controller.currentSubtitleTrack,
                  trackLabel: (t) => _trackLabel(t.id, t.title, t.language),
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
                    Navigator.of(context).pop();
                    final path = await pickSubtitle();
                    if (path == null || path.isEmpty) return;
                    try {
                      await controller.loadSubtitle(path);
                    } catch (_) {}
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

// -----------------------------------------------------------------------------
// Video & Audio Calibration Section
// -----------------------------------------------------------------------------

class _VideoAudioSettings extends StatefulWidget {
  const _VideoAudioSettings({required this.controller});

  final PlayerController controller;

  @override
  State<_VideoAudioSettings> createState() => _VideoAudioSettingsState();
}

class _VideoAudioSettingsState extends State<_VideoAudioSettings> {
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

    return _SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsCardGroup(
            title: 'Rendering engine',
            children: [
              _DropdownSettingTile<PlaybackQualityPreset>(
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
              _SettingsSwitchTile(
                icon: Icons.memory_rounded,
                title: 'Prefer hardware decoding',
                subtitle:
                    'Offloads video decoding to the dedicated GPU when compatible codecs are available.',
                value: _draft.preferHardwareDecoding,
                onChanged: (val) =>
                    _commit(_draft.copyWith(preferHardwareDecoding: val)),
              ),
            ],
          ),
          _SettingsCardGroup(
            title: 'Picture calibration',
            children: [
              _ModernSliderTile(
                key: const ValueKey('playback-brightness'),
                label: 'Brightness',
                value: _draft.brightness,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: _colorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(brightness: val)),
                onChangeEnd: (val) =>
                    _commit(_draft.copyWith(brightness: val)),
              ),
              _ModernSliderTile(
                key: const ValueKey('playback-contrast'),
                label: 'Contrast',
                value: _draft.contrast,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: _colorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(contrast: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(contrast: val)),
              ),
              _ModernSliderTile(
                key: const ValueKey('playback-saturation'),
                label: 'Saturation',
                value: _draft.saturation,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: _colorValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(saturation: val)),
                onChangeEnd: (val) =>
                    _commit(_draft.copyWith(saturation: val)),
              ),
              _ModernSliderTile(
                key: const ValueKey('playback-gamma'),
                label: 'Gamma',
                value: _draft.gamma,
                min: -100,
                max: 100,
                divisions: 200,
                formatValue: _colorValue,
                onChanged: (val) => _changeDraft(_draft.copyWith(gamma: val)),
                onChangeEnd: (val) => _commit(_draft.copyWith(gamma: val)),
              ),
            ],
          ),
          _SettingsCardGroup(
            title: 'Timing offsets',
            children: [
              _ModernSliderTile(
                key: const ValueKey('playback-audio-delay'),
                label: 'Audio delay',
                value: _draft.audioDelaySeconds,
                min: -10,
                max: 10,
                divisions: 200,
                formatValue: _secondsValue,
                onChanged: (val) =>
                    _changeDraft(_draft.copyWith(audioDelaySeconds: val)),
                onChangeEnd: (val) =>
                    _commit(_draft.copyWith(audioDelaySeconds: val)),
              ),
              _ModernSliderTile(
                key: const ValueKey('playback-subtitle-delay'),
                label: 'Subtitle delay',
                value: _draft.subtitleDelaySeconds,
                min: -10,
                max: 10,
                divisions: 200,
                formatValue: _secondsValue,
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

class _ModernSliderTile extends StatelessWidget {
  const _ModernSliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) formatValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final display = formatValue(value);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
                child: Text(
                  display,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: value != 0 ? accent : theme.colorScheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          SliderOverlay(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              semanticFormatterCallback: (val) => '$label ${formatValue(val)}',
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

String _colorValue(double value) =>
    value == 0 ? '0' : '${value > 0 ? '+' : ''}${value.toStringAsFixed(0)}';

String _secondsValue(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} s';

// -----------------------------------------------------------------------------
// Desktop & OS Integration Section
// -----------------------------------------------------------------------------

class _DesktopIntegrationSettings extends StatelessWidget {
  const _DesktopIntegrationSettings({
    required this.preferences,
    required this.desktopIntegration,
  });

  final AppPreferencesRepository preferences;
  final DesktopIntegrationService desktopIntegration;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final currentOpenBehavior = preferences.preferences.openBehavior;
      final theme = Theme.of(context);

      return _SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (preferences.saveError != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Could not save settings. Please verify app directory write permissions.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(preferences.flush()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
            _SettingsCardGroup(
              title: 'Opening media files',
              description:
                  'Choose behavior when files are opened while video is playing.',
              children: [
                RadioGroup<OpenBehaviorPreference>(
                  groupValue: currentOpenBehavior,
                  onChanged: (val) {
                    if (val != null) {
                      unawaited(preferences.setOpenBehavior(val));
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-keep-playing'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                        title: const Text('Keep playing and add to queue'),
                        subtitle: const Text(
                          'Appends opened media without interrupting the active stream.',
                        ),
                        value: OpenBehaviorPreference.keepPlayingAndEnqueue,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-play-now'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                        title: const Text('Play new files immediately'),
                        subtitle: const Text(
                          'Switches playback to the new file right away.',
                        ),
                        value: OpenBehaviorPreference.playNewFilesNow,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-ask-every-time'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                        title: const Text('Ask every time'),
                        subtitle: const Text(
                          'Displays a prompt asking whether to play or enqueue.',
                        ),
                        value: OpenBehaviorPreference.askEveryTime,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            _SettingsCardGroup(
              title: 'Power & Sleep',
              children: [
                _SettingsSwitchTile(
                  key: const ValueKey('keep-awake-switch'),
                  icon: Icons.coffee_rounded,
                  title: 'Prevent computer sleep during playback',
                  subtitle:
                      'Inhibits screen savers and system standby while video is active.',
                  value: preferences.preferences.keepAwakeDuringPlayback,
                  onChanged: (val) => unawaited(preferences.setKeepAwake(val)),
                ),
              ],
            ),
            _SettingsCardGroup(
              title: 'System integration',
              children: [
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
                      Icons.settings_applications_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: const Text('Default app associations'),
                  subtitle: const Text(
                    'Configure default video/audio player file extensions in OS settings.',
                  ),
                  trailing: OutlinedButton.icon(
                    key: const ValueKey('default-apps-button'),
                    onPressed: () => unawaited(
                      desktopIntegration.openDefaultAppsSettings(),
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text('Open settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

// -----------------------------------------------------------------------------
// Media Library Section
// -----------------------------------------------------------------------------

class LibraryFoldersView extends StatelessWidget {
  const LibraryFoldersView({super.key, required this.repository});
  final MediaLibraryRepository repository;
  @override
  Widget build(BuildContext context) =>
      _MediaLibrarySettings(libraryRepository: repository);
}

class _MediaLibrarySettings extends StatelessWidget {
  const _MediaLibrarySettings({
    required this.libraryRepository,
    this.pickDirectory,
  });

  final MediaLibraryRepository libraryRepository;
  final Future<String?> Function()? pickDirectory;

  Future<void> _addFolder(BuildContext context) async {
    try {
      final path = await (pickDirectory != null
          ? pickDirectory!()
          : getDirectoryPath());
      if (path == null || path.isEmpty) return;
      await libraryRepository.addFolder(path);
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Could not add folder. Please check directory permissions.',
        tone: AppToastTone.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: libraryRepository,
    builder: (context, _) {
      final folders = libraryRepository.folders;
      final theme = Theme.of(context);
      final accent = theme.colorScheme.primary;
      final isReady = libraryRepository.isReady;

      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
                child: Row(
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('add-folder-button'),
                      icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                      label: const Text('Add media folder'),
                      onPressed: isReady ? () => _addFolder(context) : null,
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      key: const ValueKey('rescan-all-button'),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('Rescan library'),
                      onPressed: isReady && folders.isNotEmpty
                          ? () => unawaited(libraryRepository.rescanAll())
                          : null,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: folders.isEmpty
                    ? const EmptyState(
                        title: 'No media folders added',
                        message:
                            'Add folders containing videos or music to build your local catalog.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 8,
                        ),
                    itemCount: folders.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      return Material(
                        color: theme.colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppRadii.control,
                          ),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        child: ListTile(
                          leading: Icon(
                            folder.isAvailable
                                ? Icons.folder_rounded
                                : Icons.folder_off_rounded,
                            color: folder.isAvailable
                                ? accent
                                : theme.colorScheme.error,
                            size: 24,
                          ),
                          title: Text(
                            folder.path,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: folder.isAvailable
                                      ? AppColors.jade
                                      : AppColors.rose,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                folder.isAvailable
                                    ? 'Available'
                                    : 'Drive unavailable',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: folder.isAvailable
                                      ? theme.colorScheme.onSurfaceVariant
                                      : AppColors.rose,
                                ),
                              ),
                              const Text(' · '),
                              Text(
                                '${folder.fileCount} indexed ${folder.fileCount == 1 ? 'file' : 'files'}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            key: ValueKey('remove-folder-${folder.path}'),
                            tooltip: 'Remove folder',
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 19,
                            ),
                            onPressed: () => unawaited(
                              libraryRepository.removeFolder(folder.path),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
    },
  );
}

// -----------------------------------------------------------------------------
// Shortcuts Section
// -----------------------------------------------------------------------------

class _ShortcutsSettings extends StatelessWidget {
  const _ShortcutsSettings({required this.preferences});

  final AppPreferencesRepository preferences;

  Future<void> _rebind(
    BuildContext context,
    PlayerHotkeys hotkeys,
    PlayerAction action,
  ) async {
    final binding = await showDialog<HotkeyBinding>(
      context: context,
      builder: (_) => _HotkeyCaptureDialog(
        action: action,
        initial: hotkeys.bindingFor(action),
        hotkeys: hotkeys,
      ),
    );
    if (binding != null) await preferences.setHotkey(action, binding);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final current = preferences.preferences;
      final hotkeys = current.hotkeys;

      return _SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsCardGroup(
              title: 'Seek & sync steps',
              children: [
                _DropdownSettingTile<int>(
                  icon: Icons.timer_outlined,
                  label: 'Arrow seek step',
                  value: current.seekStepSeconds,
                  items: DesktopPreferences.seekStepOptions
                      .map(
                        (sec) => DropdownMenuItem(
                          value: sec,
                          child: Text('$sec seconds'),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) unawaited(preferences.setSeekStep(val));
                  },
                ),
                _DropdownSettingTile<int>(
                  icon: Icons.sync_rounded,
                  label: 'Delay sync step',
                  value: current.syncStepMs,
                  items: DesktopPreferences.syncStepOptions
                      .map(
                        (ms) => DropdownMenuItem(
                          value: ms,
                          child: Text('$ms ms'),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) unawaited(preferences.setSyncStep(val));
                  },
                ),
              ],
            ),
            _SettingsCardGroup(
              title: 'Keyboard hotkeys',
              description: 'Click any shortcut binding to capture a new key combination.',
              trailing: TextButton.icon(
                key: const ValueKey('reset-hotkeys'),
                onPressed: () => unawaited(preferences.resetHotkeys()),
                icon: const Icon(Icons.restore_rounded, size: 15),
                label: const Text('Reset hotkeys'),
              ),
              children: [
                for (final action in PlayerAction.values)
                  _HotkeyRowTile(
                    key: ValueKey<String>('hotkey-${action.name}'),
                    action: action,
                    binding: hotkeys.bindingFor(action),
                    onPressed: () =>
                        unawaited(_rebind(context, hotkeys, action)),
                  ),
              ],
            ),
            _SettingsCardGroup(
              title: 'Mouse & system shortcuts',
              children: const [
                _ShortcutRow(
                  keys: 'Mouse wheel',
                  action: 'Adjust volume up or down',
                ),
                _ShortcutRow(
                  keys: 'Left click video',
                  action: 'Toggle play / pause',
                ),
                _ShortcutRow(
                  keys: 'Double click video',
                  action: 'Toggle full screen',
                ),
                _ShortcutRow(
                  keys: 'Right click video',
                  action: 'Open player context menu',
                ),
                _ShortcutRow(keys: 'Ctrl + O', action: 'Open files dialog'),
                _ShortcutRow(keys: 'Ctrl + L', action: 'Open network stream URL'),
                _ShortcutRow(keys: 'Ctrl + M', action: 'Open media library'),
                _ShortcutRow(keys: 'F11', action: 'Toggle full screen'),
                _ShortcutRow(keys: 'Escape', action: 'Dismiss menu / exit full screen'),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _HotkeyRowTile extends StatelessWidget {
  const _HotkeyRowTile({
    super.key,
    required this.action,
    required this.binding,
    required this.onPressed,
  });

  final PlayerAction action;
  final HotkeyBinding binding;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              action.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(80, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            child: Text(
              binding.label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              keys,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              action,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HotkeyCaptureDialog extends StatefulWidget {
  const _HotkeyCaptureDialog({
    required this.action,
    required this.initial,
    required this.hotkeys,
  });

  final PlayerAction action;
  final HotkeyBinding initial;
  final PlayerHotkeys hotkeys;

  @override
  State<_HotkeyCaptureDialog> createState() => _HotkeyCaptureDialogState();
}

class _HotkeyCaptureDialogState extends State<_HotkeyCaptureDialog> {
  static final Set<LogicalKeyboardKey> _nonBindingKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
  };

  final FocusNode _focusNode = FocusNode(debugLabel: 'Hotkey capture');
  HotkeyBinding? _captured;
  PlayerAction? _conflict;

  @override
  void initState() {
    super.initState();
    _captured = widget.initial;
    _conflict = widget.hotkeys.actionBoundTo(
      widget.initial,
      excluding: widget.action,
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_nonBindingKeys.contains(key)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final binding = HotkeyBinding.key(
      key,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
    setState(() {
      _captured = binding;
      _conflict = widget.hotkeys.actionBoundTo(
        binding,
        excluding: widget.action,
      );
    });
    return KeyEventResult.handled;
  }

  void _restoreDefault() {
    final binding = PlayerHotkeys.defaults.bindingFor(widget.action);
    setState(() {
      _captured = binding;
      _conflict = widget.hotkeys.actionBoundTo(
        binding,
        excluding: widget.action,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final captured = _captured;
    final conflict = _conflict;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('Shortcut for ${widget.action.label}'),
      content: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Press your desired key combination. Escape cancels.'),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadii.control),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
              child: Text(
                captured?.label ?? 'Press keys…',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            if (conflict != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Currently assigned to “${conflict.label}”. Choose another shortcut.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _restoreDefault, child: const Text('Default')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: captured == null || conflict != null
              ? null
              : () => Navigator.of(context).pop(captured),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// About & Updates Section
// -----------------------------------------------------------------------------

class _AboutSettings extends StatelessWidget {
  const _AboutSettings({
    required this.updates,
    required this.engineUpdates,
    required this.engineVersion,
  });

  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String engineVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return _SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.15),
                  theme.colorScheme.surfaceContainer,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(
                color: accent.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 32,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mpvson',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Modern desktop media player powered by mpv',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => UpdateCenterDialog(
                        updates: updates,
                        engineUpdates: engineUpdates,
                        engineVersion: engineVersion,
                      ),
                    );
                  },
                  icon: const Icon(Icons.system_update_alt_rounded, size: 16),
                  label: const Text('Update center'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SettingsCardGroup(
            title: 'System & Engine status',
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([updates, engineUpdates]),
                builder: (context, _) => ListTile(
                  leading: const Icon(Icons.update_rounded),
                  title: const Text('App & engine updates'),
                  subtitle: Text(
                    _updateSummary(),
                    key: ValueKey<String>(
                      'update-summary-${updates.status}-${engineUpdates.status}',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => UpdateCenterDialog(
                        updates: updates,
                        engineUpdates: engineUpdates,
                        engineVersion: engineVersion,
                      ),
                    );
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.video_settings_rounded),
                title: const Text('Playback engine'),
                subtitle: Text(engineVersion),
              ),
              ListTile(
                leading: const Icon(Icons.source_rounded),
                title: const Text('Engine distribution'),
                subtitle: Text(engineUpdates.sourceLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _updateSummary() {
    final appStatus = switch (updates.status) {
      'checking' => 'Checking…',
      'available' => 'Update available',
      'downloading' => 'Downloading…',
      'ready' => 'Update downloaded',
      'upToDate' => 'Up to date',
      'error' => 'Check failed',
      'unconfigured' => 'Checks not configured',
      _ => null,
    };
    final engineStatus = switch (engineUpdates.status) {
      'available' =>
        engineUpdates.usesOfficialMpvSource
            ? engineUpdates.channel == EngineUpdateChannel.stable
                ? 'Stable engine update available'
                : 'mpv development build available'
            : 'Engine update available',
      'stableUnavailable' => 'Stable engine build unavailable',
      'newerInstalled' => 'Installed engine is newer',
      'savingChannel' => 'Saving engine channel',
      'downloading' || 'staging' => 'Engine update in progress',
      'readyToRestart' => 'Engine staged',
      'error' => 'Engine update failed',
      'upToDate' => 'Engine up to date',
      _ => null,
    };
    final summary = appStatus == null
        ? 'Mpvson ${updates.currentVersion}'
        : 'Mpvson ${updates.currentVersion} · $appStatus';
    return engineStatus == null ? summary : '$summary · $engineStatus';
  }
}

// -----------------------------------------------------------------------------
// Setting Tile Helpers
// -----------------------------------------------------------------------------

class _DropdownSettingTile<T> extends StatelessWidget {
  const _DropdownSettingTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              borderRadius: BorderRadius.circular(AppRadii.control),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackSettingTile<T> extends StatelessWidget {
  const _TrackSettingTile({
    required this.icon,
    required this.label,
    required this.tracks,
    required this.selected,
    required this.trackLabel,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final List<T> tracks;
  final T? selected;
  final String Function(T) trackLabel;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    T? selectedValue;
    for (final track in tracks) {
      if (track == selected) {
        selectedValue = track;
        break;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: selectedValue,
              hint: const Text('Unavailable'),
              borderRadius: BorderRadius.circular(AppRadii.control),
              items: tracks.map<DropdownMenuItem<T>>((track) {
                final itemText = trackLabel(track);
                final isSelected = track == selectedValue;
                return DropdownMenuItem<T>(
                  value: track,
                  child: Semantics(
                    selected: isSelected,
                    label: isSelected ? '$itemText, selected' : itemText,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(itemText, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                );
              }).toList(),
              onChanged: tracks.isEmpty
                  ? null
                  : (track) {
                      if (track != null) onSelected(track);
                    },
            ),
          ),
        ],
      ),
    );
  }
}

String _trackLabel(String id, String? rawTitle, String? rawLanguage) {
  if (id == 'auto') return 'Automatic';
  if (id == 'no') return 'Off';
  final title = (rawTitle ?? '').trim();
  final language = (rawLanguage ?? '').trim();
  if (title.isEmpty && language.isEmpty) return 'Track $id';
  if (title.isEmpty) return language;
  if (language.isEmpty) return title;
  return '$title · $language';
}

double _nearestRate(double rate) => const [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);

// -----------------------------------------------------------------------------
// Fallback Service Stubs
// -----------------------------------------------------------------------------

class _EmptyDesktopIntegrationService extends DesktopIntegrationService {
  @override
  SystemPlaybackStatus get playbackStatus => SystemPlaybackStatus.closed;
  @override
  MediaMetadata get currentMetadata => MediaMetadata.empty;
  @override
  bool get isAwakeInhibited => false;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updatePlaybackState({
    required SystemPlaybackStatus status,
    required Duration position,
    required Duration duration,
    required double playbackRate,
  }) async {}
  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}
  @override
  Future<void> updateCapabilities({
    bool canPlay = true,
    bool canPause = true,
    bool canSeek = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
  }) async {}
  @override
  Future<void> setKeepAwake(
    bool enable, {
    required bool isVideoPlaying,
  }) async {}
  @override
  Future<void> openDefaultAppsSettings() async {}
}

class _EmptyMediaLibraryRepository extends MediaLibraryRepository {
  @override
  LibraryScanStatus get scanStatus => const LibraryScanStatus();
  @override
  List<LibraryFolderRecord> get folders => const [];
  @override
  bool get isReady => true;
  @override
  String? get initializationError => null;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> addFolder(String path) async {}
  @override
  Future<void> removeFolder(String path) async {}
  @override
  Future<List<LibraryFolderRecord>> getFolders() async => const [];
  @override
  Future<void> upsertDiscoveredFiles(List<String> paths) async {}
  @override
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  }) async {}
  @override
  Future<List<MediaItemRecord>> queryMedia({
    MediaKind? kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  }) async => const [];
  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async => null;
  @override
  Future<MediaItemRecord?> getMediaById(String id) async => null;
  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {}
  @override
  Future<void> recordPlayback(String canonicalSource) async {}
  @override
  Future<List<PlaylistRecord>> getPlaylists() async => const [];
  @override
  Future<PlaylistRecord> createPlaylist(String title) async => PlaylistRecord(
    id: '1',
    title: title,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
  @override
  Future<void> deletePlaylist(String playlistId) async {}
  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {}
  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {}
  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {}
  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {}
  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async => const [];
  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async => const [];
  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async => const [];
  @override
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {}
  @override
  Future<void> rescanFolder(String folderPath) async {}
  @override
  Future<void> rescanAll() async {}
  @override
  Future<void> cancelScan() async {}
  @override
  Future<void> dispose() async {
    super.dispose();
  }
}
