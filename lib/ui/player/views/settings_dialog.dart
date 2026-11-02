import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';
import '../player_controller.dart';
import 'settings/settings_dialog.dart';
import 'settings/settings_empty_fallbacks.dart';

export 'settings/settings_dialog.dart' show SettingsDialogView, SettingsSection;
export 'settings/settings_library_section.dart' show LibraryFoldersView;

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
  }) => showDialog<void>(
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
                height: AppLayout.settingsHeaderHeight,
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
}
