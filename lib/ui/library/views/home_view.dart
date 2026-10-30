import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../core/app_theme.dart';
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
    this.isDragging = false,
  });

  final List<MediaEntry> recent;
  final MediaLibraryRepository repository;
  final PlayerController controller;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final ValueChanged<MediaEntry> onOpenRecent;
  final bool isDragging;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppTheme.background,
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
              padding: EdgeInsets.fromLTRB(inset, 32, inset, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Home',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      isDragging ? 'Drop files to play' : 'Open your media',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose a file, open a URL, or drop files here.',
                      style: AppTheme.rowSecondary,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: onOpenFiles,
                          icon: const Icon(Icons.file_open_rounded),
                          label: const Text('Open file'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onOpenUrl,
                          icon: const Icon(Icons.link_rounded),
                          label: const Text('Open URL'),
                        ),
                      ],
                    ),
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 40),
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
                            style: AppTheme.metadata,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ],
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
                    mainAxisExtent: tileWidth * 9 / 16 + textHeight + 18,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _RecentTile(
                      key: ValueKey(recent[index].id),
                      entry: recent[index],
                      controller: controller,
                      repository: repository,
                      onOpen: () => onOpenRecent(recent[index]),
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
  });
  final MediaEntry entry;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final VoidCallback onOpen;

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

  String _time(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes
        .remainder(60)
        .toString()
        .padLeft(hours > 0 ? 2 : 1, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
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
          Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.rowPrimary.copyWith(
              fontWeight: FontWeight.w600,
              color: _focused ? accent : AppTheme.primaryText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasProgress
                ? '$type  •  ${_time(entry.position)} / ${_time(entry.duration)}'
                : type,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.metadata.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
