import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../domain/models/playback_settings.dart';
import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../player_controller.dart';
import 'floating_video_settings_display.dart';
import 'floating_video_settings_tabs.dart';

enum VideoSettingsTab { audioSubs, picture, playback, display }

/// A compact, elegant floating settings panel overlaid directly on the video.
///
/// Designed specifically for video view: allows quick tweaking of audio tracks,
/// subtitle sync, picture calibration, playback speed, and display options
/// without obscuring or leaving the active video.
class FloatingVideoSettings extends StatefulWidget {
  const FloatingVideoSettings({
    super.key,
    required this.controller,
    this.appPreferences,
    required this.pickSubtitle,
    required this.onClose,
    this.onOpenFullSettings,
  });

  final PlayerController controller;
  final AppPreferencesRepository? appPreferences;
  final Future<String?> Function() pickSubtitle;
  final VoidCallback onClose;
  final VoidCallback? onOpenFullSettings;

  @override
  State<FloatingVideoSettings> createState() => _FloatingVideoSettingsState();
}

class _FloatingVideoSettingsState extends State<FloatingVideoSettings> {
  VideoSettingsTab _currentTab = VideoSettingsTab.audioSubs;
  late PlaybackSettings _draft = widget.controller.playbackSettings;

  /// The last value this panel pushed to the controller, so an echo of our
  /// own commit is not mistaken for an external edit.
  PlaybackSettings? _lastSent;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _draft = widget.controller.playbackSettings;
  }

  @override
  void didUpdateWidget(covariant FloatingVideoSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
    _adoptControllerSettings();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  /// Keeps the draft in step with edits made elsewhere (full settings,
  /// hotkeys) so sliders never show stale values.
  void _handleControllerChanged() {
    if (!mounted) return;
    _adoptControllerSettings();
  }

  void _adoptControllerSettings() {
    final current = widget.controller.playbackSettings;
    if (current == _lastSent || current == _draft) return;
    setState(() {
      _draft = current;
      _lastSent = current;
    });
  }

  void _changeDraft(PlaybackSettings value) {
    setState(() => _draft = value.normalized());
  }

  void _commit(PlaybackSettings value) {
    final normalized = value.normalized();
    setState(() {
      _draft = normalized;
      _lastSent = normalized;
    });
    unawaited(widget.controller.setPlaybackSettings(normalized));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: FocusScope(
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: const SizedBox.expand(),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final panelWidth = math.min(
                  390.0,
                  math.max(280.0, constraints.maxWidth - 24),
                );
                final panelHeight = math.min(
                  580.0,
                  math.max(300.0, constraints.maxHeight - 40),
                );

                return Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      right: 20,
                      top: 16,
                      bottom: 16,
                    ),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.0, end: 1.0),
                      duration: AppMotion.duration(context, AppMotion.standard),
                      curve: AppMotion.enter,
                      builder: (context, progress, child) {
                        final reduce = AppMotion.reduce(context);
                        return Opacity(
                          opacity: progress,
                          child: Transform.translate(
                            offset: reduce
                                ? Offset.zero
                                : Offset((1.0 - progress) * 20.0, 0),
                            child: child,
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                          child: Container(
                            width: panelWidth,
                            height: panelHeight,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xE8141519)
                                  : const Color(0xF2FFFFFF),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.1),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  blurRadius: 28,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildHeader(theme, accent),
                                _buildTabBar(theme, accent),
                                Expanded(
                                  child: ListenableBuilder(
                                    listenable: widget.controller,
                                    builder: (context, _) =>
                                        _buildTabContent(theme, accent),
                                  ),
                                ),
                                if (widget.onOpenFullSettings != null)
                                  _buildFooter(theme, accent),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Color accent) {
    return Container(
      padding: const EdgeInsets.only(left: 14, right: 8, top: 10, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.tune_rounded, size: 16, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Video Settings',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close settings (Esc)',
            iconSize: 18,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            onPressed: widget.onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme, Color accent) {
    final tabs = [
      (VideoSettingsTab.audioSubs, Icons.subtitles_rounded, 'Audio & Subs'),
      (VideoSettingsTab.picture, Icons.tune_rounded, 'Picture'),
      (
        VideoSettingsTab.playback,
        Icons.play_circle_outline_rounded,
        'Playback',
      ),
      (VideoSettingsTab.display, Icons.palette_outlined, 'Display'),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(AppRadii.control + 2),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          for (final (tab, icon, label) in tabs)
            Expanded(
              child: _TabPill(
                icon: icon,
                label: label,
                selected: _currentTab == tab,
                accent: accent,
                onTap: () => setState(() => _currentTab = tab),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabContent(ThemeData theme, Color accent) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: switch (_currentTab) {
        VideoSettingsTab.audioSubs => FloatingAudioSubsTab(
          controller: widget.controller,
          draft: _draft,
          pickSubtitle: widget.pickSubtitle,
          onChangeDraft: _changeDraft,
          onCommit: _commit,
        ),
        VideoSettingsTab.picture => FloatingPictureTab(
          draft: _draft,
          onChangeDraft: _changeDraft,
          onCommit: _commit,
        ),
        VideoSettingsTab.playback => FloatingPlaybackTab(
          controller: widget.controller,
          draft: _draft,
          accent: accent,
          onCommit: _commit,
        ),
        VideoSettingsTab.display => FloatingDisplayTab(
          controller: widget.controller,
          appPreferences: widget.appPreferences,
        ),
      },
    );
  }

  Widget _buildFooter(ThemeData theme, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'In-video controls',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('floating-settings-full-button'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            onPressed: () {
              widget.onClose();
              widget.onOpenFullSettings?.call();
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 14),
            label: const Text('Full settings', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected ? accent : theme.colorScheme.onSurfaceVariant;
    final bg = selected ? accent.withValues(alpha: 0.16) : Colors.transparent;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.45)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(height: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: foreground,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
