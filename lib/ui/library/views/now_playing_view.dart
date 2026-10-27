import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../widgets/library_artwork.dart';

/// Now playing view featuring large artwork, track metadata, full transport
/// controls, timeline scrubber, volume, favorite toggle, and queue drawer.
class NowPlayingView extends StatefulWidget {
  const NowPlayingView({
    super.key,
    required this.controller,
    this.repository,
    this.onBack,
  });

  final PlayerController controller;
  final MediaLibraryRepository? repository;
  final VoidCallback? onBack;

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> {
  Uint8List? _cachedArtwork;
  String? _cachedArtworkPath;
  MediaItemRecord? _currentMediaRecord;
  int _metadataGeneration = 0;
  int _artworkGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.repository?.addListener(_onRepositoryChanged);
    _syncMetadata();
  }

  @override
  void didUpdateWidget(NowPlayingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _cachedArtworkPath = null;
      _syncMetadata();
    }
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository?.removeListener(_onRepositoryChanged);
      widget.repository?.addListener(_onRepositoryChanged);
      _currentMediaRecord = null;
      _syncMetadata();
    }
  }

  @override
  void dispose() {
    _metadataGeneration++;
    _artworkGeneration++;
    widget.controller.removeListener(_onControllerChanged);
    widget.repository?.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final cur = widget.controller.current;
    if (cur?.path != _cachedArtworkPath) {
      _syncMetadata();
    } else {
      if (mounted) setState(() {});
    }
  }

  void _onRepositoryChanged() {
    _syncMetadata();
  }

  Future<void> _syncMetadata() async {
    final generation = ++_metadataGeneration;
    final cur = widget.controller.current;
    if (cur == null) {
      _artworkGeneration++;
      if (mounted) {
        setState(() {
          _cachedArtwork = null;
          _cachedArtworkPath = null;
          _currentMediaRecord = null;
        });
      }
      return;
    }

    if (_cachedArtworkPath != cur.path) {
      final artworkGeneration = ++_artworkGeneration;
      setState(() {
        _cachedArtworkPath = cur.path;
        _cachedArtwork = null;
        _currentMediaRecord = null;
      });
      unawaited(_loadArtwork(cur, artworkGeneration));
    }

    // Load media record from repo if available
    final repository = widget.repository;
    if (repository != null && repository.isReady) {
      MediaItemRecord? record;
      try {
        record = await repository.getMediaByCanonicalSource(cur.path);
      } catch (_) {
        return;
      }
      if (mounted &&
          generation == _metadataGeneration &&
          _cachedArtworkPath == cur.path) {
        setState(() {
          _currentMediaRecord = record;
        });
      }
    }
  }

  Future<void> _loadArtwork(MediaEntry entry, int generation) async {
    final thumb = await widget.controller
        .loadThumbnail(entry)
        .catchError((Object _) => null);
    if (mounted &&
        generation == _artworkGeneration &&
        _cachedArtworkPath == entry.path) {
      setState(() => _cachedArtwork = thumb?.bytes);
    }
  }

  Future<void> _toggleFavorite() async {
    final repo = widget.repository;
    final record = _currentMediaRecord;
    if (repo == null || record == null) return;
    final nextFav = !record.isFavorite;
    await repo.toggleFavorite(record.id, nextFav);
    if (!mounted) return;
    setState(() {
      _currentMediaRecord = record.copyWith(isFavorite: nextFav);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.controller.current;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 800;

        return Scaffold(
          backgroundColor: AppTheme.background,
          body: Stack(
            children: [
              if (_cachedArtwork != null)
                Positioned.fill(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                    child: Image.memory(_cachedArtwork!, fit: BoxFit.cover),
                  ),
                ),
              Positioned.fill(
                child: ColoredBox(
                  color: Color.alphaBlend(
                    Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.1),
                    AppTheme.background,
                  ).withValues(alpha: 0.82),
                ),
              ),
              Row(
                children: [
                  // Main content stage
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.xl,
                        vertical: AppSpace.lg,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (widget.onBack != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: IconButton(
                                    icon: const Icon(Icons.arrow_back_rounded),
                                    tooltip: 'Back',
                                    color: AppTheme.secondaryText,
                                    onPressed: widget.onBack,
                                  ),
                                ),
                              const SizedBox(height: 12),
                              // Large square artwork
                              _buildArtwork(context, isNarrow ? 260 : 340),
                              const SizedBox(height: 28),
                              // Title & Favorite row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 48,
                                  ), // balance favorite button
                                  Expanded(
                                    child: Text(
                                      _currentMediaRecord?.title ??
                                          entry?.title ??
                                          'Nothing playing',
                                      style: AppTheme.pageTitle,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      (_currentMediaRecord?.isFavorite ?? false)
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      color:
                                          (_currentMediaRecord?.isFavorite ??
                                              false)
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : AppTheme.mutedText,
                                    ),
                                    tooltip:
                                        (_currentMediaRecord?.isFavorite ??
                                            false)
                                        ? 'Remove from favorites'
                                        : 'Add to favorites',
                                    onPressed: _currentMediaRecord != null
                                        ? _toggleFavorite
                                        : null,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Artist
                              Text(
                                _currentMediaRecord?.artist ??
                                    (entry == null ? '' : 'Unknown artist'),
                                style: AppTheme.sectionTitle.copyWith(
                                  color: AppTheme.secondaryText,
                                  fontWeight: FontWeight.w500,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              // Album
                              Text(
                                _currentMediaRecord?.album ?? '',
                                style: AppTheme.rowSecondary.copyWith(
                                  color: AppTheme.mutedText,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
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

  Widget _buildArtwork(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.raisedSurface,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: AppTheme.border, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _cachedArtwork != null
          ? Image.memory(
              _cachedArtwork!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _buildFallbackArtwork(),
            )
          : _currentMediaRecord != null
          ? LibraryArtwork(
              path: _currentMediaRecord!.metadata.artworkUri,
              mediaPath: _currentMediaRecord!.path,
              repository: widget.repository,
              icon: Icons.music_note_rounded,
              iconSize: 42,
            )
          : _buildFallbackArtwork(),
    );
  }

  Widget _buildFallbackArtwork() => ColoredBox(
    color: AppTheme.raisedSurface,
    child: Center(
      child: Icon(
        Icons.music_note_rounded,
        size: 42,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
