import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/toast_layout.dart';
import '../../core/components/seek_bar.dart';
import '../../core/components/app_mark.dart';
import '../../core/components/playback_pulse.dart';
import '../../player/widgets/queue_panel.dart';
import '../../player/widgets/player_controls.dart';
import '../widgets/audio_volume_control.dart';
import '../widgets/library_status_banner.dart';
import '../widgets/library_artwork.dart';
import 'music_view.dart';
import 'now_playing_view.dart';
import 'playlists_view.dart';
import 'videos_view.dart';

enum LibrarySection {
  home,
  videos,
  music,
  playlists,
  folders,
  nowPlaying,
  settings,
}

/// Top-level shell integrating navigation, search, content stage, and responsive layout.
class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.repository,
    required this.controller,
    this.initialSection = LibrarySection.home,
    this.home,
    this.onOpenFiles,
    this.onOpenUrl,
    this.onAddQueueFiles,
    this.onAddFolders,
    this.onShowInFolder,
    this.onBackToPlayer,
    this.settings,
    this.folders,
    this.showSettings = false,
    this.onSettings,
    this.onCloseSettings,
    this.homeNavigationRequest = 0,
    this.queueOpen,
    this.onQueueOpenChanged,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final LibrarySection initialSection;
  final Widget? home;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenUrl;
  final VoidCallback? onAddQueueFiles;
  final VoidCallback? onAddFolders;
  final ValueChanged<String>? onShowInFolder;
  final VoidCallback? onBackToPlayer;
  final Widget? settings;
  final Widget? folders;
  final bool showSettings;
  final VoidCallback? onSettings;
  final VoidCallback? onCloseSettings;
  final int homeNavigationRequest;
  final bool? queueOpen;
  final ValueChanged<bool>? onQueueOpenChanged;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell>
    with TickerProviderStateMixin {
  late LibrarySection _currentSection;
  LibrarySection _previousSection = LibrarySection.home;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _searchQuery = '';
  bool _isOnDemandQueueOpen = false;

  late final AnimationController _nowPlayingMorphController =
      AnimationController(
        vsync: this,
        duration: AppMotion.sheetEnter,
        reverseDuration: AppMotion.sheetExit,
        value: widget.initialSection == LibrarySection.nowPlaying ? 1.0 : 0.0,
      );

  late final Animation<double> _nowPlayingMorphCurve = CurvedAnimation(
    parent: _nowPlayingMorphController,
    curve: AppMotion.sheetEnterCurve,
    reverseCurve: AppMotion.sheetExitCurve,
  );

  late final AnimationController _miniPlayerVisibilityController =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
        reverseDuration: const Duration(milliseconds: 220),
        value: widget.controller.hasMedia ? 1.0 : 0.0,
      );

  late final Animation<double> _miniPlayerVisibilityCurve = CurvedAnimation(
    parent: _miniPlayerVisibilityController,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );

  MediaEntry? _lastDisplayEntry;

  bool get _isQueueOpen => widget.queueOpen ?? _isOnDemandQueueOpen;

  void _setQueueOpen(bool next) {
    setState(() => _isOnDemandQueueOpen = next);
    widget.onQueueOpenChanged?.call(next);
  }

  @override
  void initState() {
    super.initState();
    _currentSection = widget.showSettings
        ? LibrarySection.settings
        : widget.initialSection;
    _isOnDemandQueueOpen = widget.queueOpen ?? false;
    _lastDisplayEntry = widget.controller.current;
    _searchController.addListener(_onSearchChanged);
    widget.controller.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(LibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlaybackChanged);
      widget.controller.addListener(_onPlaybackChanged);
    }
    if (widget.queueOpen != oldWidget.queueOpen && widget.queueOpen != null) {
      _isOnDemandQueueOpen = widget.queueOpen!;
    }
    if (widget.showSettings != oldWidget.showSettings) {
      if (widget.showSettings) {
        _previousSection = _currentSection;
        _currentSection = LibrarySection.settings;
      } else if (_currentSection == LibrarySection.settings) {
        _currentSection = _previousSection;
      }
    }
    if (widget.homeNavigationRequest != oldWidget.homeNavigationRequest) {
      _searchController.removeListener(_onSearchChanged);
      _searchController.clear();
      _searchController.addListener(_onSearchChanged);
      _searchQuery = '';
      _currentSection = LibrarySection.home;
      _previousSection = LibrarySection.home;
      _isOnDemandQueueOpen = false;
      if (_nowPlayingMorphController.value > 0) {
        _nowPlayingMorphController.value = 0.0;
      }
    }
  }

  @override
  void dispose() {
    _nowPlayingMorphController.dispose();
    _miniPlayerVisibilityController.dispose();
    widget.controller.removeListener(_onPlaybackChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    final current = widget.controller.current;
    final hasMedia = widget.controller.hasMedia;

    if (current != null) {
      _lastDisplayEntry = current;
    }

    if (current == null &&
        (_currentSection == LibrarySection.nowPlaying ||
            _nowPlayingMorphController.value > 0)) {
      _closeNowPlaying();
    }

    if (hasMedia) {
      if (_miniPlayerVisibilityController.value < 1.0 &&
          _miniPlayerVisibilityController.status != AnimationStatus.forward) {
        if (AppMotion.reduce(context)) {
          _miniPlayerVisibilityController.value = 1.0;
        } else {
          _miniPlayerVisibilityController.forward();
        }
      }
    } else {
      if (_miniPlayerVisibilityController.value > 0.0 &&
          _miniPlayerVisibilityController.status != AnimationStatus.reverse) {
        if (AppMotion.reduce(context)) {
          _miniPlayerVisibilityController.value = 0.0;
          _lastDisplayEntry = null;
          if (mounted) setState(() {});
        } else {
          _miniPlayerVisibilityController.reverse().then((_) {
            if (mounted && !widget.controller.hasMedia) {
              setState(() {
                _lastDisplayEntry = null;
              });
            }
          });
        }
      }
    }
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
    });
  }

  void _openNowPlaying() {
    if (_currentSection != LibrarySection.nowPlaying) {
      _previousSection = _currentSection;
      _currentSection = LibrarySection.nowPlaying;
    }
    if (AppMotion.reduce(context)) {
      _nowPlayingMorphController.value = 1.0;
      if (mounted) setState(() {});
    } else {
      _nowPlayingMorphController.forward();
      if (mounted) setState(() {});
    }
  }

  void _closeNowPlaying() {
    if (AppMotion.reduce(context)) {
      _nowPlayingMorphController.value = 0.0;
      if (mounted) {
        setState(() {
          _currentSection = _previousSection;
        });
      }
    } else {
      _nowPlayingMorphController.reverse().then((_) {
        if (mounted) {
          setState(() {
            _currentSection = _previousSection;
          });
        }
      });
    }
  }

  void _selectSection(LibrarySection section) {
    if (section == LibrarySection.settings && widget.onSettings != null) {
      widget.onSettings!();
      return;
    }
    if (_currentSection == section) return;
    if (_currentSection == LibrarySection.settings) {
      widget.onCloseSettings?.call();
    }
    _searchController.clear();

    if (section == LibrarySection.nowPlaying) {
      _openNowPlaying();
      return;
    }

    if (_nowPlayingMorphController.value > 0) {
      _closeNowPlaying();
    }

    setState(() {
      _currentSection = section;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktopWide = width >= 1180;
        final isDesktopMedium = width >= 960 && width < 1180;
        final isCompact = width < 960;

        return Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            final focused = FocusManager.instance.primaryFocus?.context;
            final editing =
                focused?.widget is EditableText ||
                focused?.findAncestorWidgetOfExactType<EditableText>() != null;
            if (!editing &&
                event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.slash) {
              _searchFocus.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
              ): () =>
                  _searchFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_nowPlayingMorphController.value > 0) {
                  _closeNowPlaying();
                }
              },
            },
            child: PlaybackPulseScope(
              controller: widget.controller,
              child: Scaffold(
                key: _scaffoldKey,
                backgroundColor: context.palette.background,
                drawer: isCompact ? _buildNavigationDrawer() : null,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              // 1. Navigation: 208px sidebar on >=1180, collapsed 64px rail on 960-1179, drawer on <960
                              if (isDesktopWide) ...[
                                ToastRegion(
                                  child: SizedBox(
                                    width: 208,
                                    child: _buildSideNav(isCollapsed: false),
                                  ),
                                ),
                                VerticalDivider(
                                  width: 1,
                                  color: context.palette.border,
                                ),
                              ] else if (isDesktopMedium) ...[
                                ToastRegion(
                                  child: SizedBox(
                                    width: 64,
                                    child: _buildSideNav(isCollapsed: true),
                                  ),
                                ),
                                VerticalDivider(
                                  width: 1,
                                  color: context.palette.border,
                                ),
                              ],

                              // 2. Main Content Area: Top bar + Status Banner + Active Stage
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // Header Bar (Search & Mobile Drawer Trigger)
                                    if (_currentSection !=
                                        LibrarySection.settings)
                                      AnimatedBuilder(
                                        animation: widget.controller,
                                        builder: (context, _) => _buildHeaderBar(
                                          isCompact,
                                          !isCompact,
                                          showBackLabel: width >= 600,
                                        ),
                                      ),
                                    // Status Banners (Scanning indicator, Unavailable drive warning)
                                    LibraryStatusBanner(
                                      repository: widget.repository,
                                      onRescan: () =>
                                          widget.repository.rescanAll(),
                                    ),
                                    // Main Stage View
                                    Expanded(child: _buildContentStage()),
                                  ],
                                ),
                              ),

                              // 3. Docked Queue Panel
                              if (!isCompact && _isQueueOpen) ...[
                                VerticalDivider(
                                  width: 1,
                                  color: context.palette.border,
                                ),
                                ToastRegion(
                                  child: SizedBox(
                                    width: 280,
                                    child: QueuePanel(
                                      controller: widget.controller,
                                      onQueueFocus: (_) {},
                                      onAddFiles:
                                          widget.onAddQueueFiles ?? () {},
                                      onClose: () => _setQueueOpen(false),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        ToastRegion(child: _buildBottomMiniPlayer(isCompact)),
                      ],
                    ),
                    _buildNowPlayingMorphOverlay(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Header Bar ---

  Widget _buildHeaderBar(
    bool isCompact,
    bool canDockQueue, {
    required bool showBackLabel,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    final queueOpen = _isQueueOpen;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      // Matches the stage behind it so the header and the content read as one
      // continuous surface instead of two blocks split by a rule.
      color: context.palette.background,
      child: Row(
        children: [
          if (widget.onBackToPlayer != null) ...[
            if (showBackLabel)
              TextButton.icon(
                onPressed: widget.onBackToPlayer,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                label: const Text('Return to video'),
                style: TextButton.styleFrom(
                  foregroundColor: context.palette.primaryText,
                ),
              )
            else
              IconButton(
                onPressed: widget.onBackToPlayer,
                tooltip: 'Return to video',
                icon: const Icon(Icons.arrow_back_rounded),
                color: context.palette.primaryText,
              ),
            const SizedBox(width: 8),
          ],
          if (isCompact) ...[
            IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Open navigation',
              color: context.palette.primaryText,
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 8),
          ],
          // Search input field
          Expanded(
            child: _currentSection == LibrarySection.home
                ? const SizedBox.shrink()
                : _currentSection == LibrarySection.nowPlaying ||
                      _currentSection == LibrarySection.settings ||
                      _currentSection == LibrarySection.folders
                ? Text(
                    _currentSection == LibrarySection.nowPlaying
                        ? 'Now playing'
                        : _currentSection == LibrarySection.settings
                        ? 'Settings'
                        : 'Folders',
                    style: context.palette.sectionTitle,
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: SizedBox(
                        height: 38,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          style: context.palette.rowPrimary.copyWith(
                            fontSize: AppType.small,
                          ),
                          cursorColor: accent,
                          decoration: InputDecoration(
                            hintText: 'Search ${_sectionName(_currentSection)}',
                            hintStyle: context.palette.metadata,
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: context.palette.mutedText,
                            ),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    color: context.palette.mutedText,
                                    tooltip: 'Clear search',
                                    onPressed: () => _searchController.clear(),
                                  )
                                : null,
                            filled: true,
                            fillColor: context.palette.raisedSurface,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: AppSpace.xs,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide(
                                color: context.palette.border,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide(color: accent, width: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (_currentSection != LibrarySection.home &&
              widget.onOpenFiles != null)
            IconButton(
              onPressed: widget.onOpenFiles,
              tooltip: 'Open file',
              icon: const Icon(Icons.file_open_rounded),
            ),
          if (_currentSection != LibrarySection.home &&
              widget.onOpenUrl != null)
            IconButton(
              onPressed: widget.onOpenUrl,
              tooltip: 'Open URL',
              icon: const Icon(Icons.link_rounded),
            ),
          const SizedBox(width: 12),
          // Medium screen On-Demand Queue Toggle
          if (canDockQueue) ...[
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(
                Icons.queue_music_rounded,
                size: 20,
                color: queueOpen ? accent : context.palette.secondaryText,
              ),
              tooltip: queueOpen ? 'Close queue' : 'Open queue',
              onPressed: () => _setQueueOpen(!queueOpen),
            ),
          ],
        ],
      ),
    );
  }

  String _sectionName(LibrarySection s) {
    return switch (s) {
      LibrarySection.home => 'home',
      LibrarySection.videos => 'videos',
      LibrarySection.music => 'music',
      LibrarySection.playlists => 'playlists',
      LibrarySection.folders => 'folders',
      LibrarySection.nowPlaying => 'now playing',
      LibrarySection.settings => 'settings',
    };
  }

  // --- Content Stage ---

  Widget _buildContentStage() {
    final effectiveSection = _currentSection == LibrarySection.nowPlaying
        ? _previousSection
        : _currentSection;
    final Widget stage;
    switch (effectiveSection) {
      case LibrarySection.home:
        stage = widget.home ?? const SizedBox.shrink();
      case LibrarySection.settings:
        stage = widget.settings ?? const SizedBox.shrink();
      case LibrarySection.folders:
        stage = widget.folders ?? const SizedBox.shrink();
      case LibrarySection.videos:
        stage = VideosView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
          onAddFolders: widget.onAddFolders,
          onShowInFolder: widget.onShowInFolder,
        );
      case LibrarySection.music:
        stage = MusicView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
          onAddFolders: widget.onAddFolders,
          onShowInFolder: widget.onShowInFolder,
        );
      case LibrarySection.playlists:
        stage = PlaylistsView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
        );
      case LibrarySection.nowPlaying:
        stage = widget.home ?? const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: AppMotion.duration(context, AppMotion.stage),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) =>
            AppMotion.stageTransition(context, child, animation),
        child: KeyedSubtree(
          key: ValueKey<LibrarySection>(effectiveSection),
          child: stage,
        ),
      ),
    );
  }

  /// Morphing full Now Playing player sheet overlay.
  ///
  /// Expands smoothly upwards from the bottom edge to cover the entire window,
  /// achieving a seamless 60fps morph even on low-end hardware by utilizing
  /// purely compositor-driven translation over an opaque background with elevation shadow.
  Widget _buildNowPlayingMorphOverlay() {
    return AnimatedBuilder(
      animation: _nowPlayingMorphCurve,
      builder: (context, _) {
        final progress = _nowPlayingMorphCurve.value;
        if (progress <= 0.0001) return const SizedBox.shrink();

        final reduced = AppMotion.reduce(context);
        final slideOffset = reduced ? Offset.zero : Offset(0.0, 1.0 - progress);

        return Positioned.fill(
          child: FractionalTranslation(
            translation: slideOffset,
            child: RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.palette.background,
                  border: Border(top: BorderSide(color: context.palette.border)),
                ),
                child: NowPlayingView(
                  controller: widget.controller,
                  repository: widget.repository,
                  onBack: _closeNowPlaying,
                  onOpenQueue: _showCompactQueue,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Side Navigation & Collapsed Rail ---

  Widget _buildSideNav({required bool isCollapsed}) {
    return Container(
      color: context.palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The brand block used to sit above the nav items; it is dropped so
          // the sidebar starts straight into navigation and the window top is
          // not split between "Mpvson" and the stage's own title.
          const SizedBox(height: 12),
          // Nav Items
          _navItem(
            LibrarySection.home,
            'Home',
            Icons.home_rounded,
            Icons.home_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.videos,
            'Videos',
            Icons.movie_rounded,
            Icons.movie_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.music,
            'Music',
            Icons.music_note_rounded,
            Icons.music_note_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.playlists,
            'Playlists',
            Icons.queue_music_rounded,
            Icons.queue_music_rounded,
            isCollapsed,
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: context.palette.border),
          const SizedBox(height: 8),
          _navItem(
            LibrarySection.folders,
            'Folders',
            Icons.folder_rounded,
            Icons.folder_rounded,
            isCollapsed,
          ),
          const Spacer(),
          if (widget.onSettings != null)
            _navItem(
              LibrarySection.settings,
              'Settings',
              Icons.settings_rounded,
              Icons.settings_rounded,
              isCollapsed,
            ),
        ],
      ),
    );
  }

  Widget _navItem(
    LibrarySection section,
    String label,
    IconData unselectedIcon,
    IconData selectedIcon,
    bool isCollapsed,
  ) {
    final isSelected = _currentSection == section;
    final accent = Theme.of(context).colorScheme.primary;
    final icon = selectedIcon;

    if (isCollapsed) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isSelected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(
          vertical: AppSpace.xxs,
          horizontal: AppSpace.xs,
        ),
        child: IconButton(
          icon: Icon(icon, size: 22),
          tooltip: label,
          color: isSelected ? accent : context.palette.secondaryText,
          style: IconButton.styleFrom(
            backgroundColor: isSelected
                ? accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          onPressed: () => _selectSection(section),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      child: InkWell(
        onTap: () => _selectSection(section),
        borderRadius: BorderRadius.circular(AppRadii.control),
        hoverColor: context.palette.hover,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.sm,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? accent.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border(
              left: BorderSide(
                color: isSelected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? accent : context.palette.secondaryText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppType.small,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? accent : context.palette.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Drawer for < 960px Screens ---

  Widget _buildNavigationDrawer() {
    return Drawer(
      backgroundColor: context.palette.sidebar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, AppSpace.md),
              child: Row(
                children: [
                  const AppMark(size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Mpvson',
                      style: TextStyle(
                        color: context.palette.primaryText,
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.border),
            const SizedBox(height: 8),
            _drawerItem(LibrarySection.home, 'Home', Icons.home_rounded),
            _drawerItem(LibrarySection.videos, 'Videos', Icons.movie_rounded),
            _drawerItem(
              LibrarySection.music,
              'Music',
              Icons.music_note_rounded,
            ),
            _drawerItem(
              LibrarySection.playlists,
              'Playlists',
              Icons.queue_music_rounded,
            ),
            _drawerItem(
              LibrarySection.folders,
              'Folders',
              Icons.folder_rounded,
            ),
            const Spacer(),
            if (widget.onSettings != null)
              _drawerItem(
                LibrarySection.settings,
                'Settings',
                Icons.settings_rounded,
              ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(LibrarySection section, String label, IconData icon) {
    final isSelected = _currentSection == section;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isSelected ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: ListTile(
        selected: isSelected,
        selectedColor: accent,
        tileColor: isSelected
            ? accent.withValues(alpha: 0.10)
            : Colors.transparent,
        leading: Icon(
          icon,
          color: isSelected ? accent : context.palette.secondaryText,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: isSelected ? accent : context.palette.secondaryText,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onTap: () {
          _selectSection(section);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showCompactQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.surface,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.8,
        child: QueuePanel(
          controller: widget.controller,
          onClose: () => Navigator.of(sheetContext).pop(),
          onQueueFocus: (_) {},
          onAddFiles: widget.onAddQueueFiles ?? () {},
        ),
      ),
    );
  }

  // --- Stacked Audio Layout (Bottom Mini Player) ---

  Widget _buildBottomMiniPlayer(bool isCompact) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _miniPlayerVisibilityCurve,
        _nowPlayingMorphCurve,
        widget.controller,
      ]),
      builder: (context, _) {
        final visibility = _miniPlayerVisibilityCurve.value;
        if (visibility <= 0.001) {
          return const SizedBox.shrink();
        }

        final displayEntry = widget.controller.current ?? _lastDisplayEntry;
        if (displayEntry == null) {
          return const SizedBox.shrink();
        }

        final isVideo =
            widget.controller.isVideo ||
            MediaCatalog.kindFromExtension(displayEntry.path).isVideo;

        final morph = _nowPlayingMorphCurve.value;
        // As the full sheet rises over the mini player, gently fade out the mini-player's controls
        // so there is zero visual overlap with the rising sheet.
        final controlsFade = (1.0 - (morph * 2.5)).clamp(0.0, 1.0);

        final barContent = _buildMiniPlayerBar(
          context,
          displayEntry,
          isVideo,
          isCompact,
          controlsOpacity: controlsFade,
        );

        final reduced = AppMotion.reduce(context);
        if (reduced) {
          return RepaintBoundary(
            child: SizedBox(height: 84, child: barContent),
          );
        }

        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: visibility,
            child: FractionalTranslation(
              translation: Offset(0, 0.4 * (1.0 - visibility)),
              child: Opacity(
                opacity: visibility.clamp(0.0, 1.0),
                child: RepaintBoundary(
                  child: SizedBox(height: 84, child: barContent),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMiniPlayerBar(
    BuildContext context,
    MediaEntry current,
    bool isVideo,
    bool isCompact, {
    double controlsOpacity = 1.0,
  }) {
    final title = current.title;
    return Container(
      decoration: BoxDecoration(
        color: context.palette.sidebar,
        border: Border(top: BorderSide(color: context.palette.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AudioVolumeWheel(
            controller: widget.controller,
            child: Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap:
                        widget.controller.isVideo &&
                            widget.onBackToPlayer != null
                        ? widget.onBackToPlayer
                        : _openNowPlaying,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    hoverColor: context.palette.hover,
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.artwork),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                LibraryArtwork(
                                  mediaPath: current.path,
                                  repository: widget.repository,
                                  iconSize: 20,
                                ),
                                if (widget.controller.isPlaying && !isVideo)
                                  Positioned(
                                    right: 2,
                                    bottom: 2,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.75,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const PlayingEqualizerGlyph(
                                        isPlaying: true,
                                        size: 10,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Title and subtitle both come from the library
                        // record when it exists, so the bar and the Now
                        // Playing screen never disagree about a track.
                        Expanded(
                          child: _MiniPlayerSubtitle(
                            key: ValueKey(current.path),
                            repository: widget.repository,
                            path: current.path,
                            fallbackTitle: title,
                            isVideo: isVideo,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Opacity(
                  opacity: controlsOpacity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TransportButtons(
                        controller: widget.controller,
                        compact: isCompact,
                      ),
                      AudioVolumeControl(
                        controller: widget.controller,
                        compact: true,
                        showPercent: !isCompact,
                      ),
                      if (isCompact) ...[
                        IconButton(
                          icon: Icon(
                            Icons.queue_music_rounded,
                            size: 20,
                            color: context.palette.secondaryText,
                          ),
                          tooltip: 'Queue',
                          onPressed: _showCompactQueue,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: 24, child: SeekBar(controller: widget.controller)),
        ],
      ),
    );
  }
}

/// Title and subtitle for the bottom transport bar.
///
/// The controller notifies for many transport changes; resolving the library
/// record once per track instead of once per rebuild keeps those notifications
/// from issuing a database query each time. Both lines prefer the record so the
/// bar and the Now Playing screen show the same title and artist.
class _MiniPlayerSubtitle extends StatefulWidget {
  const _MiniPlayerSubtitle({
    super.key,
    required this.repository,
    required this.path,
    required this.fallbackTitle,
    required this.isVideo,
  });

  final MediaLibraryRepository repository;
  final String path;
  final String fallbackTitle;
  final bool isVideo;

  @override
  State<_MiniPlayerSubtitle> createState() => _MiniPlayerSubtitleState();
}

class _MiniPlayerSubtitleState extends State<_MiniPlayerSubtitle> {
  Future<MediaItemRecord?>? _record;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onRepositoryChanged);
    _resolve();
  }

  @override
  void didUpdateWidget(_MiniPlayerSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
    }
    if (oldWidget.path != widget.path ||
        oldWidget.repository != widget.repository ||
        oldWidget.isVideo != widget.isVideo) {
      _resolve();
    }
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onRepositoryChanged() {
    if (!widget.isVideo && _record == null && widget.repository.isReady) {
      setState(_resolve);
    }
  }

  void _resolve() {
    if (widget.isVideo || !widget.repository.isReady) {
      _record = null;
      return;
    }
    _record = widget.repository
        .getMediaByCanonicalSource(widget.path)
        .catchError((Object _) => null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isVideo) {
      return _lines(widget.fallbackTitle, 'Video');
    }
    final record = _record;
    if (record == null) {
      return _lines(widget.fallbackTitle, 'Unknown artist');
    }
    return FutureBuilder<MediaItemRecord?>(
      future: record,
      builder: (context, snapshot) => _lines(
        snapshot.data?.title ?? widget.fallbackTitle,
        snapshot.data?.artist ?? 'Unknown artist',
      ),
    );
  }

  Widget _lines(String title, String subtitle) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: context.palette.rowPrimary.copyWith(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 2),
      Text(
        subtitle,
        style: context.palette.metadata,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );
}
