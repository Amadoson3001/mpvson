import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/format.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_popup_menu_item.dart';
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
        final columns = ((contentWidth + gap) / 320).ceil().clamp(1, 8);
        final tileWidth = (contentWidth - (columns - 1) * gap) / columns;
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          'Home',
                          style: Theme.of(context).textTheme.displaySmall,
                        ),
                        const SizedBox(width: 14),
                        Text(
                          'Desktop Media Center',
                          style: context.palette.metadata.copyWith(
                            color: context.palette.mutedText,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _DropZoneCard(
                      isDragging: isDragging,
                      onOpenFiles: onOpenFiles,
                      onOpenUrl: onOpenUrl,
                      compact: recent.isNotEmpty,
                    ),
                    if (recent.isEmpty) ...[ const _HomeEmptyGuide(), const _HomeFooterInfo() ],
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            'Recently played',
                            style: Theme.of(context).textTheme.titleLarge,
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
                                  if (cleared.isNotEmpty && context.mounted) {
                                    AppToast.show(
                                      context,
                                      'Recently played cleared',
                                      actionLabel: 'Undo',
                                      onAction: () =>
                                          controller.restoreRecentList(cleared),
                                    );
                                  }
                                },
                            icon: const Icon(Icons.clear_all_rounded, size: 16),
                            label: const Text('Clear all'),
                            style: TextButton.styleFrom(
                              foregroundColor: context.palette.mutedText,
                              visualDensity: VisualDensity.compact,
                              textStyle: Theme.of(context).textTheme.bodySmall,
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
                padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
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
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _thumbnail = _load();
  }

  @override
  void didUpdateWidget(covariant _RecentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.controller != widget.controller) {
      _request?.release();
      _request = null;
      _thumbnail = _load();
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
    return InkWell(
      onTap: widget.onOpen,
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      onHover: (value) => setState(() => _hovered = value),
      onFocusChange: (value) => setState(() => _focused = value),
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
                      final bytes = snapshot.data?.bytes;
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
                              cacheWidth: 512,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => fallback(),
                            );
                    },
                  ),
                  if (_hovered || _focused)
                    ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                      child: const Center(
                        child: Icon(
                          Icons.play_circle_fill_rounded,
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
                  if (widget.onRemove != null && (_hovered || _focused))
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.transparent,
                        child: Tooltip(
                          message: 'Remove from recently played',
                          child: InkResponse(
                            onTap: widget.onRemove,
                            radius: 16,
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.7),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.25),
                                  width: 1,
                                ),
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (hasProgress)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 3,
                      child: ColoredBox(
                        color: Colors.black45,
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
                        color: _focused ? accent : context.palette.primaryText,
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
                  width: 24,
                  height: 24,
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: isDragging
            ? Color.alphaBlend(primary.withValues(alpha: 0.12), palette.card)
            : palette.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(
          color: isDragging
              ? primary
              : palette.borderStrong.withValues(alpha: 0.5),
          width: isDragging ? 2.0 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isDragging
                ? primary.withValues(alpha: 0.25)
                : primary.withValues(alpha: 0.06),
            blurRadius: isDragging ? 32 : 24,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary.withValues(alpha: 0.14),
              border: Border.all(
                color: primary.withValues(alpha: 0.38),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: primary.withValues(alpha: 0.18),
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
          const SizedBox(height: 12),
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
                : 'Drag and drop audio or video files anywhere, or browse your files',
            style: palette.rowSecondary.copyWith(
              color: palette.secondaryText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline_rounded,
                  size: 14, color: palette.mutedText),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Supports MP4, MKV, AVI, MOV, MP3, FLAC, AAC, WAV, and more',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: palette.metadata.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeEmptyGuide extends StatelessWidget {
  const _HomeEmptyGuide();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        Text(
          'Features & Shortcuts',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: palette.primaryText,
          ),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 640;
            if (isWide) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    Expanded(
                      child: _FeatureCard(
                        icon: Icons.tune_rounded,
                        title: 'High-Performance Engine',
                        description:
                            'Hardware-accelerated playback powered by mpv. Supports HDR tonemapping, high-bitrate video, and bit-perfect lossless audio.',
                        tags: ['4K HDR', 'H.265 / AV1', 'Lossless FLAC', 'Gapless Audio', 'Hardware Accel', 'Subtitles Engine'],
                        accentColor: Color(0xFFF1A64C),
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: _ShortcutsCard(
                        accentColor: Color(0xFFDDB264),
                      ),
                    ),
                  ],
                ),
              );
            }
            return Column(
              children: const [
                _FeatureCard(
                  icon: Icons.tune_rounded,
                  title: 'High-Performance Engine',
                  description:
                      'Hardware-accelerated playback powered by mpv. Supports HDR tonemapping, high-bitrate video, and bit-perfect lossless audio.',
                  tags: ['4K HDR', 'H.265 / AV1', 'Lossless FLAC', 'Gapless Audio', 'Hardware Accel', 'Subtitles Engine'],
                  accentColor: Color(0xFFF1A64C),
                ),
                SizedBox(height: 16),
                _ShortcutsCard(
                  accentColor: Color(0xFFDDB264),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.tags,
    required this.accentColor,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<String> tags;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.raisedSurface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Icon(icon, size: 20, color: accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.primaryText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: palette.rowSecondary.copyWith(
              color: palette.secondaryText,
              height: 1.4,
            ),
          ),
          const Spacer(),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: tags.map((tag) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  border: Border.all(
                    color: palette.borderStrong.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  tag,
                  style: palette.metadata.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: palette.primaryText.withValues(alpha: 0.85),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ShortcutsCard extends StatelessWidget {
  const _ShortcutsCard({
    required this.accentColor,
  });

  final Color accentColor;

  Widget _buildKeyRow(BuildContext context, String keyText, String desc) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
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
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              desc,
              style: palette.rowSecondary.copyWith(
                color: palette.secondaryText,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.raisedSurface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Icon(
                  Icons.keyboard_outlined,
                  size: 20,
                  color: accentColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Quick Keyboard Shortcuts',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.primaryText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildKeyRow(context, 'Space', 'Play / Pause playback'),
          _buildKeyRow(context, 'F', 'Toggle fullscreen'),
          _buildKeyRow(context, 'M', 'Mute / Unmute audio'),
          _buildKeyRow(context, '← / →', 'Seek 5 seconds backward / forward'),
          const Spacer(),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 14, color: palette.secondaryText),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Customize shortcuts in Settings',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: palette.metadata.copyWith(
                    fontSize: 11,
                    color: palette.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeFooterInfo extends StatelessWidget {
  const _HomeFooterInfo();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 32),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, size: 14, color: palette.mutedText),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'mpvson Media Center • High fidelity local playback',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: palette.metadata.copyWith(
                  fontSize: 11,
                  color: palette.mutedText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}