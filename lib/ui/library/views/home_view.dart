import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/format.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_popup_menu_item.dart';
import '../../core/components/page_header.dart';
import '../../core/toast/app_toast.dart';
import '../../player/player_controller.dart';
import '../widgets/library_artwork.dart';

class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.recent,
    required this.repository,
    required this.controller,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onOpenRecent,
    this.onRemoveRecent,
    this.onClearRecent,
    this.isDragging = false,
  });

  final List<MediaEntry> recent;
  final MediaLibraryRepository repository;
  final PlayerController controller;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final ValueChanged<MediaEntry> onOpenRecent;
  final ValueChanged<MediaEntry>? onRemoveRecent;
  final VoidCallback? onClearRecent;
  final bool isDragging;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.palette.background,
      gradient: RadialGradient(
        center: const Alignment(0, -0.35),
        radius: 1.15,
        colors: [
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          context.palette.raisedSurface.withValues(alpha: 0.15),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ),
      border: isDragging
          ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
          : null,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const gap = 20.0;
        final compact = constraints.maxWidth < 600;
        final inset = compact ? 20.0 : 32.0;
        final contentWidth = (constraints.maxWidth - inset * 2).clamp(
          0.0,
          double.infinity,
        );
        // The opening surface is capped at 960; keep the recent grid on the
        // same measure instead of letting it run wider underneath.
        final gridWidth = math.min(contentWidth, 960.0);
        final gridInset = inset + (contentWidth - gridWidth) / 2;
        final columns = ((gridWidth + gap) / 320).ceil().clamp(1, 8);
        final tileWidth = (gridWidth - (columns - 1) * gap) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 20, inset, 32),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const PageHeader(
                          title: 'Home',
                          subtitle: 'Desktop Media Center',
                          padding: EdgeInsets.zero,
                        ),
                        const SizedBox(height: 24),
                        _DropZoneCard(
                          isDragging: isDragging,
                          onOpenFiles: onOpenFiles,
                          onOpenUrl: onOpenUrl,
                          compact: recent.isNotEmpty,
                        ),
                        if (recent.isEmpty) const _HomeEmptyGuide(),
                        if (recent.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Expanded(
                                child: Text(
                                  'Recently played',
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '${recent.length} ${recent.length == 1 ? 'item' : 'items'}',
                                style: context.palette.metadata,
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed:
                                    onClearRecent ??
                                    () {
                                      final cleared = controller.clearRecent();
                                      if (cleared.isNotEmpty &&
                                          context.mounted) {
                                        AppToast.show(
                                          context,
                                          'Recently played cleared',
                                          actionLabel: 'Undo',
                                          onAction: () => controller
                                              .restoreRecentList(cleared),
                                        );
                                      }
                                    },
                                icon: const Icon(
                                  Icons.clear_all_rounded,
                                  size: 16,
                                ),
                                label: const Text('Clear all'),
                                style: TextButton.styleFrom(
                                  foregroundColor: context.palette.mutedText,
                                  visualDensity: VisualDensity.compact,
                                  textStyle: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (recent.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(gridInset, 0, gridInset, 32),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: 24,
                    mainAxisExtent: tileWidth * 9 / 16 + textHeight + 20,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _RecentTile(
                      key: ValueKey(recent[index].id),
                      entry: recent[index],
                      controller: controller,
                      repository: repository,
                      onOpen: () => onOpenRecent(recent[index]),
                      onRemove: onRemoveRecent != null
                          ? () => onRemoveRecent!(recent[index])
                          : () {
                              final restored = controller.removeRecent(
                                recent[index],
                              );
                              if (restored != null && context.mounted) {
                                AppToast.show(
                                  context,
                                  'Removed from recently played',
                                  actionLabel: 'Undo',
                                  onAction: () => controller.restoreRecent(
                                    restored.$1,
                                    restored.$2,
                                  ),
                                );
                              }
                            },
                    ),
                    addAutomaticKeepAlives: false,
                    childCount: recent.length,
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _RecentTile extends StatefulWidget {
  const _RecentTile({
    super.key,
    required this.entry,
    required this.controller,
    required this.repository,
    required this.onOpen,
    this.onRemove,
  });
  final MediaEntry entry;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  State<_RecentTile> createState() => _RecentTileState();
}

class _RecentTileState extends State<_RecentTile> {
  ThumbnailRequestHandle? _request;
  late Future<MediaThumbnail?> _thumbnail;
  MediaThumbnail? _provisional;
  final ValueNotifier<bool> _active = ValueNotifier<bool>(false);
  bool _hovered = false;
  bool _focused = false;

  void _syncPreview() {
    _provisional = widget.controller.peekThumbnail(widget.entry);
    _thumbnail = _load();
  }

  void _setHover(bool value) {
    if (_hovered == value) return;
    _hovered = value;
    _active.value = _hovered || _focused;
  }

  void _setFocus(bool value) {
    if (_focused == value) return;
    _focused = value;
    _active.value = _hovered || _focused;
  }

  @override
  void initState() {
    super.initState();
    _syncPreview();
  }

  @override
  void didUpdateWidget(covariant _RecentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.controller != widget.controller) {
      _request?.release();
      _request = null;
      _syncPreview();
    }
  }

  Future<MediaThumbnail?> _load() async {
    try {
      _request = widget.controller.requestThumbnail(widget.entry);
      return await _request?.thumbnail;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _request?.release();
    _active.dispose();
    super.dispose();
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final entry = widget.entry;
    final hasProgress =
        entry.duration > Duration.zero && entry.position > Duration.zero;
    final accent = Theme.of(context).colorScheme.primary;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: context.palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: BorderSide(color: context.palette.border),
      ),
      items: [
        AppPopupMenuItem<String>(
          value: 'play',
          icon: Icons.play_arrow_rounded,
          iconColor: accent,
          text: hasProgress ? 'Resume' : 'Play',
        ),
        if (widget.onRemove != null) ...[
          const PopupMenuDivider(height: 1),
          AppPopupMenuItem<String>(
            value: 'remove',
            icon: Icons.delete_outline_rounded,
            iconColor: context.palette.danger,
            text: 'Remove from recently played',
          ),
        ],
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'play') {
      widget.onOpen();
    } else if (selected == 'remove') {
      widget.onRemove?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final kind = MediaCatalog.kindFromExtension(entry.path);
    final icon = kind == MediaKind.audio
        ? Icons.music_note_rounded
        : Icons.movie_rounded;
    final type = switch (kind) {
      MediaKind.audio => 'Audio',
      MediaKind.video => 'Video',
      _ => 'Media',
    };
    final hasProgress =
        entry.duration > Duration.zero && entry.position > Duration.zero;
    final progress = hasProgress
        ? (entry.position.inMilliseconds / entry.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final accent = Theme.of(context).colorScheme.primary;
    final semanticLabel = hasProgress
        ? '$type: ${entry.title}, '
              '${formatTime(entry.position, compactMinutes: true)} of '
              '${formatTime(entry.duration, compactMinutes: true)}'
        : '$type: ${entry.title}';
    return Semantics(
      button: true,
      container: true,
      label: semanticLabel,
      child: InkWell(
        onTap: widget.onOpen,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        onHover: _setHover,
        onFocusChange: _setFocus,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.artwork),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<MediaThumbnail?>(
                      future: _thumbnail,
                      builder: (context, snapshot) {
                        final bytes =
                            snapshot.data?.bytes ?? _provisional?.bytes;
                        Widget fallback() => LibraryArtwork(
                          mediaPath: entry.path,
                          repository: widget.repository,
                          icon: icon,
                          iconSize: 32,
                        );
                        return bytes == null
                            ? fallback()
                            : Image.memory(
                                bytes,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                                cacheWidth: 480,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => fallback(),
                              );
                      },
                    ),
                    Positioned.fill(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _active,
                        builder: (context, active, _) {
                          if (!active) return const SizedBox.shrink();
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              const ColoredBox(
                                color: AppColors.lightScrim,
                                child: Center(
                                  child: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: AppColors.onStage,
                                    size: 44,
                                  ),
                                ),
                              ),
                              if (widget.onRemove != null)
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton(
                                    onPressed: widget.onRemove,
                                    tooltip: 'Remove from recently played',
                                    color: AppColors.onStage,
                                    style: IconButton.styleFrom(
                                      backgroundColor: AppColors.scrim,
                                      shape: const CircleBorder(
                                        side: BorderSide(
                                          color: AppColors.onStage,
                                          width: 0.5,
                                        ),
                                      ),
                                      minimumSize: const Size.square(44),
                                      maximumSize: const Size.square(44),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (hasProgress)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 3,
                        child: ColoredBox(
                          color: AppColors.lightScrim,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: progress,
                              child: ColoredBox(color: accent),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.palette.rowPrimary.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _focused
                              ? accent
                              : context.palette.primaryText,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasProgress
                            ? '$type  •  ${formatTime(entry.position, compactMinutes: true)} / ${formatTime(entry.duration, compactMinutes: true)}'
                            : type,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.palette.metadata.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onRemove != null)
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        size: 18,
                        color: context.palette.mutedText,
                      ),
                      tooltip: 'Actions',
                      padding: EdgeInsets.zero,
                      color: context.palette.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        side: BorderSide(color: context.palette.border),
                      ),
                      onSelected: (action) {
                        if (action == 'play') {
                          widget.onOpen();
                        } else if (action == 'remove') {
                          widget.onRemove?.call();
                        }
                      },
                      itemBuilder: (context) => [
                        AppPopupMenuItem<String>(
                          value: 'play',
                          icon: Icons.play_arrow_rounded,
                          iconColor: accent,
                          text: hasProgress ? 'Resume' : 'Play',
                        ),
                        const PopupMenuDivider(height: 1),
                        AppPopupMenuItem<String>(
                          value: 'remove',
                          icon: Icons.delete_outline_rounded,
                          iconColor: context.palette.danger,
                          text: 'Remove from recently played',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DropZoneCard extends StatelessWidget {
  const _DropZoneCard({
    required this.isDragging,
    required this.onOpenFiles,
    required this.onOpenUrl,
    this.compact = false,
  });

  final bool isDragging;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (compact) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDragging
              ? Color.alphaBlend(primary.withValues(alpha: 0.12), palette.card)
              : palette.card,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: isDragging
                ? primary
                : palette.borderStrong.withValues(alpha: 0.4),
            width: isDragging ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isDragging
                  ? Icons.file_download_rounded
                  : Icons.cloud_upload_outlined,
              size: 22,
              color: primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isDragging ? 'Release to play media' : 'Open new media',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Drop files anywhere, or browse your files',
                    style: palette.metadata,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  FilledButton.icon(
                    onPressed: onOpenFiles,
                    icon: const Icon(Icons.file_open_rounded, size: 16),
                    label: const Text('Open file'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpenUrl,
                    icon: const Icon(Icons.link_rounded, size: 16),
                    label: const Text('Open URL'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        color: isDragging
            ? Color.alphaBlend(primary.withValues(alpha: 0.12), palette.card)
            : palette.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(
          color: isDragging
              ? primary
              : isDark
              ? palette.borderStrong.withValues(alpha: 0.45)
              : palette.borderStrong,
          width: isDragging ? 2.0 : 1.0,
        ),
        boxShadow: AppMotion.lowPower(context)
            ? null
            : [
                BoxShadow(
                  color: isDragging
                      ? primary.withValues(alpha: 0.25)
                      : primary.withValues(alpha: isDark ? 0.05 : 0.03),
                  blurRadius: isDragging ? 32 : 24,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
                  blurRadius: isDark ? 16 : 24,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary.withValues(alpha: 0.12),
              border: Border.all(
                color: primary.withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: AppMotion.lowPower(context)
                  ? null
                  : [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.15),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
            ),
            child: Center(
              child: Icon(
                isDragging
                    ? Icons.file_download_rounded
                    : Icons.cloud_upload_rounded,
                size: 28,
                color: primary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isDragging ? 'Release to play media' : 'Drop media files here',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: AppLetterSpacing.title,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            isDragging
                ? 'Files will start playing immediately'
                : 'Drag and drop video or audio files anywhere, or browse your files',
            style: palette.rowSecondary.copyWith(color: palette.secondaryText),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: onOpenFiles,
                icon: const Icon(Icons.file_open_rounded, size: 18),
                label: const Text('Open file'),
              ),
              OutlinedButton.icon(
                onPressed: onOpenUrl,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Open URL'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: const [
              _FormatBadge('MP4'),
              _FormatBadge('MKV'),
              _FormatBadge('AVI'),
              _FormatBadge('MOV'),
              _FormatBadge('MP3'),
              _FormatBadge('FLAC'),
              _FormatBadge('AAC'),
              _FormatBadge('WAV'),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.raisedSurface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.borderStrong.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: palette.metadata.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: palette.secondaryText,
        ),
      ),
    );
  }
}

class _HomeEmptyGuide extends StatelessWidget {
  const _HomeEmptyGuide();

  Widget _buildKeyPill(BuildContext context, String keyText, String label) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: palette.borderStrong.withValues(alpha: 0.5),
            ),
          ),
          child: Text(
            keyText,
            style: palette.metadata.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 11,
              color: palette.primaryText,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: palette.rowSecondary.copyWith(
            color: palette.secondaryText,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: palette.isDark
              ? palette.raisedSurface.withValues(alpha: 0.45)
              : palette.surface,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: palette.border),
        ),
        child: Center(
          child: Wrap(
            spacing: 24,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildKeyPill(context, 'Space', 'Play / Pause'),
              _buildKeyPill(context, 'F', 'Fullscreen'),
              _buildKeyPill(context, 'M', 'Mute'),
              _buildKeyPill(context, '← / →', 'Seek 5s'),
            ],
          ),
        ),
      ),
    );
  }
}
