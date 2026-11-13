import 'dart:ffi' show Abi;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../../core/components/app_mark.dart';
import '../../../../data/services/engine_path_resolver.dart';
import '../../../../data/services/engine_update_service.dart';
import '../../../../data/services/update_service.dart';
import '../update_center_dialog.dart';
import '../update_status.dart';
import 'settings_shared_widgets.dart';

class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({
    super.key,
    required this.updates,
    required this.engineUpdates,
    required this.engineVersion,
  });

  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String engineVersion;

  void _openUpdateCenter(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box != null && box.hasSize
        ? box.localToGlobal(box.size.center(Offset.zero))
        : null;
    showMorphDialog<void>(
      context: context,
      anchor: anchor,
      builder: (_) => UpdateCenterDialog(
        updates: updates,
        engineUpdates: engineUpdates,
        engineVersion: engineVersion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero Branded Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final avatar = Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const AppMark(size: 30),
                );
                final identity = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Mpvson',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                          ),
                          child: Text(
                            'v${updates.currentVersion}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Modern desktop media player powered by mpv',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
                final updateButton = Builder(
                  builder: (buttonContext) => FilledButton.tonalIcon(
                    onPressed: () => _openUpdateCenter(buttonContext),
                    icon: const Icon(Icons.sync_rounded, size: 16),
                    label: const Text('Update center'),
                  ),
                );
                if (constraints.maxWidth < 480) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          avatar,
                          const SizedBox(width: 16),
                          Expanded(child: identity),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: updateButton,
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    avatar,
                    const SizedBox(width: 16),
                    Expanded(child: identity),
                    const SizedBox(width: 12),
                    updateButton,
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 20),

          // Software & Engine Status Group
          SettingsCardGroup(
            title: 'Software & Engine',
            children: [
              AnimatedBuilder(
                animation: updates,
                builder: (context, _) {
                  final (statusText, statusColor) = appUpdateStatusPresentation(
                    context,
                    updates,
                  );
                  return _AboutTile(
                    icon: Icons.desktop_windows_outlined,
                    title: 'Application updates',
                    subtitle: 'In-app update checks',
                    trailing: UpdateStatusPill(
                      label: statusText,
                      color: statusColor,
                    ),
                  );
                },
              ),
              AnimatedBuilder(
                animation: engineUpdates,
                builder: (context, _) {
                  final (statusText, statusColor) =
                      engineUpdateStatusPresentation(context, engineUpdates);
                  return _AboutTile(
                    icon: Icons.memory_rounded,
                    title: 'Playback engine',
                    subtitle: _formatEngineVersion(engineVersion),
                    trailing: UpdateStatusPill(
                      label: statusText,
                      color: statusColor,
                    ),
                  );
                },
              ),
              _AboutTile(
                icon: Icons.alt_route_rounded,
                title: 'Engine channel & distribution',
                subtitle:
                    '${engineUpdates.channel.name.toUpperCase()} · ${engineUpdates.sourceLabel}',
              ),
            ],
          ),

          // System & Architecture Group
          SettingsCardGroup(
            title: 'System & Architecture',
            children: [
              _AboutTile(
                icon: Icons.speed_rounded,
                title: 'Rendering pipeline',
                subtitle: _renderingPipelineLabel(),
              ),
              const _AboutTile(
                icon: Icons.verified_user_outlined,
                title: 'Open source & license',
                subtitle: 'GPLv3 / LGPL · Built with Flutter and libmpv',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Flutter exposes no runtime query for its rasterizer backend, so report
  /// only what the app can actually detect instead of naming a pipeline.
  static String _renderingPipelineLabel() {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
    final architecture = switch (Abi.current()) {
      Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 => 'x64',
      Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 => 'ARM64',
      _ => null,
    };
    return architecture == null
        ? 'Flutter · $platform'
        : 'Flutter · $platform · $architecture';
  }

  static String _formatEngineVersion(String raw) =>
      EnginePathResolver.formatVersion(raw);
}

class _AboutTile extends StatelessWidget {
  const _AboutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
            child: Icon(
              icon,
              size: 17,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}
