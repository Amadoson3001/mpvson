import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/control_density.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/playback_settings.dart';
import '../../../domain/updates/engine_update_channel.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/slider_overlay.dart';
import '../player_controller.dart';
import 'update_center_dialog.dart';

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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => widget.embedded
        ? _buildBody(context)
        : Dialog(
            insetPadding: const EdgeInsets.all(AppSpace.lg),
            child: _buildBody(context),
          ),
  );

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
          ? (availableWidth < 780 ? availableWidth : 780.0)
          : 780.0;
      final dialogHeight = widget.embedded
          ? availableHeight
          : (availableHeight < 640 ? availableHeight : 640.0);
      final useRail = availableWidth >= 700;
      final compactViewport = dialogHeight <= 520;

      return SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            if (!widget.embedded) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  20,
                  AppSpace.xxs,
                  AppSpace.xs,
                  AppSpace.xxs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close settings',
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      onPressed:
                          widget.onClose ?? () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            if (useRail)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 184,
                      child: ColoredBox(
                        color: AppTheme.background,
                        child: _SettingsNavigation(
                          key: const ValueKey('settings-navigation-rail'),
                          section: _section,
                          wide: true,
                          showMediaLibrary: !widget.embedded,
                          onSelected: _selectSection,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
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
              const Divider(height: 1),
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
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  20,
                  AppSpace.xxs,
                  20,
                  AppSpace.xs,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed:
                        widget.onClose ?? () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
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
    _SettingsSection.desktopIntegration => 'Desktop integration',
    _SettingsSection.mediaLibrary => 'Media library',
    _SettingsSection.shortcuts => 'Shortcuts',
    _SettingsSection.about => 'About',
  };

  String get description => switch (this) {
    _SettingsSection.appearance =>
      'Choose how much space the player controls use.',
    _SettingsSection.playback =>
      'Set playback behavior and choose audio or subtitle tracks.',
    _SettingsSection.videoAudio =>
      'Adjust picture quality, color, and playback timing.',
    _SettingsSection.desktopIntegration =>
      'Configure file opening behavior and system integration.',
    _SettingsSection.mediaLibrary =>
      'Manage indexed folders and update library scans.',
    _SettingsSection.shortcuts =>
      'See the mouse and keyboard controls for the player.',
    _SettingsSection.about =>
      'View the app version, playback engine, and update status.',
  };

  IconData get icon => switch (this) {
    _SettingsSection.appearance => Icons.tune_rounded,
    _SettingsSection.playback => Icons.play_circle_outline_rounded,
    _SettingsSection.videoAudio => Icons.high_quality_rounded,
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
        padding: const EdgeInsets.fromLTRB(10, 14, 10, AppSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[item, const SizedBox(height: 4)],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(10, 2, 10, AppSpace.xxs),
      child: Row(mainAxisSize: MainAxisSize.min, children: items),
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
    final accent = Theme.of(context).colorScheme.primary;
    final button = TextButton.icon(
      onPressed: onPressed,
      icon: Icon(section.icon, size: 18),
      label: Text(
        section.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      style:
          TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            foregroundColor: selected ? accent : AppTheme.secondaryText,
            padding: EdgeInsets.symmetric(horizontal: wide ? 10 : AppSpace.xs),
            minimumSize: Size(wide ? double.infinity : 64, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ).copyWith(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return BorderSide(color: accent, width: 1.2);
              }
              return BorderSide.none;
            }),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return accent.withValues(alpha: 0.12);
              }
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)) {
                return AppTheme.hover.withValues(alpha: 0.62);
              }
              return Colors.transparent;
            }),
          ),
    );

    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.quick),
        margin: wide
            ? const EdgeInsets.only(bottom: 2)
            : const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          border: wide
              ? Border(
                  left: BorderSide(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                )
              : Border(
                  bottom: BorderSide(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                ),
        ),
        child: button,
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, AppSpace.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(section.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              section.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      Expanded(
        child: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppMotion.standard),
          reverseDuration: AppMotion.duration(context, AppMotion.quick),
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          transitionBuilder: (child, animation) {
            if (AppMotion.reduce(context)) return child;
            final transition = CurvedAnimation(
              parent: animation,
              curve: AppMotion.enter,
              reverseCurve: AppMotion.exit,
            );
            return FadeTransition(
              opacity: transition,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.025),
                  end: Offset.zero,
                ).animate(transition),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey<_SettingsSection>(section),
            child: switch (section) {
              _SettingsSection.appearance => _AppearanceSettings(
                controller: controller,
                compactViewport: compactViewport,
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
              _SettingsSection.shortcuts => const _ShortcutsSettings(),
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
  );
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.controller,
    required this.compactViewport,
  });

  final PlayerController controller;
  final bool compactViewport;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final compact = controller.controlDensity == ControlDensity.compact;
    final settingDescription = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Control size',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AppTheme.secondaryText,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          'Compact uses smaller buttons and leaves more room for the seek bar.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          'Changes apply immediately and are remembered.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
    final selector = SegmentedButton<ControlDensity>(
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
          return states.contains(WidgetState.selected) ? accent : AppTheme.card;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppTheme.accentForeground
              : AppTheme.secondaryText;
        }),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
        ),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(color: accent, width: 2);
          }
          return const BorderSide(color: AppTheme.border);
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      onSelectionChanged: (selection) {
        controller.setControlDensity(selection.first);
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 520;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            18,
            compactViewport ? 6 : 14,
            18,
            compactViewport ? AppSpace.xs : 18,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stacked)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    settingDescription,
                    const SizedBox(height: 10),
                    selector,
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: settingDescription),
                    const SizedBox(width: 12),
                    selector,
                  ],
                ),
              SizedBox(height: compactViewport ? 8 : 18),
              Container(
                padding: EdgeInsets.all(
                  compactViewport ? AppSpace.xs : AppSpace.sm,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live preview',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppTheme.secondaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: compactViewport ? 6 : 10),
                    ExcludeSemantics(
                      child: _ControlBarPreview(
                        compact: compact,
                        compactViewport: compactViewport,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
    final accent = Theme.of(context).colorScheme.primary;
    final buttonSize = compact ? 32.0 : 44.0;
    final iconSize = compact ? 18.0 : 22.0;
    final previewHeight = compactViewport
        ? (compact ? 66.0 : 86.0)
        : (compact ? 148.0 : 168.0);
    final barHeight = compact
        ? (compactViewport ? 50.0 : 60.0)
        : (compactViewport ? 70.0 : 88.0);

    return Container(
      key: const ValueKey('control-density-preview'),
      height: previewHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: AppTheme.border),
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
                size: compactViewport ? 16 : 18,
                color: AppTheme.muted.withValues(alpha: 0.32),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: barHeight,
              color: AppTheme.surface,
              padding: EdgeInsets.fromLTRB(
                compact ? 8 : (compactViewport ? 14 : 22),
                compact
                    ? (compactViewport ? 4 : 8)
                    : (compactViewport ? 8 : 16),
                compact ? 8 : (compactViewport ? 14 : 22),
                compact
                    ? (compactViewport ? 4 : 6)
                    : (compactViewport ? 8 : 12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(
                    value: 0.38,
                    minHeight: compact ? 4 : 3,
                    backgroundColor: AppTheme.border,
                    color: accent,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(AppRadii.control),
                    ),
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
                              color: AppTheme.secondaryText,
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
                                color: AppTheme.accentForeground,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.skip_next_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.volume_up_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: compact ? 52 : (compactViewport ? 56 : 72),
                              child: const LinearProgressIndicator(
                                value: 0.7,
                                minHeight: 3,
                                backgroundColor: AppTheme.border,
                                color: AppTheme.secondaryText,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(AppRadii.control),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              Icons.queue_music_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.fullscreen_rounded,
                              size: iconSize,
                              color: AppTheme.secondaryText,
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

class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings({
    required this.controller,
    required this.pickSubtitle,
  });

  final PlayerController controller;
  final Future<String?> Function() pickSubtitle;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.lg,
      20,
      AppSpace.lg,
      AppSpace.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Shuffle'),
          subtitle: const Text('Play queued videos in a shuffled order'),
          value: controller.shuffle,
          onChanged: (_) => unawaited(controller.toggleShuffle()),
        ),
        const Divider(height: 1),
        SwitchListTile.adaptive(
          key: const ValueKey('save-network-urls-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Save network URLs between sessions'),
          subtitle: const Text(
            'Stores complete stream URLs, including any tokens they carry, in '
            'this computer\'s session files so network videos stay in the queue '
            'and history. Off by default; local files are always remembered. '
            'Switching this off removes stored URLs.',
          ),
          value: controller.saveNetworkUrls,
          onChanged: (value) => unawaited(controller.setSaveNetworkUrls(value)),
        ),
        const Divider(height: 1),
        const Divider(height: 24),
        _DropdownSetting<double>(
          icon: Icons.speed_rounded,
          label: 'Playback speed',
          value: _nearestRate(controller.rate),
          items: const <double>[0.5, 0.75, 1, 1.25, 1.5, 2]
              .map(
                (rate) => DropdownMenuItem(
                  value: rate,
                  child: Text(rate == 1 ? 'Normal' : '$rate×'),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) unawaited(controller.setRate(value));
          },
        ),
        const Divider(height: 1),
        _DropdownSetting<String>(
          icon: Icons.repeat_rounded,
          label: 'Repeat',
          value: controller.repeatMode,
          items: const [
            DropdownMenuItem(value: 'off', child: Text('Off')),
            DropdownMenuItem(value: 'all', child: Text('Queue')),
            DropdownMenuItem(value: 'one', child: Text('Current video')),
          ],
          onChanged: (value) {
            if (value != null) unawaited(_setRepeat(value));
          },
        ),
        const SizedBox(height: 24),
        const _SectionHeading(title: 'Tracks'),
        _TrackSetting<AudioTrack>(
          icon: Icons.audiotrack_rounded,
          label: 'Audio',
          tracks: controller.audioTracks,
          selected: controller.currentAudioTrack,
          trackLabel: (track) =>
              _trackLabel(track.id, track.title, track.language),
          onSelected: (track) => unawaited(controller.setAudioTrack(track)),
        ),
        const Divider(height: 1),
        _TrackSetting<SubtitleTrack>(
          icon: Icons.subtitles_rounded,
          label: 'Subtitles',
          tracks: controller.subtitleTracks,
          selected: controller.currentSubtitleTrack,
          trackLabel: (track) =>
              _trackLabel(track.id, track.title, track.language),
          onSelected: (track) => unawaited(controller.setSubtitleTrack(track)),
        ),
        const Divider(height: 1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          minTileHeight: 48,
          leading: const Icon(Icons.note_add_outlined),
          title: const Text('Load subtitle file'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            Navigator.of(context).pop();
            final path = await pickSubtitle();
            if (path == null || path.isEmpty) return;
            try {
              await controller.loadSubtitle(path);
            } catch (_) {
              // PlayerController reports playback errors in the main view.
            }
          },
        ),
      ],
    ),
  );

  Future<void> _setRepeat(String target) async {
    for (var i = 0; i < 3 && controller.repeatMode != target; i++) {
      await controller.cycleRepeat();
    }
  }
}

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
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.lg,
      20,
      AppSpace.lg,
      AppSpace.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(title: 'Video quality'),
        _DropdownSetting<PlaybackQualityPreset>(
          icon: Icons.high_quality_rounded,
          label: 'Quality preset',
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
        Padding(
          padding: const EdgeInsets.only(left: 33, bottom: AppSpace.xxs),
          child: Text(
            switch (_draft.qualityPreset) {
              PlaybackQualityPreset.performance =>
                'Uses faster scaling for lower GPU load.',
              PlaybackQualityPreset.balanced =>
                'Balances scaling detail and playback cost.',
              PlaybackQualityPreset.quality =>
                'Uses sharper scaling and debanding; GPU load may increase.',
            },
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
          ),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Prefer hardware decoding'),
          subtitle: const Text(
            'Use a supported GPU decoder when available. Turn off to use the '
            'software decoder.',
          ),
          value: _draft.preferHardwareDecoding,
          onChanged: (value) =>
              _commit(_draft.copyWith(preferHardwareDecoding: value)),
        ),
        const SizedBox(height: 8),
        const _SectionHeading(title: 'Picture'),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-brightness'),
          label: 'Brightness',
          value: _draft.brightness,
          min: -100,
          max: 100,
          divisions: 200,
          formatValue: _colorValue,
          onChanged: (value) =>
              _changeDraft(_draft.copyWith(brightness: value)),
          onChangeEnd: (value) => _commit(_draft.copyWith(brightness: value)),
        ),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-contrast'),
          label: 'Contrast',
          value: _draft.contrast,
          min: -100,
          max: 100,
          divisions: 200,
          formatValue: _colorValue,
          onChanged: (value) => _changeDraft(_draft.copyWith(contrast: value)),
          onChangeEnd: (value) => _commit(_draft.copyWith(contrast: value)),
        ),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-saturation'),
          label: 'Saturation',
          value: _draft.saturation,
          min: -100,
          max: 100,
          divisions: 200,
          formatValue: _colorValue,
          onChanged: (value) =>
              _changeDraft(_draft.copyWith(saturation: value)),
          onChangeEnd: (value) => _commit(_draft.copyWith(saturation: value)),
        ),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-gamma'),
          label: 'Gamma',
          value: _draft.gamma,
          min: -100,
          max: 100,
          divisions: 200,
          formatValue: _colorValue,
          onChanged: (value) => _changeDraft(_draft.copyWith(gamma: value)),
          onChangeEnd: (value) => _commit(_draft.copyWith(gamma: value)),
        ),
        const SizedBox(height: 8),
        const _SectionHeading(title: 'Timing'),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-audio-delay'),
          label: 'Audio delay',
          value: _draft.audioDelaySeconds,
          min: -10,
          max: 10,
          divisions: 200,
          formatValue: _secondsValue,
          onChanged: (value) =>
              _changeDraft(_draft.copyWith(audioDelaySeconds: value)),
          onChangeEnd: (value) =>
              _commit(_draft.copyWith(audioDelaySeconds: value)),
        ),
        _PlaybackSettingSlider(
          key: const ValueKey('playback-subtitle-delay'),
          label: 'Subtitle delay',
          value: _draft.subtitleDelaySeconds,
          min: -10,
          max: 10,
          divisions: 200,
          formatValue: _secondsValue,
          onChanged: (value) =>
              _changeDraft(_draft.copyWith(subtitleDelaySeconds: value)),
          onChangeEnd: (value) =>
              _commit(_draft.copyWith(subtitleDelaySeconds: value)),
        ),
        if (widget.controller.playbackSettingsError case final error?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Text(
              'Some settings were not confirmed by the playback engine: $error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('reset-playback-settings'),
            onPressed: () => _commit(PlaybackSettings.defaults),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Reset playback settings'),
          ),
        ),
      ],
    ),
  );
}

