import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/media_probe_service_impl.dart'
    show MediaProbeServiceImpl, PureDartMediaParser;
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';
import '../../core/toast/app_toast.dart';

/// Displays file, metadata, and playback properties for a media entry or
/// indexed library item.
class MediaPropertiesDialog extends StatefulWidget {
  const MediaPropertiesDialog({
    super.key,
    required this.path,
    required this.title,
    required this.kind,
    required this.repository,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.initialRecord,
    this.onShowInFolder,
    @visibleForTesting this.revealInFolder,
  });

  final String path;
  final String title;
  final MediaKind kind;
  final MediaLibraryRepository repository;
  final Duration duration;
  final Duration position;
  final MediaItemRecord? initialRecord;
  final ValueChanged<String>? onShowInFolder;

  @visibleForTesting
  final Future<bool> Function(String path)? revealInFolder;

  static Future<void> show(
    BuildContext context, {
    required String path,
    required String title,
    required MediaKind kind,
    required MediaLibraryRepository repository,
    Duration duration = Duration.zero,
    Duration position = Duration.zero,
    MediaItemRecord? initialRecord,
    ValueChanged<String>? onShowInFolder,
  }) {
    if (!context.mounted) return Future<void>.value();
    if (Navigator.maybeOf(context, rootNavigator: true) == null) {
      return Future<void>.value();
    }
    return AppDialog.show<void>(
      context: context,
      builder: (_) => MediaPropertiesDialog(
        path: path,
        title: title,
        kind: kind,
        repository: repository,
        duration: duration,
        position: position,
        initialRecord: initialRecord,
        onShowInFolder: onShowInFolder,
      ),
    );
  }

  @override
  State<MediaPropertiesDialog> createState() => _MediaPropertiesDialogState();
}

class _MediaPropertiesDialogState extends State<MediaPropertiesDialog> {
  MediaItemRecord? _record;
  MediaMetadata? _probedMetadata;
  FileStat? _fileStat;
  String? _displayPath;
  bool _loading = true;
  bool _probing = false;
  bool _revealing = false;
  int _loadGeneration = 0;

  String? get _localPath => normalizeLocalPath(widget.path);
  bool get _isEmptyPath => widget.path.trim().isEmpty;
  bool get _isNetwork => !_isEmptyPath && _localPath == null;

  @override
  void initState() {
    super.initState();
    _record = widget.initialRecord;
    _displayPath = _localPath;
    _loadDetails();
  }

  @override
  void didUpdateWidget(covariant MediaPropertiesDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.initialRecord != widget.initialRecord ||
        oldWidget.repository != widget.repository) {
      _record = widget.initialRecord;
      _probedMetadata = null;
      _fileStat = null;
      _displayPath = _localPath;
      _loading = true;
      _probing = false;
      _loadDetails();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    super.dispose();
  }

  bool _needsMetadataProbe(MediaItemRecord? record, FileStat? stat) {
    if (stat == null ||
        stat.type != FileSystemEntityType.file ||
        stat.size < 16) {
      return false;
    }
    final meta = record?.metadata;
    if (meta == null) return true;
    final hasDuration =
        meta.duration > Duration.zero || widget.duration > Duration.zero;
    if (!hasDuration) return true;
    final effectiveKind = widget.kind != MediaKind.unknown
        ? widget.kind
        : (record?.kind ?? MediaKind.unknown);
    if (effectiveKind == MediaKind.video) {
      return meta.videoInfo == null || meta.videoInfo!.isEmpty;
    }
    if (effectiveKind == MediaKind.audio) {
      return meta.audioInfo == null;
    }
    return (meta.videoInfo == null || meta.videoInfo!.isEmpty) &&
        meta.audioInfo == null;
  }

