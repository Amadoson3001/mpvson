import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_source.dart';
import '../../../utils/file_utils.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../player/player_controller.dart';
import 'media_properties_dialog.dart';
import 'playlist_create_dialog.dart';

/// Descriptor for a recent item or indexed library video shown in
/// [showMediaContextMenu].
@immutable
class MediaContextMenuTarget {
  const MediaContextMenuTarget({
    required this.id,
    required this.path,
    required this.title,
    required this.kind,
    this.isAvailable = true,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.record,
  });

  factory MediaContextMenuTarget.fromEntry(MediaEntry entry) {
    return MediaContextMenuTarget(
      id: entry.id,
      path: entry.path,
      title: entry.title,
      kind: MediaCatalog.kindFromExtension(entry.path),
      duration: entry.duration,
      position: entry.position,
    );
  }

  factory MediaContextMenuTarget.fromRecord(
    MediaItemRecord record, {
    Duration position = Duration.zero,
  }) {
    return MediaContextMenuTarget(
      id: record.id,
      path: record.path,
      title: record.title,
      kind: record.kind,
      isAvailable: record.isAvailable,
      duration: record.metadata.duration,
      position: position,
      record: record,
    );
  }

  final String id;
  final String path;
  final String title;
  final MediaKind kind;
  final bool isAvailable;
  final Duration duration;
  final Duration position;
  final MediaItemRecord? record;

  bool get isNetwork => MediaEntry.isNetworkUrl(path);
}

