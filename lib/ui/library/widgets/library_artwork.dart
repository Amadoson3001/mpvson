import 'dart:io';

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
  });

  final String? path;
  final String? mediaPath;
  final MediaLibraryRepository? repository;
  final IconData icon;
  final double iconSize;

  @override
  State<LibraryArtwork> createState() => _LibraryArtworkState();
}

class _LibraryArtworkState extends State<LibraryArtwork> {
  late Future<String?> _artwork;

  @override
  void initState() {
    super.initState();
    _artwork = _resolve();
  }

  @override
  void didUpdateWidget(LibraryArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.mediaPath != widget.mediaPath ||
        oldWidget.repository != widget.repository) {
      _artwork = _resolve();
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
        return path;
      }
      final mediaPath = widget.mediaPath;
      if (mediaPath != null && widget.repository != null) {
        return await widget.repository!.resolveArtwork(mediaPath);
      }
    } catch (_) {
      // Artwork can disappear independently of the media file.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => ColoredBox(
      color: AppTheme.raisedSurface,
      child: Center(
        child: Icon(
          widget.icon,
          size: widget.iconSize,
          color: AppTheme.mutedText,
        ),
      ),
    );
    return FutureBuilder<String?>(
      future: _artwork,
      builder: (context, snapshot) {
        final path = snapshot.data;
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
                      .clamp(1, 4096)
                      .toInt()
                : null;
            return Image.file(
              _file(path),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              cacheWidth: cacheWidth,
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        );
      },
    );
  }
}