  Future<void> _loadDetails() async {
    final generation = ++_loadGeneration;
    final trimmedPath = widget.path.trim();
    final localPath = _localPath;

    if (trimmedPath.isEmpty) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _record = widget.initialRecord;
        _probedMetadata = null;
        _fileStat = null;
        _displayPath = null;
        _loading = false;
        _probing = false;
      });
      return;
    }

    final canonical = MediaEntry.canonicalSource(trimmedPath);
    final recordFuture = widget.initialRecord != null
        ? Future<MediaItemRecord?>.value(widget.initialRecord)
        : widget.repository
              .getMediaByCanonicalSource(canonical)
              .catchError((Object _) => null);

    final statFuture = localPath != null
        ? FileStat.stat(localPath)
              .then<FileStat?>(
                (stat) =>
                    stat.type == FileSystemEntityType.notFound ? null : stat,
              )
              .catchError((Object _) => null)
        : Future<FileStat?>.value(null);

    final resolvedRecord = await recordFuture;
    final resolvedStat = await statFuture;

    String? resolvedDisplayPath = localPath;
    if (localPath != null && resolvedStat != null) {
      try {
        final rawResolved = resolvedStat.type == FileSystemEntityType.directory
            ? await Directory(localPath).resolveSymbolicLinks()
            : await File(localPath).resolveSymbolicLinks();
        resolvedDisplayPath =
            normalizeLocalPath(rawResolved) ??
            stripWindowsLongPathPrefix(rawResolved);
      } catch (_) {
        resolvedDisplayPath = localPath;
      }
    }

    final shouldProbe = _needsMetadataProbe(resolvedRecord, resolvedStat);

    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _record = resolvedRecord;
      _fileStat = resolvedStat;
      _displayPath = resolvedDisplayPath;
      _loading = false;
      _probing = shouldProbe;
    });

    if (!shouldProbe || localPath == null || resolvedStat == null) return;

    final probePath = resolvedDisplayPath ?? localPath;
    final discovered = await const PureDartMediaParser()
        .parse(probePath)
        .catchError((Object _) => null);
    if (!mounted || generation != _loadGeneration) return;

    final parsedMeta = discovered != null
        ? MediaProbeServiceImpl.normalizeMetadata(
            rawTags: discovered.rawTags,
            duration: discovered.duration,
            audioInfo: discovered.audioInfo,
            videoInfo: discovered.videoInfo,
            artworkUri: resolvedRecord?.metadata.artworkUri,
          )
        : null;

    if (parsedMeta != null) {
      setState(() {
        _probedMetadata = parsedMeta;
      });
    }

    final effectiveKind = widget.kind != MediaKind.unknown
        ? widget.kind
        : (resolvedRecord?.kind ?? MediaKind.unknown);
    final pureHasStreamInfo =
        parsedMeta != null &&
        parsedMeta.duration > Duration.zero &&
        (effectiveKind == MediaKind.video
            ? (parsedMeta.videoInfo != null && !parsedMeta.videoInfo!.isEmpty)
            : parsedMeta.audioInfo != null);

    if (resolvedRecord != null && pureHasStreamInfo) {
      await widget.repository
          .updateMediaMetadata(
            resolvedRecord.canonicalSource,
            kind: resolvedRecord.kind,
            metadata: parsedMeta,
            fileSize: resolvedStat.size,
            modifiedAt: resolvedStat.modified,
          )
          .catchError((Object _) {});
    } else if (!pureHasStreamInfo || resolvedRecord != null) {
      await widget.repository.probeMedia(trimmedPath).catchError((Object _) {});
      if (!mounted || generation != _loadGeneration) return;
      final refreshed = await widget.repository
          .getMediaByCanonicalSource(canonical)
          .catchError((Object _) => null);
      if (!mounted || generation != _loadGeneration) return;
      if (refreshed != null) {
        setState(() {
          _record = refreshed;
        });
      }
    }

    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _probing = false;
    });
  }

  String get _kindLabel => switch (widget.kind) {
    MediaKind.video => 'Video',
    MediaKind.audio => 'Audio',
    _ => _isNetwork ? 'Stream' : 'Media',
  };

  IconData get _kindIcon => switch (widget.kind) {
    MediaKind.video => Icons.movie_outlined,
    MediaKind.audio => Icons.music_note_rounded,
    _ => _isNetwork ? Icons.link_rounded : Icons.insert_drive_file_outlined,
  };

  String _formatVideoCodecLabel(String codec) {
    final normalized = codec.trim().toLowerCase();
    return switch (normalized) {
      'h264' || 'avc' || 'avc1' => 'H.264',
      'hevc' || 'h265' || 'hvc1' || 'hev1' => 'H.265 / HEVC',
      'vp9' => 'VP9',
      'vp8' => 'VP8',
      'av1' => 'AV1',
      'mpeg4' => 'MPEG-4',
      _ => codec.trim().toUpperCase(),
    };
  }

  String _formatFpsLabel(double fps) {
    final rounded = fps.roundToDouble();
    if ((fps - rounded).abs() < 0.005) {
      return '${rounded.toInt()} fps';
    }
    return '${fps.toStringAsFixed(2)} fps';
  }

  String _formatBitrateLabel(int bitrate) {
    if (bitrate >= 1000000) {
      return '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
    }
    return '${(bitrate / 1000).round()} kbps';
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d  $hh:$mm';
  }

  Future<void> _copyLocation() async {
    final valueToCopy = _isNetwork
        ? widget.path.trim()
        : (_displayPath ?? _localPath ?? widget.path.trim());
    if (valueToCopy.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: valueToCopy));
    if (!mounted) return;
    AppToast.show(
      context,
      _isNetwork
          ? 'Source URL copied to clipboard'
          : 'Path copied to clipboard',
    );
  }

  Future<void> _revealInExplorer() async {
    final targetPath = _localPath ?? widget.path.trim();
    if (targetPath.isEmpty || _isNetwork || _revealing) return;
    if (widget.onShowInFolder != null) {
      widget.onShowInFolder!(targetPath);
      return;
    }

    setState(() => _revealing = true);
    var ok = false;
    try {
      ok = await (widget.revealInFolder ?? showInFolder)(targetPath);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _revealing = false);
    if (!ok) {
      AppToast.show(
        context,
        'Could not open File Explorer',
        tone: AppToastTone.warning,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final isNetwork = _isNetwork;
    final isEmptyPath = _isEmptyPath;
    final record = _record;
    final meta = record?.metadata ?? MediaMetadata.empty;

    final effectivePath = _displayPath ?? _localPath ?? widget.path.trim();
    final isDirectory = _fileStat?.type == FileSystemEntityType.directory;
    final isMissingFromDisk =
        !isNetwork &&
        !isEmptyPath &&
        (_loading
            ? (record != null && !record.isAvailable)
            : _fileStat == null);

    final effectiveDuration = widget.duration > Duration.zero
        ? widget.duration
        : (meta.duration > Duration.zero
              ? meta.duration
              : (_probedMetadata?.duration ?? Duration.zero));
    final effectiveArtist =
        (meta.artist != null && meta.artist!.trim().isNotEmpty)
        ? meta.artist!.trim()
        : _probedMetadata?.artist?.trim();
    final effectiveAlbum = (meta.album != null && meta.album!.trim().isNotEmpty)
        ? meta.album!.trim()
        : _probedMetadata?.album?.trim();
    final effectiveGenre = (meta.genre != null && meta.genre!.trim().isNotEmpty)
        ? meta.genre!.trim()
        : _probedMetadata?.genre?.trim();
    final effectiveYear = (meta.year != null && meta.year! > 0)
        ? meta.year
        : _probedMetadata?.year;
    final effectiveSize = (_fileStat != null && !isDirectory)
        ? _fileStat!.size
        : (record?.fileSize ?? 0);
    final showSize =
        (_fileStat != null && _fileStat!.type == FileSystemEntityType.file) ||
        (effectiveSize > 0 && !isDirectory);
    final modifiedAt = _fileStat?.modified ?? record?.modifiedAt;

    final ext = (isEmptyPath || isNetwork || isDirectory)
        ? ''
        : p.extension(effectivePath).replaceFirst('.', '').toUpperCase();
    final fileName = isEmptyPath
        ? 'Unavailable'
        : isNetwork
        ? effectivePath
        : (p.basename(effectivePath).isNotEmpty
              ? p.basename(effectivePath)
              : effectivePath);
    final folderPath = (isEmptyPath || isNetwork)
        ? effectivePath
        : (isDirectory ? effectivePath : p.dirname(effectivePath));

    final displayTitle = widget.title.trim().isNotEmpty
        ? widget.title.trim()
        : fileName;

    final videoInfo = meta.videoInfo ?? _probedMetadata?.videoInfo;
    final videoParts = <String>[
      if (videoInfo?.codec != null && videoInfo!.codec!.trim().isNotEmpty)
        _formatVideoCodecLabel(videoInfo.codec!),
      if (videoInfo?.resolutionLabel != null) videoInfo!.resolutionLabel!,
      if (videoInfo?.fps != null && videoInfo!.fps! > 0)
        _formatFpsLabel(videoInfo.fps!),
      if (videoInfo?.bitrate != null && videoInfo!.bitrate! > 0)
        _formatBitrateLabel(videoInfo.bitrate!),
    ];

    final audioInfo = meta.audioInfo ?? _probedMetadata?.audioInfo;
    final codecParts = <String>[
      if (audioInfo?.codec != null && audioInfo!.codec!.trim().isNotEmpty)
        audioInfo.codec!.trim().toUpperCase(),
      if (audioInfo?.sampleRate != null && audioInfo!.sampleRate! > 0)
        '${(audioInfo.sampleRate! / 1000).toStringAsFixed(1)} kHz',
      if (audioInfo?.bitrate != null && audioInfo!.bitrate! > 0)
        _formatBitrateLabel(audioInfo.bitrate!),
      if (audioInfo?.bitsPerSample != null && audioInfo!.bitsPerSample! > 0)
        '${audioInfo.bitsPerSample}-bit',
      if (audioInfo?.channels != null && audioInfo!.channels! > 0)
        '${audioInfo.channels} ch',
    ];

    return AppDialog(
      maxWidth: 500,
      scrollable: true,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
            ),
            child: Icon(_kindIcon, size: 20, color: accent),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: palette.sectionTitle.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  ext.isNotEmpty ? '$_kindLabel  •  $ext' : _kindLabel,
                  style: palette.metadata,
                ),
              ],
            ),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: accent,
                backgroundColor: palette.border,
              ),
            ),
          Divider(height: 1, color: palette.border),
          const SizedBox(height: AppSpace.md),
          _PropertyRow(
            label: isNetwork ? 'Source' : (isDirectory ? 'Folder' : 'File'),
            value: fileName,
            trailing: isNetwork && !isEmptyPath
                ? IconButton(
                    onPressed: _copyLocation,
                    tooltip: 'Copy source URL',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    color: palette.secondaryText,
                    icon: const Icon(Icons.content_copy_rounded),
                  )
                : null,
          ),
          if (!isNetwork && !isEmptyPath && !isDirectory)
            _PropertyRow(
              label: 'Folder',
              value: folderPath,
              trailing: IconButton(
                onPressed: _copyLocation,
                tooltip: 'Copy full path',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                color: palette.secondaryText,
                icon: const Icon(Icons.content_copy_rounded),
              ),
            ),
          if (effectiveDuration > Duration.zero)
            _PropertyRow(
              label: 'Duration',
              value: formatDuration(effectiveDuration, compactMinutes: true),
              tabular: true,
            ),
          if (widget.position > Duration.zero)
            _PropertyRow(
              label: 'Resume at',
              value: formatDuration(widget.position, compactMinutes: true),
              tabular: true,
            ),
          if (showSize)
            _PropertyRow(
              label: 'Size',
              value: formatFileSize(effectiveSize),
              tabular: true,
            ),
          if (effectiveArtist != null && effectiveArtist.isNotEmpty)
            _PropertyRow(label: 'Artist', value: effectiveArtist),
          if (effectiveAlbum != null && effectiveAlbum.isNotEmpty)
            _PropertyRow(label: 'Album', value: effectiveAlbum),
          if (effectiveGenre != null && effectiveGenre.isNotEmpty)
            _PropertyRow(label: 'Genre', value: effectiveGenre),
          if (effectiveYear != null && effectiveYear > 0)
            _PropertyRow(label: 'Year', value: '$effectiveYear', tabular: true),
          if (videoParts.isNotEmpty)
            _PropertyRow(
              label: 'Video',
              value: videoParts.join('  •  '),
              tabular: true,
            ),
          if (codecParts.isNotEmpty)
            _PropertyRow(
              label: 'Audio',
              value: codecParts.join('  •  '),
              tabular: true,
            ),
          if (_probing && videoParts.isEmpty && codecParts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                'Inspecting stream metadata…',
                style: palette.metadata,
              ),
            ),
          if (modifiedAt != null)
            _PropertyRow(
              label: 'Modified',
              value: _formatDateTime(modifiedAt),
              tabular: true,
            ),
          if (record?.lastPlayedAt != null)
            _PropertyRow(
              label: 'Last played',
              value: _formatDateTime(record!.lastPlayedAt!),
              tabular: true,
            ),
          if (record != null && record.playCount > 0)
            _PropertyRow(
              label: 'Play count',
              value: '${record.playCount}',
              tabular: true,
            ),
          if (isMissingFromDisk)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: AppSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: palette.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  border: Border.all(
                    color: palette.danger.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: palette.danger,
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        'This file is currently missing from disk.',
                        style: palette.metadata.copyWith(color: palette.danger),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      actions: [
        if (!isNetwork && !isEmptyPath)
          OutlinedButton.icon(
            onPressed: _revealing ? null : _revealInExplorer,
            icon: const Icon(Icons.folder_outlined, size: 17),
            label: const Text('Open in File Explorer'),
          ),
        FilledButton(
          onPressed: () => Navigator.maybeOf(context)?.pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _PropertyRow extends StatelessWidget {
  const _PropertyRow({
    required this.label,
    required this.value,
    this.tabular = false,
    this.trailing,
  });

  final String label;
  final String value;
  final bool tabular;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: palette.metadata.copyWith(fontSize: AppType.small),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: SelectableText(
              value,
              style: palette.rowPrimary.copyWith(
                fontSize: AppType.small,
                fontFeatures: tabular
                    ? const [FontFeature.tabularFigures()]
                    : null,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpace.xs),
            trailing!,
          ],
        ],
      ),
    );
  }
}