class _PlaybackSettingSlider extends StatelessWidget {
  const _PlaybackSettingSlider({
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

  String get displayValue => formatValue(value);
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.xxs, bottom: 2),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            Text(
              displayValue,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: AppTheme.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
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
            label: displayValue,
            semanticFormatterCallback: (value) =>
                '$label ${formatValue(value)}',
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    ),
  );
}

String _colorValue(double value) =>
    value == 0 ? '0' : '${value > 0 ? '+' : ''}${value.toStringAsFixed(0)}';

String _secondsValue(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} s';

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
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          20,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeading(title: 'Opening files'),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Text(
                'Choose what happens when opening new files while media is playing:',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
              ),
            ),
            RadioGroup<OpenBehaviorPreference>(
              groupValue: currentOpenBehavior,
              onChanged: (preference) {
                if (preference != null) {
                  unawaited(preferences.setOpenBehavior(preference));
                }
              },
              child: Column(
                children: [
                  RadioListTile<OpenBehaviorPreference>(
                    key: const ValueKey('open-behavior-keep-playing'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Keep playing and add to queue'),
                    subtitle: const Text(
                      'Appends opened media to the queue without interrupting current playback',
                    ),
                    value: OpenBehaviorPreference.keepPlayingAndEnqueue,
                  ),
                  RadioListTile<OpenBehaviorPreference>(
                    key: const ValueKey('open-behavior-play-now'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Play new files now'),
                    subtitle: const Text(
                      'Immediately interrupts and plays newly opened files',
                    ),
                    value: OpenBehaviorPreference.playNewFilesNow,
                  ),
                  RadioListTile<OpenBehaviorPreference>(
                    key: const ValueKey('open-behavior-ask-every-time'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Ask every time'),
                    subtitle: const Text(
                      'Prompts for action each time media is opened during playback',
                    ),
                    value: OpenBehaviorPreference.askEveryTime,
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
            const _SectionHeading(title: 'Power & system'),
            SwitchListTile.adaptive(
              key: const ValueKey('keep-awake-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep computer awake during playback'),
              subtitle: const Text(
                'Prevents screen sleep and system standby while video playback is active',
              ),
              value: preferences.preferences.keepAwakeDuringPlayback,
              onChanged: (value) => unawaited(preferences.setKeepAwake(value)),
            ),
            const Divider(height: 28),
            const _SectionHeading(title: 'System integration'),
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpace.xxs,
                bottom: AppSpace.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'File associations',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Manage file type associations and autoplay settings in the operating system',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppTheme.secondaryText),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('default-apps-button'),
                    onPressed: () =>
                        unawaited(desktopIntegration.openDefaultAppsSettings()),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Default apps'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Folder management in the main application shell.
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: libraryRepository,
    builder: (context, _) {
      final folders = libraryRepository.folders;
      final status = libraryRepository.scanStatus;
      final accent = Theme.of(context).colorScheme.primary;

      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          20,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('add-folder-button'),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Add folder'),
                  onPressed: !libraryRepository.isReady
                      ? null
                      : () async {
                          try {
                            final path = await (pickDirectory != null
                                ? pickDirectory!()
                                : getDirectoryPath());
                            if (path != null && path.isNotEmpty) {
                              await libraryRepository.addFolder(path);
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not add the folder. Try again.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const ValueKey('rescan-all-button'),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Rescan all folders'),
                  onPressed: libraryRepository.isReady
                      ? () => unawaited(libraryRepository.rescanAll())
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              key: const ValueKey('library-scan-progress'),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(AppRadii.control),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 6,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (status.isScanning) ...[
                            Icon(Icons.sync_rounded, size: 16, color: accent),
                            const SizedBox(width: 8),
                            Text(
                              'Scanning library…',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: accent,
                                  ),
                            ),
                          ] else ...[
                            const Icon(
                              Icons.check_circle_outline_rounded,
                              size: 16,
                              color: AppTheme.secondaryText,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Scan idle',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppTheme.secondaryText),
                            ),
                          ],
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Discovered: ${status.discoveredCount}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                          const Text(' · '),
                          Text(
                            'Enriched: ${status.enrichedCount}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (status.isScanning) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: status.totalToEnrich > 0
                          ? (status.enrichedCount / status.totalToEnrich).clamp(
                              0.0,
                              1.0,
                            )
                          : 0.0,
                      backgroundColor: AppTheme.border,
                      color: accent,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SectionHeading(title: 'Library folders'),
            if (folders.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                alignment: Alignment.center,
                child: Column(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 36,
                      color: AppTheme.secondaryText.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No folders added yet',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.secondaryText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add a media folder to index video and audio files.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.secondaryText.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: folders.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      folder.isAvailable
                          ? Icons.folder_rounded
                          : Icons.folder_off_rounded,
                      color: folder.isAvailable
                          ? accent
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      folder.path,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: folder.isAvailable
                            ? AppTheme.primaryText
                            : AppTheme.secondaryText,
                      ),
                    ),
                    subtitle: Row(
                      children: [
                        Text(
                          folder.isAvailable ? 'Available' : 'Unavailable',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: folder.isAvailable
                                    ? AppTheme.secondaryText
                                    : Theme.of(context).colorScheme.error,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        const Text(' · '),
                        Text(
                          '${folder.fileCount} ${folder.fileCount == 1 ? 'file' : 'files'}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppTheme.secondaryText),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      key: ValueKey('remove-folder-${folder.path}'),
                      tooltip: 'Remove folder',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: () => unawaited(
                        libraryRepository.removeFolder(folder.path),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      );
    },
  );
}

class _ShortcutsSettings extends StatelessWidget {
  const _ShortcutsSettings();

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.lg,
      20,
      AppSpace.lg,
      AppSpace.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(title: 'Video controls'),
        const SizedBox(height: 8),
        const _ShortcutRow(
          keys: 'Mouse wheel over video',
          action: 'Adjust volume',
        ),
        const _ShortcutRow(keys: 'Click video', action: 'Toggle playback'),
        const _ShortcutRow(
          keys: 'Double-click video',
          action: 'Toggle fullscreen',
        ),
        const _ShortcutRow(
          keys: 'Right-click video',
          action: 'Open player menu',
        ),
        const _ShortcutRow(keys: 'M', action: 'Mute or unmute'),
        const _ShortcutRow(keys: 'F', action: 'Toggle fullscreen'),
        const _ShortcutRow(keys: 'Shift + F10', action: 'Open player menu'),
        const SizedBox(height: 18),
        const _SectionHeading(title: 'Keyboard shortcuts'),
        const SizedBox(height: 8),
        const _ShortcutRow(keys: 'Space', action: 'Play or pause'),
        const _ShortcutRow(keys: 'Hold Space', action: 'Play at 2× while held'),
        const _ShortcutRow(
          keys: '←  →',
          action: 'Seek 5 seconds (or adjust focused slider)',
        ),
        const _ShortcutRow(
          keys: '↑  ↓',
          action: 'Change volume (or adjust focused slider)',
        ),
        const _ShortcutRow(keys: 'Ctrl + O', action: 'Open files'),
        const _ShortcutRow(keys: 'Ctrl + L', action: 'Open URL'),
        const _ShortcutRow(keys: 'P', action: 'Show or hide the queue'),
        const _ShortcutRow(keys: 'F11', action: 'Toggle fullscreen'),
        const _ShortcutRow(
          keys: 'Esc',
          action: 'Dismiss queue drawer or exit fullscreen',
        ),
        const _ShortcutRow(
          keys: 'Delete',
          action: 'Remove the selected queue item',
        ),
      ],
    ),
  );
}

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
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.lg,
      20,
      AppSpace.lg,
      AppSpace.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([updates, engineUpdates]),
          builder: (context, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: 56,
            leading: const Icon(Icons.system_update_alt_rounded),
            title: const Text('Updates & about'),
            subtitle: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.quick),
              transitionBuilder: (child, animation) {
                if (AppMotion.reduce(context)) {
                  return FadeTransition(opacity: animation, child: child);
                }
                final transition = CurvedAnimation(
                  parent: animation,
                  curve: AppMotion.enter,
                  reverseCurve: AppMotion.exit,
                );
                return FadeTransition(
                  opacity: transition,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.04),
                      end: Offset.zero,
                    ).animate(transition),
                    child: child,
                  ),
                );
              },
              child: Text(
                _updateSummary(),
                key: ValueKey<String>(
                  'update-summary-${updates.status}-${engineUpdates.status}',
                ),
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
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: _AboutRow(label: 'Playback engine', value: engineVersion),
        ),
        _AboutRow(label: 'Engine source', value: engineUpdates.sourceLabel),
      ],
    ),
  );

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

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: AppTheme.secondaryText,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _DropdownSetting<T> extends StatelessWidget {
  const _DropdownSetting({
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
  Widget build(BuildContext context) => Semantics(
    label: '$label, selected $value',
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.secondaryText, size: 21),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(AppRadii.control),
            items: items,
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );
}

class _TrackSetting<T> extends StatelessWidget {
  const _TrackSetting({
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
    T? selectedValue;
    for (final track in tracks) {
      if (track == selected) {
        selectedValue = track;
        break;
      }
    }

    final currentDisplay = selectedValue != null
        ? trackLabel(selectedValue)
        : 'Unavailable';

    return Semantics(
      label: '$label track, selected $currentDisplay',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.secondaryText, size: 21),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
            DropdownButton<T>(
              value: selectedValue,
              hint: const Text('Unavailable'),
              underline: const SizedBox.shrink(),
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
          ],
        ),
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

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 142,
            child: Text(
              keys,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(action, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 132,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

double _nearestRate(double rate) => const [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);

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
