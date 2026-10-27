import 'package:flutter/material.dart';

import '../../../domain/models/media_entry.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import 'screen_play_mark.dart';

class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({
    super.key,
    required this.recent,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onOpenRecent,
    this.error,
    this.isDragging = false,
    this.onOpenLibrary,
  });

  final List<MediaEntry> recent;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final ValueChanged<MediaEntry> onOpenRecent;
  final String? error;
  final bool isDragging;
  final VoidCallback? onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final horizontalPadding = compact ? 22.0 : 38.0;

        return DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.background,
            border: isDragging ? Border.all(color: accent, width: 2) : null,
          ),
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: AppMotionReveal(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        compact ? 30 : 42,
                        horizontalPadding,
                        34,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HomeHero(
                            compact: compact,
                            isDragging: isDragging,
                            onOpenFiles: onOpenFiles,
                            onOpenUrl: onOpenUrl,
                            onOpenLibrary: onOpenLibrary,
                          ),
                          if (error != null && error!.trim().isNotEmpty) ...[
                            const SizedBox(height: 24),
                            _ErrorMessage(message: error!),
                          ],
                          if (recent.isNotEmpty) ...[
                            const SizedBox(height: 34),
                            _RecentSection(
                              entries: recent.take(4).toList(growable: false),
                              onOpenRecent: onOpenRecent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeHero extends StatelessWidget {
  const _HomeHero({
    required this.compact,
    required this.isDragging,
    required this.onOpenFiles,
    required this.onOpenUrl,
    this.onOpenLibrary,
  });

  final bool compact;
  final bool isDragging;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final VoidCallback? onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final copy = _HeroCopy(
      isDragging: isDragging,
      onOpenFiles: onOpenFiles,
      onOpenUrl: onOpenUrl,
      onOpenLibrary: onOpenLibrary,
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ScreenPlayMark(width: 94, height: 72),
          const SizedBox(height: 18),
          copy,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: copy),
        const SizedBox(width: 28),
        const ScreenPlayMark(width: 154, height: 118),
      ],
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({
    required this.isDragging,
    required this.onOpenFiles,
    required this.onOpenUrl,
    this.onOpenLibrary,
  });

  final bool isDragging;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final VoidCallback? onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isDragging ? 'Drop to start playback' : 'Open a video',
          style: textTheme.headlineMedium?.copyWith(
            fontSize: AppType.display,
            height: 1.08,
            letterSpacing: -1.1,
          ),
        ),
        const SizedBox(height: 11),
        Text(
          isDragging
              ? 'Release the file anywhere in the player.'
              : 'Choose a file from your computer or paste a stream link.',
          style: textTheme.bodyLarge?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            Tooltip(
              message: 'Open video files (Ctrl+O)',
              child: FilledButton.icon(
                key: const ValueKey('open-files'),
                onPressed: onOpenFiles,
                icon: const Icon(Icons.folder_open_rounded, size: 19),
                label: const Text('Open files'),
              ),
            ),
            Tooltip(
              message: 'Open a stream URL (Ctrl+L)',
              child: OutlinedButton.icon(
                key: const ValueKey('open-url'),
                onPressed: onOpenUrl,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Open URL'),
              ),
            ),
            if (onOpenLibrary != null)
              Tooltip(
                message: 'Browse media library (Ctrl+M)',
                child: OutlinedButton.icon(
                  key: const ValueKey('open-library'),
                  onPressed: onOpenLibrary,
                  icon: const Icon(Icons.video_library_rounded, size: 18),
                  label: const Text('Media library'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.file_download_outlined, size: 16),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                'Drop files anywhere in the player',
                style: textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.entries, required this.onOpenRecent});

  final List<MediaEntry> entries;
  final ValueChanged<MediaEntry> onOpenRecent;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent media',
          style: textTheme.titleMedium?.copyWith(
            color: AppTheme.secondaryText,
            fontSize: AppType.body,
          ),
        ),
        const SizedBox(height: 10),
        for (var index = 0; index < entries.length; index++) ...[
          if (index > 0)
            Divider(height: 1, color: AppTheme.border.withValues(alpha: 0.7)),
          _RecentEntry(
            key: ValueKey(entries[index].id),
            entry: entries[index],
            onTap: () => onOpenRecent(entries[index]),
          ),
        ],
      ],
    );
  }
}

class _RecentEntry extends StatefulWidget {
  const _RecentEntry({super.key, required this.entry, required this.onTap});

  final MediaEntry entry;
  final VoidCallback onTap;

  @override
  State<_RecentEntry> createState() => _RecentEntryState();
}

class _RecentEntryState extends State<_RecentEntry> {
  bool _hasFocus = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final entry = widget.entry;
    final durationMs = entry.duration.inMilliseconds;
    final positionMs = entry.position.inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final hasResume = entry.position > Duration.zero;
    final detail = hasResume
        ? 'Resume at ${_formatTime(entry.position)}'
        : 'Played ${_dateLabel(entry.lastPlayed)}';
    final label = hasResume
        ? 'Play ${entry.title}, resume at ${_formatTime(entry.position)}'
        : 'Play ${entry.title}, last played ${_dateLabel(entry.lastPlayed)}';

    final row = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (value) {
          if (_hasFocus != value) setState(() => _hasFocus = value);
        },
        onHover: (value) {
          if (_isHovered != value) setState(() => _isHovered = value);
        },
        borderRadius: BorderRadius.circular(AppRadii.control),
        focusColor: accent.withValues(alpha: 0.08),
        hoverColor: AppTheme.hover.withValues(alpha: 0.42),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: _hasFocus
                  ? accent.withValues(alpha: 0.6)
                  : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: 10,
          ),
          child: Row(
            children: [
              const Icon(Icons.play_arrow_rounded, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 3),
                    Text(detail, style: Theme.of(context).textTheme.bodySmall),
                    if (durationMs > 0 && hasResume) ...[
                      const SizedBox(height: 7),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.square),
                        child: LinearProgressIndicator(
                          value: progress.toDouble(),
                          minHeight: 2.5,
                          backgroundColor: AppTheme.border,
                          color: accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 19),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: AppMotion.reduce(context)
          ? row
          : AnimatedScale(
              scale: _hasFocus || _isHovered ? 1.005 : 1,
              duration: AppMotion.duration(context, AppMotion.quick),
              curve: AppMotion.enter,
              child: row,
            ),
    );
  }

  static String _formatTime(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  static String _dateLabel(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[value.month - 1]} ${value.day}';
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.only(left: AppSpace.sm, top: 2, bottom: 2),
    decoration: const BoxDecoration(
      border: Border(left: BorderSide(color: AppTheme.danger, width: 2)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.error_outline_rounded,
          color: AppTheme.danger,
          size: 18,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
          ),
        ),
      ],
    ),
  );
}