/// Opens a desktop context menu at [globalPosition] with playback, queue,
/// playlist submenu, file explorer, properties, and selection actions.
Future<void> showMediaContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required MediaContextMenuTarget target,
  required MediaLibraryRepository repository,
  required PlayerController controller,
  VoidCallback? onPlay,
  VoidCallback? onRemove,
  VoidCallback? onSelect,
  bool isSelected = false,
  ValueChanged<String>? onShowInFolder,
}) async {
  final navigator = Navigator.maybeOf(context, rootNavigator: true);
  final overlay =
      navigator?.overlay ?? Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  final hostContext = overlay.context;
  final completer = Completer<void>();
  late final OverlayEntry overlayEntry;
  var closed = false;

  void dismiss() {
    if (closed) return;
    closed = true;
    if (overlayEntry.mounted) {
      overlayEntry.remove();
    }
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  overlayEntry = OverlayEntry(
    builder: (overlayContext) => _MediaContextMenuOverlay(
      hostContext: hostContext,
      anchor: globalPosition,
      target: target,
      repository: repository,
      controller: controller,
      onPlay: onPlay,
      onRemove: onRemove,
      onSelect: onSelect,
      isSelected: isSelected,
      onShowInFolder: onShowInFolder,
      onDismiss: dismiss,
    ),
  );

  overlay.insert(overlayEntry);
  return completer.future;
}

class _MediaContextMenuOverlay extends StatefulWidget {
  const _MediaContextMenuOverlay({
    required this.hostContext,
    required this.anchor,
    required this.target,
    required this.repository,
    required this.controller,
    required this.onPlay,
    required this.onRemove,
    required this.onSelect,
    required this.isSelected,
    required this.onShowInFolder,
    required this.onDismiss,
  });

  final BuildContext hostContext;
  final Offset anchor;
  final MediaContextMenuTarget target;
  final MediaLibraryRepository repository;
  final PlayerController controller;
  final VoidCallback? onPlay;
  final VoidCallback? onRemove;
  final VoidCallback? onSelect;
  final bool isSelected;
  final ValueChanged<String>? onShowInFolder;
  final VoidCallback onDismiss;

  @override
  State<_MediaContextMenuOverlay> createState() =>
      _MediaContextMenuOverlayState();
}

class _MediaContextMenuOverlayState extends State<_MediaContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  static const double _menuWidth = 246.0;
  static const double _submenuWidth = 224.0;
  static const double _viewportMargin = 8.0;
  static const double _rowHeight = 36.0;
  static const double _dividerHeight = 9.0;
  static const double _panelPadding = 4.0;

  final GlobalKey _playlistRowKey = GlobalKey();
  final FocusNode _focusNode = FocusNode(debugLabel: 'MediaContextMenu');
  late final AnimationController _animController;
  late final CurvedAnimation _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late final CurvedAnimation _scaleCurve;

  List<PlaylistRecord>? _playlists;
  bool _loadingPlaylists = true;
  bool _playlistSubmenuOpen = false;
  bool _hoveringPlaylistRow = false;
  bool _hoveringSubmenu = false;
  Timer? _submenuCloseTimer;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: AppMotion.hover,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _scaleCurve = CurvedAnimation(
      parent: _animController,
      curve: AppMotion.enter,
    );
    _scaleAnimation = Tween<double>(begin: 0.96, end: 1.0).animate(_scaleCurve);
    _loadPlaylists();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      if (AppMotion.lowPower(context)) {
        _animController.value = 1.0;
      } else {
        _animController.forward();
      }
    });
  }

  @override
  void dispose() {
    _submenuCloseTimer?.cancel();
    _fadeAnimation.dispose();
    _scaleCurve.dispose();
    _animController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    try {
      final list = await widget.repository.getPlaylists();
      if (!mounted) return;
      setState(() {
        _playlists = list;
        _loadingPlaylists = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _playlists = const [];
        _loadingPlaylists = false;
      });
    }
  }

  void _scheduleSubmenuClose() {
    _submenuCloseTimer?.cancel();
    _submenuCloseTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (!_hoveringPlaylistRow && !_hoveringSubmenu && _playlistSubmenuOpen) {
        setState(() => _playlistSubmenuOpen = false);
      }
    });
  }

  void _openSubmenuNow() {
    _submenuCloseTimer?.cancel();
    if (!_playlistSubmenuOpen) {
      setState(() => _playlistSubmenuOpen = true);
    }
  }

  void _runAndClose(VoidCallback action) {
    widget.onDismiss();
    action();
  }

  Future<void> _playNow() async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    final onPlay = widget.onPlay;
    widget.onDismiss();
    if (onPlay != null) {
      onPlay();
      return;
    }
    try {
      await widget.controller.openPaths(
        [target.path],
        append: false,
        initialIndex: 0,
      );
      if (hostContext.mounted && widget.controller.error != null) {
        AppToast.show(
          hostContext,
          widget.controller.error!,
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not play "${target.title}"',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<bool> _ensureSourceReachable() async {
    if (widget.target.isNetwork) return true;
    final validation = MediaSource.validate(widget.target.path);
    if (!validation.isValid || validation.source == null) return false;
    final normalized = MediaEntry.normalizeSourcePath(validation.source!);
    if (MediaEntry.isBufferedNetworkSource(normalized)) return true;
    try {
      return await File(normalized).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _enqueueTarget({required bool playNext}) async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    widget.onDismiss();
    if (!await _ensureSourceReachable()) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'File not found: ${target.title}',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    try {
      if (playNext) {
        await widget.controller.playNext([target.path]);
      } else {
        await widget.controller.addToQueue([target.path]);
      }
      if (!hostContext.mounted) return;
      final error = widget.controller.error;
      AppToast.show(
        hostContext,
        error ??
            (playNext
                ? 'Playing next: ${target.title}'
                : 'Added to queue: ${target.title}'),
        tone: error != null ? AppToastTone.danger : AppToastTone.neutral,
      );
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          playNext
              ? 'Could not queue "${target.title}" next'
              : 'Could not add "${target.title}" to queue',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _playNext() => _enqueueTarget(playNext: true);

  Future<void> _addToQueue() => _enqueueTarget(playNext: false);

  Future<void> _addToExistingPlaylist(PlaylistRecord playlist) async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    final repo = widget.repository;
    widget.onDismiss();
    try {
      await repo.addPathsToPlaylist(playlist.id, [target.path]);
      if (hostContext.mounted) {
        AppToast.show(hostContext, 'Added to "${playlist.title}"');
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not add item to playlist',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _createPlaylistAndAdd() async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    final repo = widget.repository;
    widget.onDismiss();
    if (!hostContext.mounted ||
        Navigator.maybeOf(hostContext, rootNavigator: true) == null) {
      return;
    }
    final created = await PlaylistCreateDialog.show(hostContext, repo);
    if (created == null) return;
    try {
      await repo.addPathsToPlaylist(created.id, [target.path]);
      if (hostContext.mounted) {
        AppToast.show(hostContext, 'Added to "${created.title}"');
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not add item to "${created.title}"',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _openWith() async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    widget.onDismiss();
    if (!await _ensureSourceReachable()) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'File not found: ${target.title}',
          tone: AppToastTone.danger,
        );
      }
      return;
    }
    try {
      final launched = await openWith(target.path);
      if (!launched && hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open system app chooser',
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open system app chooser',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _openInExplorer() async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    final onShow = widget.onShowInFolder;
    widget.onDismiss();
    if (onShow != null) {
      onShow(target.path);
      return;
    }
    try {
      final ok = await showInFolder(target.path);
      if (!ok && hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open File Explorer',
          tone: AppToastTone.danger,
        );
      }
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open File Explorer',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _showProperties() async {
    final target = widget.target;
    final hostContext = widget.hostContext;
    final repo = widget.repository;
    final onShow = widget.onShowInFolder;
    widget.onDismiss();
    if (!hostContext.mounted ||
        Navigator.maybeOf(hostContext, rootNavigator: true) == null) {
      return;
    }
    try {
      await MediaPropertiesDialog.show(
        hostContext,
        path: target.path,
        title: target.title,
        kind: target.kind,
        repository: repo,
        duration: target.duration,
        position: target.position,
        initialRecord: target.record,
        onShowInFolder: onShow,
      );
    } catch (_) {
      if (hostContext.mounted) {
        AppToast.show(
          hostContext,
          'Could not open properties',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  double _estimatedMenuHeight({required bool hasRemove}) {
    final rowCount = hasRemove ? 9 : 8;
    return _panelPadding * 2 + rowCount * _rowHeight + 2 * _dividerHeight;
  }

  Rect _computeSubmenuRect(Rect menuRect, Size viewport) {
    final playlistsCount = _playlists?.length ?? 0;
    final rowCount = 1 + (playlistsCount > 0 ? playlistsCount : 0);
    final dividerExtra = playlistsCount > 0 ? _dividerHeight : 0.0;
    final estimatedHeight =
        (_panelPadding * 2 + rowCount * _rowHeight + dividerExtra).clamp(
          48.0,
          320.0,
        );

    var top = menuRect.top + 3 * _rowHeight + _dividerHeight;
    final rowCtx = _playlistRowKey.currentContext;
    if (rowCtx != null) {
      final box = rowCtx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        top = box.localToGlobal(Offset.zero).dy - _panelPadding;
      }
    }

    var left = menuRect.right - 2;
    if (left + _submenuWidth > viewport.width - _viewportMargin) {
      left = menuRect.left - _submenuWidth + 2;
    }
    left = left.clamp(
      _viewportMargin,
      (viewport.width - _submenuWidth - _viewportMargin).clamp(
        _viewportMargin,
        double.infinity,
      ),
    );
    top = top.clamp(
      _viewportMargin,
      (viewport.height - estimatedHeight - _viewportMargin).clamp(
        _viewportMargin,
        double.infinity,
      ),
    );

    return Rect.fromLTWH(left, top, _submenuWidth, estimatedHeight);
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final hasRemove = widget.onRemove != null;
    final menuHeight = _estimatedMenuHeight(hasRemove: hasRemove);
    final menuLeft = widget.anchor.dx.clamp(
      _viewportMargin,
      (viewport.width - _menuWidth - _viewportMargin).clamp(
        _viewportMargin,
        double.infinity,
      ),
    );
    final menuTop = widget.anchor.dy.clamp(
      _viewportMargin,
      (viewport.height - menuHeight - _viewportMargin).clamp(
        _viewportMargin,
        double.infinity,
      ),
    );
    final menuRect = Rect.fromLTWH(menuLeft, menuTop, _menuWidth, menuHeight);
    final canPlay = widget.target.isAvailable;
    final canOpenWith = widget.target.isAvailable && !widget.target.isNetwork;
    final canOpenInExplorer = !widget.target.isNetwork;

    final submenuRect = _playlistSubmenuOpen
        ? _computeSubmenuRect(menuRect, viewport)
        : null;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
        if (canOpenInExplorer)
          const SingleActivator(LogicalKeyboardKey.f3): _openInExplorer,
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => widget.onDismiss(),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: menuRect.left,
              top: menuRect.top,
              width: _menuWidth,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  alignment: Alignment.topLeft,
                  scale: _scaleAnimation,
                  child: _MenuSurface(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _MenuRow(
                          icon: Icons.play_arrow_outlined,
                          label: 'Play',
                          enabled: canPlay,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _playNow,
                        ),
                        _MenuRow(
                          icon: Icons.queue_play_next_rounded,
                          label: 'Play next',
                          enabled: canPlay,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _playNext,
                        ),
                        _MenuRow(
                          icon: Icons.playlist_add_rounded,
                          label: 'Add to queue',
                          enabled: canPlay,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _addToQueue,
                        ),
                        const _MenuDivider(),
                        _MenuRow(
                          key: _playlistRowKey,
                          icon: Icons.library_add_outlined,
                          label: 'Add to playlist',
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: context.palette.mutedText,
                          ),
                          forceHighlighted: _playlistSubmenuOpen,
                          onHoverChanged: (hovering) {
                            _hoveringPlaylistRow = hovering;
                            if (hovering) {
                              _openSubmenuNow();
                            } else {
                              _scheduleSubmenuClose();
                            }
                          },
                          onTap: _openSubmenuNow,
                        ),
                        if (hasRemove)
                          _MenuRow(
                            icon: Icons.close_rounded,
                            label: 'Remove',
                            onHoverChanged: (hovering) {
                              if (hovering) _scheduleSubmenuClose();
                            },
                            onTap: () => _runAndClose(widget.onRemove!),
                          ),
                        _MenuRow(
                          icon: Icons.open_in_new_rounded,
                          label: 'Open with',
                          enabled: canOpenWith,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _openWith,
                        ),
                        _MenuRow(
                          icon: Icons.folder_outlined,
                          label: 'Open in File Explorer',
                          shortcut: 'F3',
                          enabled: canOpenInExplorer,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _openInExplorer,
                        ),
                        _MenuRow(
                          icon: Icons.info_outline_rounded,
                          label: 'Properties',
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: _showProperties,
                        ),
                        const _MenuDivider(),
                        _MenuRow(
                          icon: Icons.checklist_rounded,
                          label: widget.isSelected ? 'Deselect' : 'Select',
                          enabled: widget.onSelect != null,
                          onHoverChanged: (hovering) {
                            if (hovering) _scheduleSubmenuClose();
                          },
                          onTap: widget.onSelect == null
                              ? null
                              : () => _runAndClose(widget.onSelect!),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (submenuRect != null)
              Positioned(
                left: submenuRect.left,
                top: submenuRect.top,
                width: _submenuWidth,
                child: MouseRegion(
                  onEnter: (_) {
                    _hoveringSubmenu = true;
                    _submenuCloseTimer?.cancel();
                  },
                  onExit: (_) {
                    _hoveringSubmenu = false;
                    _scheduleSubmenuClose();
                  },
                  child: _MenuSurface(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _MenuRow(
                              icon: Icons.add_rounded,
                              label: 'New playlist...',
                              onTap: _createPlaylistAndAdd,
                            ),
                            if (_loadingPlaylists)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Text(
                                  'Loading playlists...',
                                  style: context.palette.metadata,
                                ),
                              )
                            else if ((_playlists ?? const []).isNotEmpty) ...[
                              const _MenuDivider(),
                              for (final playlist in _playlists!)
                                _MenuRow(
                                  icon: Icons.queue_music_rounded,
                                  label: playlist.title,
                                  shortcut: playlist.entryCount > 0
                                      ? '${playlist.entryCount}'
                                      : null,
                                  onTap: () => _addToExistingPlaylist(playlist),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuSurface extends StatelessWidget {
  const _MenuSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(AppRadii.control + 2),
          border: Border.all(color: palette.borderStrong),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      color: context.palette.border,
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.shortcut,
    this.trailing,
    this.enabled = true,
    this.forceHighlighted = false,
    this.onHoverChanged,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? shortcut;
  final Widget? trailing;
  final bool enabled;
  final bool forceHighlighted;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback? onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = widget.enabled && (_hovered || widget.forceHighlighted);
    final textColor = widget.enabled
        ? palette.primaryText
        : palette.mutedText.withValues(alpha: 0.6);
    final iconColor = widget.enabled
        ? palette.primaryText.withValues(alpha: 0.9)
        : palette.mutedText.withValues(alpha: 0.55);

    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
        widget.onHoverChanged?.call(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? palette.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control - 2),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: palette.rowPrimary.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w400,
                    color: textColor,
                  ),
                ),
              ),
              if (widget.shortcut != null) ...[
                const SizedBox(width: 12),
                Text(
                  widget.shortcut!,
                  style: palette.metadata.copyWith(
                    fontSize: 12,
                    color: widget.enabled
                        ? palette.mutedText
                        : palette.mutedText.withValues(alpha: 0.45),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ] else if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
