import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../utils/file_utils.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/library_item_actions.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/format.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/page_header.dart';
import '../../core/components/player_icon_button.dart';
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
  Widget build(BuildContext context) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    final hasDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        gradient: RadialGradient(
          center: const Alignment(0, -0.35),
          radius: 1.15,
          colors: [
            primary.withValues(alpha: 0.06),
            palette.raisedSurface.withValues(alpha: 0.12),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        border: isDragging ? Border.all(color: primary, width: 2) : null,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 18.0;
          final compact = constraints.maxWidth < AppLayout.compactBreakpoint;
          final inset = PageHeader.gutterFor(constraints.maxWidth);
          final gridWidth = (constraints.maxWidth - inset * 2).clamp(
            0.0,
            double.infinity,
          );
          final columns = ((gridWidth + gap) / AppLayout.videoGridMinWidth)
              .ceil()
              .clamp(1, 8);
          final tileWidth = (gridWidth - (columns - 1) * gap) / columns;
          final textHeight = MediaQuery.textScalerOf(context).scale(13) * 4.0;

          final openButtons = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: onOpenFiles,
                icon: const Icon(Icons.file_open_rounded, size: 16),
                label: const Text('Open file'),
              ),
              const SizedBox(width: AppSpace.xs),
              OutlinedButton.icon(
                onPressed: onOpenUrl,
                icon: const Icon(Icons.link_rounded, size: 16),
                label: const Text('Open URL'),
              ),
            ],
          );

          final headerRow = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (hasDrawer) ...[
                PlayerIconButton(
                  icon: const Icon(Icons.menu_rounded),
                  tooltip: 'Open navigation',
                  color: palette.primaryText,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
                const SizedBox(width: AppSpace.xs),
              ],
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Home',
                    style: palette.pageTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              if (!compact)
                openButtons
              else
                Flexible(
                  flex: 0,
                  child: Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    alignment: WrapAlignment.end,
                    children: [
                      FilledButton.icon(
                        onPressed: onOpenFiles,
                        icon: const Icon(Icons.file_open_rounded, size: 16),
                        label: const Text('Open'),
                      ),
                      IconButton.outlined(
                        onPressed: onOpenUrl,
                        tooltip: 'Open URL',
                        icon: const Icon(Icons.link_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
            ],
          );

          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  AppSpace.md,
                  inset,
                  recent.isEmpty ? AppSpace.lg : AppSpace.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      headerRow,
                      if (isDragging && recent.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.sm),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.md,
                            vertical: AppSpace.sm,
                          ),
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              primary.withValues(alpha: 0.12),
                              palette.card,
                            ),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            border: Border.all(color: primary, width: 1.5),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.file_download_rounded,
                                size: 20,
                                color: primary,
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Text(
                                'Release to play media',
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (recent.isEmpty) ...[
                        const SizedBox(height: AppSpace.lg),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: Column(
                              children: [
                                _DropZoneCard(
                                  isDragging: isDragging,
                                  onOpenFiles: onOpenFiles,
                                  onOpenUrl: onOpenUrl,
                                ),
                                const _HomeEmptyGuide(),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (recent.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.lg),
                        _RecentSectionHeader(
                          recentCount: recent.length,
                          onClearRecent: () {
                            _homeSelectedRecentIds.value = <String>{};
                            if (onClearRecent != null) {
                              onClearRecent!();
                              return;
                            }
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
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (recent.isNotEmpty)
                _RecentSliverGrid(
                  recent: recent,
                  columns: columns,
                  gap: gap,
                  inset: inset,
                  tileWidth: tileWidth,
                  textHeight: textHeight,
                  controller: controller,
                  repository: repository,
                  onOpenRecent: onOpenRecent,
                  onRemoveRecent: onRemoveRecent,
                ),
            ],
          );
        },
      ),
    );
  }
}

final ValueNotifier<Set<String>> _homeSelectedRecentIds =
    ValueNotifier<Set<String>>(<String>{});

class _RecentSectionHeader extends StatelessWidget {
  const _RecentSectionHeader({
    required this.recentCount,
    required this.onClearRecent,
  });

