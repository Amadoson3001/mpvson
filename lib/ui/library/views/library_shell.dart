import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/toast_layout.dart';
import '../../core/components/playback_pulse.dart';
import '../../player/widgets/queue_panel.dart';
import '../../player/views/player_queue_layout.dart';
import '../widgets/library_status_banner.dart';
import 'library_navigation.dart';
import 'library_section.dart';
import 'library_top_bar.dart';
import 'mini_player_bar.dart';
import 'music_view.dart';
import 'now_playing_view.dart';
import 'playlists_view.dart';
import 'videos_view.dart';

export 'library_section.dart';

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

  /// Keyboard focus falls back here when the Now Playing sheet excludes the
  /// background from focus, so shortcut keys (Esc, Ctrl+K) keep working: the
  /// scope sits below [CallbackShortcuts], and key events bubble through it.
  final _shellFocusScope = FocusScopeNode(debugLabel: 'Library shell');
  String _searchQuery = '';
  bool _isOnDemandQueueOpen = false;

  /// Bumped on every explicit section change. Async section restores (the
  /// delayed [AnimationController.reverse] callback) capture the value when
  /// they start and discard themselves when it has moved on, so a restore
  /// that races a user click can never clobber the clicked section.
  int _sectionGeneration = 0;

  late final AnimationController _nowPlayingMorphController =
      AnimationController(
        vsync: this,
        duration: AppMotion.sheetEnter,
        reverseDuration: AppMotion.sheetExit,
        value:
            widget.initialSection == LibrarySection.nowPlaying &&
                !widget.showSettings
            ? 1.0
            : 0.0,
      );

  late final CurvedAnimation _nowPlayingMorphCurve = CurvedAnimation(
    parent: _nowPlayingMorphController,
    curve: AppMotion.sheetEnterCurve,
    reverseCurve: AppMotion.sheetExitCurve,
  );

  late final AnimationController _miniPlayerVisibilityController =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
        reverseDuration: const Duration(milliseconds: 220),
        value: (widget.controller.hasMedia && !widget.controller.isStopped)
            ? 1.0
            : 0.0,
      );

  late final CurvedAnimation _miniPlayerVisibilityCurve = CurvedAnimation(
    parent: _miniPlayerVisibilityController,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );

  late final AnimationController _queueSlide;
  late final CurvedAnimation _queueSlideCurve;
  bool _queueMounted = false;

  MediaEntry? _lastDisplayEntry;

  bool get _isQueueOpen => widget.queueOpen ?? _isOnDemandQueueOpen;

  void _setQueueOpen(bool next) {
    setState(() {
      _isOnDemandQueueOpen = next;
      if (next) _queueMounted = true;
    });
    widget.onQueueOpenChanged?.call(next);
    _driveQueueSlide();
  }

  void _driveQueueSlide() {
    if (_isQueueOpen) {
      _queueSlide.forward();
    } else {
      _queueSlide.reverse();
    }
  }

  void _handleQueueSlideStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // A zero-length reverse can finish inside the build phase; unmount at the
    // end of the frame instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _queueMounted = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _currentSection = widget.showSettings
        ? LibrarySection.settings
        : widget.initialSection;
    _previousSection = widget.initialSection;
    _isOnDemandQueueOpen = widget.queueOpen ?? false;
    _queueMounted = _isQueueOpen;
    _queueSlide = AnimationController(
      vsync: this,
      duration: AppMotion.panelEnter,
      reverseDuration: AppMotion.panelExit,
      value: _isQueueOpen ? 1.0 : 0.0,
    )..addStatusListener(_handleQueueSlideStatus);
    _queueSlideCurve = CurvedAnimation(
      parent: _queueSlide,
      curve: AppMotion.panelEnterCurve,
      reverseCurve: AppMotion.exit,
    );
    _lastDisplayEntry = widget.controller.current;
    _searchController.addListener(_onSearchChanged);
    widget.controller.addListener(_onPlaybackChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduce(context);
    _queueSlide.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelEnter);
    _queueSlide.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelExit);
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
      if (_isOnDemandQueueOpen) _queueMounted = true;
      _driveQueueSlide();
    }
    if (widget.showSettings != oldWidget.showSettings) {
      if (widget.showSettings) {
        _sectionGeneration++;
        // Opening Settings over the Now Playing sheet: dismiss the sheet
        // immediately (no delayed restore) and show the real pre-sheet
        // section behind Settings, so closing Settings cannot land on a
        // stale one and Esc never races the morph animation.
        if (_currentSection == LibrarySection.nowPlaying ||
            _nowPlayingMorphController.value > 0) {
          _nowPlayingMorphController
            ..stop()
            ..value = 0.0;
          _currentSection = _previousSection;
        }
        _previousSection = _currentSection;
        _currentSection = LibrarySection.settings;
      } else if (_currentSection == LibrarySection.settings) {
        _sectionGeneration++;
        _currentSection = _previousSection;
      }
    }
    if (widget.homeNavigationRequest != oldWidget.homeNavigationRequest) {
      _sectionGeneration++;
      _searchController.removeListener(_onSearchChanged);
      _searchController.clear();
      _searchController.addListener(_onSearchChanged);
      _searchQuery = '';
      _currentSection = LibrarySection.home;
      _previousSection = LibrarySection.home;
      _isOnDemandQueueOpen = false;
      if (_nowPlayingMorphController.value > 0) {
        _nowPlayingMorphController
          ..stop()
          ..value = 0.0;
      }
    }
  }

  @override
  void dispose() {
    _queueSlide.removeStatusListener(_handleQueueSlideStatus);
    _queueSlideCurve.dispose();
    _queueSlide.dispose();
    _nowPlayingMorphCurve.dispose();
    _miniPlayerVisibilityCurve.dispose();
    _nowPlayingMorphController.dispose();
    _miniPlayerVisibilityController.dispose();
    widget.controller.removeListener(_onPlaybackChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _shellFocusScope.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    final current = widget.controller.current;
    final hasMedia = widget.controller.hasMedia;

    if (current != null && current != _lastDisplayEntry) {
      setState(() {
        _lastDisplayEntry = current;
      });
    }

    if (current == null &&
        (_currentSection == LibrarySection.nowPlaying ||
            _nowPlayingMorphController.value > 0)) {
      _closeNowPlaying();
    }

    if (hasMedia && !widget.controller.isStopped) {
      if (_miniPlayerVisibilityController.value < 1.0 &&
          _miniPlayerVisibilityController.status != AnimationStatus.forward) {
        if (AppMotion.reduce(context)) {
          _miniPlayerVisibilityController.value = 1.0;
        } else {
          _miniPlayerVisibilityController.forward();
        }
      }
    } else {
      if (_miniPlayerVisibilityController.value > 0.0) {
        _miniPlayerVisibilityController.value = 0.0;
      }
      if (_lastDisplayEntry != null) {
        _lastDisplayEntry = null;
      }
      if (mounted) setState(() {});
    }
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
    });
  }

  void _openNowPlaying() {
    if (_currentSection == LibrarySection.nowPlaying &&
        _nowPlayingMorphController.value > 0) {
      return;
    }
    _sectionGeneration++;
    if (_currentSection == LibrarySection.settings) {
      // Now Playing replaces the embedded Settings; leave Settings in this
      // frame so the parent's later didUpdateWidget pass cannot restore it.
      widget.onCloseSettings?.call();
      _currentSection = _previousSection;
    }
    _previousSection = _currentSection;
    _currentSection = LibrarySection.nowPlaying;
    if (AppMotion.reduce(context)) {
      _nowPlayingMorphController.value = 1.0;
      if (mounted) setState(() {});
    } else {
      _nowPlayingMorphController.forward();
      if (mounted) setState(() {});
    }
  }

  void _closeNowPlaying() {
    if (_nowPlayingMorphController.status == AnimationStatus.dismissed) {
      return;
    }
    final token = _sectionGeneration;
    void restore() {
      if (!mounted) return;
      // Stale restore: the user picked another section (or opened Settings)
      // while the sheet was animating out, so that interaction already owns
      // the stage. Discard instead of clobbering the clicked section.
      if (token != _sectionGeneration) return;
      if (_currentSection != LibrarySection.nowPlaying) return;
      setState(() => _currentSection = _previousSection);
    }

    if (AppMotion.reduce(context)) {
      _nowPlayingMorphController.value = 0.0;
      restore();
    } else {
      _nowPlayingMorphController.reverse().then((_) => restore());
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
      // Leave Settings in this frame; the parent's onCloseSettings only
      // confirms it and its didUpdateWidget pass must not re-restore.
      setState(() => _currentSection = _previousSection);
    }
    _searchController.clear();
    _sectionGeneration++;

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
        final isDesktopMedium =
            width >= AppLayout.mediumBreakpoint && width < 1180;
        final isCompact = width < AppLayout.mediumBreakpoint;

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
                if (_currentSection == LibrarySection.settings) {
                  // Esc closes the embedded Settings first so it can never
                  // race the Now Playing morph for the same keypress.
                  widget.onCloseSettings?.call();
                } else if (_nowPlayingMorphController.value > 0) {
                  _closeNowPlaying();
                }
              },
            },
            child: FocusScope(
              node: _shellFocusScope,
              child: PlaybackPulseScope(
                controller: widget.controller,
                child: Scaffold(
                  key: _scaffoldKey,
                  backgroundColor: context.palette.background,
                  drawer: isCompact
                      ? ShellNavigationDrawer(
                          section: _currentSection,
                          onSelect: (section) {
                            _selectSection(section);
                            Navigator.of(context).pop();
                          },
                          showSettings: widget.onSettings != null,
                        )
                      : null,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      // While the Now Playing sheet is up the library behind it
                      // is inert: nothing back there can take focus or be read
                      // by assistive tech until the sheet has left.
                      AnimatedBuilder(
                        animation: _nowPlayingMorphCurve,
                        builder: (context, _) {
                          final sheetUp = _nowPlayingMorphCurve.value > 0;
                          return ExcludeFocus(
                            excluding: sheetUp,
                            child: ExcludeSemantics(
                              excluding: sheetUp,
                              child: Column(
                                children: [
                                  Expanded(
                                    child: _buildBodyRow(
                                      isDesktopWide,
                                      isDesktopMedium,
                                      isCompact,
                                    ),
                                  ),
                                  ToastRegion(
                                    child: _buildBottomMiniPlayer(isCompact),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      _buildNowPlayingMorphOverlay(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Sidebar + top bar + stage + docked queue, all wired to their modules.
  Widget _buildBodyRow(
    bool isDesktopWide,
    bool isDesktopMedium,
    bool isCompact,
  ) {
    return Row(
      children: [
        // 1. Navigation: 208px sidebar on >=1180, collapsed 64px rail on
        // 960-1179, drawer on <960.
        if (isDesktopWide) ...[
          ToastRegion(
            child: SizedBox(
              width: AppLayout.sidebarExpanded,
              child: ShellSideNav(
                section: _currentSection,
                onSelect: _selectSection,
                collapsed: false,
                showSettings: widget.onSettings != null,
              ),
            ),
          ),
          VerticalDivider(width: 1, color: context.palette.border),
        ] else if (isDesktopMedium) ...[
          ToastRegion(
            child: SizedBox(
              width: AppLayout.sidebarCollapsed,
              child: ShellSideNav(
                section: _currentSection,
                onSelect: _selectSection,
                collapsed: true,
                showSettings: widget.onSettings != null,
              ),
            ),
          ),
          VerticalDivider(width: 1, color: context.palette.border),
        ],

        // 2. Main Content Area: Top bar + Status Banner + Active Stage
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // System status stays anchored at the top of every section,
              // above section chrome.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: LibraryStatusBanner(
                    repository: widget.repository,
                    onRescan: () => widget.repository.rescanAll(),
                  ),
                ),
              ),
              // Top bar (search & compact drawer trigger).
              if (_currentSection != LibrarySection.settings)
                LibraryTopBar(
                  section: _currentSection,
                  compact: isCompact,
                  canDockQueue: !isCompact,
                  queueOpen: _isQueueOpen,
                  searchController: _searchController,
                  searchFocus: _searchFocus,
                  onOpenNavigation: () =>
                      _scaffoldKey.currentState?.openDrawer(),
                  onToggleQueue: () => _setQueueOpen(!_isQueueOpen),
                  onBackToPlayer: widget.onBackToPlayer,
                  onOpenFiles: widget.onOpenFiles,
                  onOpenUrl: widget.onOpenUrl,
                ),
              // Main Stage View
              Expanded(child: _buildContentStage()),
            ],
          ),
        ),

        // 3. Docked Queue Panel
        if (!isCompact && (_isQueueOpen || _queueMounted))
          QueueSlideSlot(
            progress: _queueSlideCurve,
            child: IgnorePointer(
              ignoring: !_isQueueOpen,
              child: SizedBox(
                width: AppLayout.queuePanelWidth + 1,
                child: Row(
                  children: [
                    VerticalDivider(width: 1, color: context.palette.border),
                    Expanded(
                      child: ToastRegion(
                        child: QueuePanel(
                          controller: widget.controller,
                          onQueueFocus: (_) {},
                          onAddFiles: widget.onAddQueueFiles ?? () {},
                          onClose: () => _setQueueOpen(false),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
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
      child: KeyedSubtree(
        key: ValueKey<LibrarySection>(effectiveSection),
        child: stage,
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
                  border: Border(
                    top: BorderSide(color: context.palette.border),
                  ),
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
    if (widget.controller.isStopped || !widget.controller.hasMedia) {
      return const SizedBox.shrink();
    }
    final displayEntry = widget.controller.current ?? _lastDisplayEntry;
    if (displayEntry == null) {
      return const SizedBox.shrink();
    }

    final isVideo =
        widget.controller.isVideo ||
        MediaCatalog.kindFromExtension(displayEntry.path).isVideo;
    final dense = MediaQuery.sizeOf(context).height < 600;
    final height = MiniPlayerBar.heightFor(
      MediaQuery.textScalerOf(context),
      dense: dense,
    );
    final bar = MiniPlayerBar(
      controller: widget.controller,
      repository: widget.repository,
      entry: displayEntry,
      isVideo: isVideo,
      compact: isCompact,
      dense: dense,
      openLabel: isVideo ? 'Return to video' : 'Open Now Playing',
      // A video goes back to the player stage; audio opens Now Playing.
      onOpen: isVideo && widget.onBackToPlayer != null
          ? widget.onBackToPlayer!
          : _openNowPlaying,
      onShowQueue: _showCompactQueue,
    );

    // The bar is the AnimatedBuilder child so animation ticks only move the
    // already-painted surface; playback ticks rebuild it via the shell's
    // track-change listener, not per position notify.
    return AnimatedBuilder(
      animation: _miniPlayerVisibilityCurve,
      child: RepaintBoundary(
        child: SizedBox(height: height, child: bar),
      ),
      builder: (context, child) {
        final visibility = _miniPlayerVisibilityCurve.value;
        if (visibility <= 0.001) {
          return const SizedBox.shrink();
        }
        if (AppMotion.reduce(context) || visibility >= 0.999) {
          return child!;
        }
        // Rigid slide-up: the bar translates with the growing slot and is
        // revealed by the clip. No fade, no scale, no per-tick bar rebuild.
        // The clip exists only during the reveal; steady state must stay
        // unclipped so the seek preview can float above the bar.
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: visibility,
            child: child,
          ),
        );
      },
    );
  }
}
