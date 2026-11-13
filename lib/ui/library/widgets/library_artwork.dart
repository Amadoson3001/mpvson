import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../core/app_theme.dart';

/// Displays cached artwork and recreates it when the cache has evicted it.
class LibraryArtwork extends StatefulWidget {
  const LibraryArtwork({
    super.key,
    this.path,
    this.mediaPath,
    this.repository,
    this.icon = Icons.album_rounded,
    this.iconSize = 48,
    this.semanticLabel,
  });

  final String? path;
  final String? mediaPath;
  final MediaLibraryRepository? repository;
  final IconData icon;
  final double iconSize;

  /// Description announced by screen readers.
  ///
  /// When omitted the artwork is treated as decorative, which is the right
  /// default for tiles that already announce their own title.
  final String? semanticLabel;

  @override
  State<LibraryArtwork> createState() => _LibraryArtworkState();
}

class _LibraryArtworkState extends State<LibraryArtwork> {
  static const int _maxCachedPaths = 512;
  static final LinkedHashMap<String, String> _directPathCache =
      LinkedHashMap<String, String>();
  static final Expando<LinkedHashMap<String, String>> _repoPathCache =
      Expando<LinkedHashMap<String, String>>('libraryArtworkRepoPathCache');

  late Future<String?> _artwork;
  String? _syncPath;

  String get _repoLookupKey =>
      '${widget.path ?? ''}\u0000${widget.mediaPath ?? ''}';

  static String? _touchLru(LinkedHashMap<String, String> cache, String key) {
    final existing = cache.remove(key);
    if (existing != null) {
      cache[key] = existing;
    }
    return existing;
  }

  static void _recordLru(
    LinkedHashMap<String, String> cache,
    String key,
    String value,
  ) {
    cache.remove(key);
    cache[key] = value;
    while (cache.length > _maxCachedPaths) {
      cache.remove(cache.keys.first);
    }
  }

  String? _lookupCachedPath() {
    final direct = widget.path;
    if (direct != null && direct.isNotEmpty) {
      final hit = _touchLru(_directPathCache, direct);
      if (hit != null) return hit;
    }
    final repo = widget.repository;
    if (repo != null && widget.mediaPath != null) {
      final repoCache = _repoPathCache[repo];
      if (repoCache != null) {
        return _touchLru(repoCache, _repoLookupKey);
      }
    }
    return null;
  }

  void _recordCachedPath(String resolved) {
    final direct = widget.path;
    if (direct != null && direct.isNotEmpty && resolved == direct) {
      _recordLru(_directPathCache, direct, resolved);
      return;
    }
    final repo = widget.repository;
    if (repo != null && widget.mediaPath != null) {
      final repoCache = _repoPathCache[repo] ??=
          LinkedHashMap<String, String>();
      _recordLru(repoCache, _repoLookupKey, resolved);
    }
  }

  void _invalidateCachedPath(String failedPath) {
    _directPathCache.remove(failedPath);
    if (widget.path != null && widget.path!.isNotEmpty) {
      _directPathCache.remove(widget.path);
    }
    final repo = widget.repository;
    if (repo != null && widget.mediaPath != null) {
      _repoPathCache[repo]?.remove(_repoLookupKey);
    }
  }

  void _prepareArtwork() {
    _syncPath = _lookupCachedPath();
    if (_syncPath != null) {
      _artwork = SynchronousFuture<String?>(_syncPath);
    } else {
      _artwork = _resolve();
    }
  }

  @override
  void initState() {
    super.initState();
    _prepareArtwork();
  }

  @override
  void didUpdateWidget(LibraryArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.mediaPath != widget.mediaPath ||
        oldWidget.repository != widget.repository) {
      _prepareArtwork();
    }
  }

  File _file(String source) {
    final uri = Uri.tryParse(source);
    return uri?.scheme == 'file' ? File.fromUri(uri!) : File(source);
  }

  Future<String?> _resolve() async {
    final path = widget.path;
    try {
      if (path != null && path.isNotEmpty && await _file(path).exists()) {
        _recordCachedPath(path);
        return path;
      }
      final mediaPath = widget.mediaPath;
      if (mediaPath != null && widget.repository != null) {
        final resolved = await widget.repository!.resolveArtwork(mediaPath);
        if (resolved != null && resolved.isNotEmpty) {
          _recordCachedPath(resolved);
        }
        return resolved;
      }
    } catch (_) {
      // Artwork can disappear independently of the media file.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => ColoredBox(
      color: context.palette.raisedSurface,
      child: Center(
        child: Icon(
          widget.icon,
          size: widget.iconSize,
          color: context.palette.mutedText,
        ),
      ),
    );
    final artwork = FutureBuilder<String?>(
      future: _artwork,
      builder: (context, snapshot) {
        final path = snapshot.data ?? _syncPath;
        if (path == null) return fallback();
        return LayoutBuilder(
          builder: (context, constraints) {
            // Decode at the size the artwork is displayed at instead of the
            // source resolution; album covers can otherwise cost megabytes
            // each in the image cache.
            final width = constraints.maxWidth;
            final cacheWidth = width.isFinite && width > 0
                ? (width * MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(1, 512)
                      .toInt()
                : 256;
            return Image.file(
              _file(path),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) {
                _invalidateCachedPath(path);
                return fallback();
              },
            );
          },
        );
      },
    );
    final label = widget.semanticLabel;
    if (label == null) return ExcludeSemantics(child: artwork);
    return Semantics(
      image: true,
      label: label,
      excludeSemantics: true,
      child: artwork,
    );
  }
}