  final int recentCount;
  final VoidCallback onClearRecent;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<Set<String>>(
      valueListenable: _homeSelectedRecentIds,
      builder: (context, selectedIds, _) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                'Recently played',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              '$recentCount ${recentCount == 1 ? 'item' : 'items'}',
              style: palette.metadata,
            ),
            if (selectedIds.isNotEmpty) ...[
              const SizedBox(width: AppSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  border: Border.all(color: accent.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${selectedIds.length} selected',
                      style: palette.metadata.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => _homeSelectedRecentIds.value = <String>{},
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.close_rounded,
                          size: 13,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Spacer(),
            TextButton.icon(
              onPressed: onClearRecent,
              icon: const Icon(Icons.clear_all_rounded, size: 16),
              label: const Text('Clear all'),
              style: TextButton.styleFrom(
                foregroundColor: palette.mutedText,
                visualDensity: VisualDensity.compact,
                textStyle: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecentSliverGrid extends StatelessWidget {
  const _RecentSliverGrid({
    required this.recent,
    required this.columns,
    required this.gap,
    required this.inset,
    required this.tileWidth,
    required this.textHeight,
    required this.controller,
    required this.repository,
    required this.onOpenRecent,
    this.onRemoveRecent,
  });

  final List<MediaEntry> recent;
  final int columns;
  final double gap;
  final double inset;
  final double tileWidth;
  final double textHeight;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final ValueChanged<MediaEntry> onOpenRecent;
  final ValueChanged<MediaEntry>? onRemoveRecent;

  void _toggleSelection(String id) {
    final next = Set<String>.from(_homeSelectedRecentIds.value);
    if (!next.add(id)) {
      next.remove(id);
    }
    _homeSelectedRecentIds.value = next;
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, AppSpace.xl),
      sliver: ValueListenableBuilder<Set<String>>(
        valueListenable: _homeSelectedRecentIds,
        builder: (context, selectedIds, _) {
          final selectionMode = selectedIds.isNotEmpty;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: 22,
              mainAxisExtent: tileWidth * 9 / 16 + textHeight + 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entry = recent[index];
                return _RecentTile(
                  key: ValueKey(entry.id),
                  entry: entry,
                  controller: controller,
                  repository: repository,
                  isSelected: selectedIds.contains(entry.id),
                  selectionMode: selectionMode,
                  onToggleSelect: () => _toggleSelection(entry.id),
                  onOpen: () => onOpenRecent(entry),
                  onRemove: onRemoveRecent != null
                      ? () {
                          final next = Set<String>.from(
                            _homeSelectedRecentIds.value,
                          )..remove(entry.id);
                          _homeSelectedRecentIds.value = next;
                          onRemoveRecent!(entry);
                        }
                      : () {
                          final next = Set<String>.from(
                            _homeSelectedRecentIds.value,
                          )..remove(entry.id);
                          _homeSelectedRecentIds.value = next;
                          final restored = controller.removeRecent(entry);
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
                );
              },
              addAutomaticKeepAlives: false,
              childCount: recent.length,
            ),
          );
        },
      ),
    );
  }
}

class _RecentTile extends StatefulWidget {
  const _RecentTile({
    super.key,
    required this.entry,
    required this.controller,
    required this.repository,
    required this.onOpen,
    required this.isSelected,
    required this.selectionMode,
    required this.onToggleSelect,
    this.onRemove,
  });
  final MediaEntry entry;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final VoidCallback onOpen;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onToggleSelect;
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

  final FocusNode _tileFocusNode = FocusNode(debugLabel: 'RecentTile');

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
    _tileFocusNode.dispose();
    super.dispose();
  }

  Future<void> _showInFolder(String path) async {
    final ok = await showInFolder(path);
    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open File Explorer',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    await showMediaContextMenu(
      context: context,
      globalPosition: position,
      target: LibraryItemTarget.fromEntry(widget.entry),
      repository: widget.repository,
      controller: widget.controller,
      onPlay: widget.onOpen,
      onRemove: widget.onRemove,
      isSelected: widget.isSelected,
      onSelect: widget.onToggleSelect,
      onShowInFolder: (path) => unawaited(_showInFolder(path)),
    );
    if (mounted) {
      _tileFocusNode.requestFocus();
    }
  }

  void _openContextMenuFromButton(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final bottomLeft = box.localToGlobal(Offset(0, box.size.height));
    _showContextMenu(buttonContext, bottomLeft);
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
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (!MediaEntry.isNetworkUrl(entry.path))
          const SingleActivator(LogicalKeyboardKey.f3): () =>
              unawaited(_showInFolder(entry.path)),
        if (widget.isSelected || widget.selectionMode)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _homeSelectedRecentIds.value = <String>{},
      },
      child: Semantics(
        button: true,
        container: true,
        label: semanticLabel,
        child: InkWell(
          focusNode: _tileFocusNode,
          onTap: () {
            _tileFocusNode.requestFocus();
            if (widget.selectionMode) {
              widget.onToggleSelect();
            } else {
              widget.onOpen();
            }
          },
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
                child: Container(
                  foregroundDecoration: widget.isSelected
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadii.artwork),
                          border: Border.all(color: accent, width: 2),
                        )
                      : null,
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
                        if (widget.isSelected)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
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
                            color: (_focused || widget.isSelected)
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
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Builder(
                      builder: (buttonContext) => IconButton(
                        icon: Icon(
                          Icons.more_vert_rounded,
                          size: 18,
                          color: context.palette.mutedText,
                        ),
                        tooltip: 'Actions',
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            _openContextMenuFromButton(buttonContext),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
  });

  final bool isDragging;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
