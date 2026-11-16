import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import '../../../../domain/models/graphics_settings.dart';
import '../../../core/app_theme.dart';
import '../../../core/toast/app_toast.dart';
import 'settings_shared_widgets.dart';

class DesktopIntegrationSettingsSection extends StatefulWidget {
  const DesktopIntegrationSettingsSection({
    super.key,
    required this.preferences,
    required this.desktopIntegration,
  });

  final AppPreferencesRepository preferences;
  final DesktopIntegrationService desktopIntegration;

  @override
  State<DesktopIntegrationSettingsSection> createState() =>
      _DesktopIntegrationSettingsSectionState();
}

class _DesktopIntegrationSettingsSectionState
    extends State<DesktopIntegrationSettingsSection> {
  WindowsRegistrationStatus? _associationStatus;
  bool _registering = false;

  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    _refreshAssociationStatus();
  }

  @override
  void didUpdateWidget(covariant DesktopIntegrationSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.desktopIntegration != widget.desktopIntegration) {
      _refreshAssociationStatus();
    }
  }

  Future<void> _refreshAssociationStatus() async {
    if (!_isWindows) return;
    final status = await widget.desktopIntegration
        .getWindowsAssociationStatus();
    if (!mounted) return;
    setState(() => _associationStatus = status);
  }

  Future<void> _registerAssociations() async {
    if (_registering) return;
    setState(() => _registering = true);
    var registered = false;
    try {
      registered = await widget.desktopIntegration.registerWindowsAssociations(
        force: true,
      );
      await _refreshAssociationStatus();
    } finally {
      if (mounted) setState(() => _registering = false);
    }
    if (!mounted) return;
    AppToast.show(
      context,
      registered
          ? 'File associations registered. You can now pick Mpvson in Windows Default Apps.'
          : 'Could not update Windows file associations.',
      tone: registered ? AppToastTone.success : AppToastTone.danger,
    );
  }

  String _associationSubtitle(WindowsRegistrationStatus? status) {
    if (!_isWindows || status == null) {
      return 'Configure default video/audio player file extensions in OS settings.';
    }
    if (status.isRegistered &&
        status.matchesTarget &&
        status.hasRegisteredApplication) {
      return 'Registered with Windows 10/11 Default Apps for this executable.';
    }
    if (status.isRegistered && status.otherInstallExists) {
      return 'Currently registered to another Mpvson location (${status.registeredExePath}).';
    }
    return 'Register Mpvson with Windows so it appears in Default Apps and Open With.';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.preferences,
    builder: (context, _) {
      final prefs = widget.preferences.preferences;
      final currentOpenBehavior = prefs.openBehavior;
      final graphics = prefs.graphics;
      final theme = Theme.of(context);
      final status = _associationStatus;
      final isFullyRegistered =
          status != null &&
          status.isRegistered &&
          status.matchesTarget &&
          status.hasRegisteredApplication;

      return SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.preferences.saveError != null) ...[
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
                      onPressed: () => unawaited(widget.preferences.flush()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
            SettingsCardGroup(
              title: 'Opening media files',
              description:
                  'Choose behavior when files are opened while video is playing.',
              children: [
                RadioGroup<OpenBehaviorPreference>(
                  groupValue: currentOpenBehavior,
                  onChanged: (val) {
                    if (val != null) {
                      unawaited(widget.preferences.setOpenBehavior(val));
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-keep-playing'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        title: const Text('Keep playing and add to queue'),
                        subtitle: const Text(
                          'Appends opened media without interrupting the active stream.',
                        ),
                        value: OpenBehaviorPreference.keepPlayingAndEnqueue,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-play-now'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        title: const Text('Play new files immediately'),
                        subtitle: const Text(
                          'Switches playback to the new file right away.',
                        ),
                        value: OpenBehaviorPreference.playNewFilesNow,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-ask-every-time'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
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
            SettingsCardGroup(
              title: 'Power & Graphics',
              children: [
                SettingsSwitchTile(
                  key: const ValueKey('keep-awake-switch'),
                  icon: Icons.coffee_rounded,
                  title: 'Prevent computer sleep during playback',
                  subtitle:
                      'Inhibits screen savers and system standby while video is active.',
                  value: prefs.keepAwakeDuringPlayback,
                  onChanged: (val) =>
                      unawaited(widget.preferences.setKeepAwake(val)),
                ),
                if (_isWindows)
                  DropdownSettingTile<GpuPreferenceMode>(
                    key: const ValueKey('gpu-preference-dropdown'),
                    icon: Icons.memory_rounded,
                    label: 'Preferred GPU (next launch)',
                    value: graphics.preferredGpu,
                    items: GpuPreferenceMode.values
                        .map(
                          (mode) => DropdownMenuItem<GpuPreferenceMode>(
                            value: mode,
                            child: Text(mode.label),
                          ),
                        )
                        .toList(),
                    onChanged: (mode) {
                      if (mode != null) {
                        unawaited(
                          widget.preferences.setGraphicsSettings(
                            graphics.copyWith(preferredGpu: mode),
                          ),
                        );
                      }
                    },
                  ),
                SettingsSwitchTile(
                  key: const ValueKey('trim-on-minimize-switch'),
                  icon: Icons.compress_rounded,
                  title: 'Trim video memory when minimized',
                  subtitle:
                      'Releases unused decoded frames and video surface memory in the background.',
                  value: graphics.trimOnMinimize,
                  onChanged: (val) => unawaited(
                    widget.preferences.setGraphicsSettings(
                      graphics.copyWith(trimOnMinimize: val),
                    ),
                  ),
                ),
                SettingsSwitchTile(
                  key: const ValueKey('limit-demuxer-cache-switch'),
                  icon: Icons.storage_rounded,
                  title: 'Limit demuxer cache size',
                  subtitle:
                      'Caps ahead/back stream buffering to keep memory usage predictable.',
                  value: graphics.limitDemuxerCache,
                  onChanged: (val) => unawaited(
                    widget.preferences.setGraphicsSettings(
                      graphics.copyWith(limitDemuxerCache: val),
                    ),
                  ),
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'System integration',
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
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
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Default app associations',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _associationSubtitle(status),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          if (_isWindows)
                            OutlinedButton.icon(
                              key: const ValueKey(
                                'register-associations-button',
                              ),
                              onPressed: _registering
                                  ? null
                                  : _registerAssociations,
                              icon: Icon(
                                isFullyRegistered
                                    ? Icons.verified_outlined
                                    : Icons.app_registration_rounded,
                                size: 15,
                              ),
                              label: Text(
                                _registering
                                    ? 'Registering…'
                                    : isFullyRegistered
                                    ? 'Re-register'
                                    : 'Register',
                              ),
                            ),
                          OutlinedButton.icon(
                            key: const ValueKey('default-apps-button'),
                            onPressed: () async {
                              await widget.desktopIntegration
                                  .openDefaultAppsSettings();
                              await _refreshAssociationStatus();
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 15,
                            ),
                            label: const Text('Open settings'),
                          ),
                        ],
                      ),
                    ],
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
