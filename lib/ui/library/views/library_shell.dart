import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/toast_layout.dart';
import '../../core/components/animated_grid_reflow.dart';
import '../../core/components/playback_pulse.dart';
import '../../player/widgets/queue_panel.dart';
import '../../player/views/player_queue_layout.dart';
import '../../player/views/queue_slide_transition.dart';
import '../../../utils/debouncer.dart';
import '../library_browse_constants.dart';
import '../widgets/library_status_banner.dart';
import 'library_navigation.dart';
import 'library_section.dart';
import 'library_top_bar.dart';
import 'mini_player_bar.dart';
import 'music_view.dart';
import 'now_playing_view.dart';
import 'playlists_view.dart';
import 'sidebar_transition.dart';
import 'videos_view.dart';

export 'library_section.dart';

/// Exposes [LibraryShell]'s shared search controller and focus node to section
/// stages such as [HomeView] so `Ctrl+F` / `Ctrl+K` / `/` work everywhere.
class LibrarySearchScope extends InheritedWidget {
  const LibrarySearchScope({
    super.key,
    required this.controller,
    required this.focusNode,
    required super.child,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  static LibrarySearchScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LibrarySearchScope>();

  @override
  bool updateShouldNotify(LibrarySearchScope oldWidget) =>
      controller != oldWidget.controller || focusNode != oldWidget.focusNode;
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
    this.onAddQueueUrl,
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
  final VoidCallback? onAddQueueUrl;
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
  /// background from focus, so shortcut keys (Esc, Ctrl+F, Ctrl+K) keep working: the
  /// scope sits below [CallbackShortcuts], and key events bubble through it.
  final _shellFocusScope = FocusScopeNode(debugLabel: 'Library shell');
  String _searchQuery = '';
  final Debouncer _searchDebounce = Debouncer(delay: kLibrarySearchDebounce);
  bool _isOnDemandQueueOpen = false;
  bool? _sidebarCollapsedOverride;

  /// Bumped on every explicit section change. Async section restores (the
  /// delayed [AnimationController.reverse] callback) capture the value when
  /// they start and discard themselves when it has moved on, so a restore
  /// that races a user click can never clobber the clicked section.
  int _sectionGeneration = 0;

  late final SpringMotionController _nowPlayingMorph = SpringMotionController(
    vsync: this,
    initialForward:
        widget.initialSection == LibrarySection.nowPlaying &&
        !widget.showSettings,
    forwardSpring: AppMotion.sheetSpring,
    reverseSpring: AppMotion.sheetSpring,
    tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
  );

  late final SpringMotionController _miniPlayerVisibility =
      SpringMotionController(
        vsync: this,
        initialForward:
            widget.controller.hasMedia && !widget.controller.isStopped,
        forwardSpring: AppMotion.panelSpring,
        reverseSpring: AppMotion.panelSpring,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
      );

  late final QueueSlideTransition _queueSlide;
  bool _queueMounted = false;
  late final SidebarTransition _sidebarSlide;
  late final Listenable _shellWidthMotion;
  bool _sidebarLayoutSynced = false;

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

  void _driveQueueSlide() => _queueSlide.drive(_isQueueOpen);

  void _handleQueueSlideDismissed() {
    if (!mounted || _isQueueOpen) return;
    setState(() => _queueMounted = false);
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
    _queueSlide = QueueSlideTransition(
      vsync: this,
      initialOpen: _isQueueOpen,
      onDismissed: _handleQueueSlideDismissed,
    );
    _sidebarSlide = SidebarTransition(vsync: this, initialExpanded: true);
    _shellWidthMotion = Listenable.merge(<Listenable>[
      _sidebarSlide.progress,
      _queueSlide.progress,
    ]);
    _lastDisplayEntry = widget.controller.current;
    _searchController.addListener(_onSearchChanged);
    widget.controller.structureListenable.addListener(_onPlaybackChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _queueSlide.applyMotion(context);
    _sidebarSlide.applyMotion(context);
    _nowPlayingMorph.applyMotion(context);
    _miniPlayerVisibility.applyMotion(context);
  }

  @override
  void didUpdateWidget(LibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.structureListenable.removeListener(
        _onPlaybackChanged,
      );
      widget.controller.structureListenable.addListener(_onPlaybackChanged);
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
            _nowPlayingMorph.value > 0) {
          _nowPlayingMorph.snap(false);
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
      if (_nowPlayingMorph.value > 0) {
        _nowPlayingMorph.snap(false);
      }
    }
  }

  @override
  void dispose() {
    _queueSlide.dispose();
    _sidebarSlide.dispose();
    _nowPlayingMorph.dispose();
    _miniPlayerVisibility.dispose();
    widget.controller.structureListenable.removeListener(_onPlaybackChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchDebounce.dispose();
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
            _nowPlayingMorph.value > 0)) {
      _closeNowPlaying();
    }

    if (hasMedia && !widget.controller.isStopped) {
      if (_miniPlayerVisibility.value < 1.0 &&
          (!_miniPlayerVisibility.targetForward ||
              !_miniPlayerVisibility.isAnimating)) {
        unawaited(_miniPlayerVisibility.drive(true));
      }
    } else {
      if (_miniPlayerVisibility.value > 0.0 ||
          _miniPlayerVisibility.isAnimating) {
        _miniPlayerVisibility.snap(false);
      }
      if (_lastDisplayEntry != null) {
        _lastDisplayEntry = null;
      }
      if (mounted) setState(() {});
    }
  }

  void _onSearchChanged() {
    final next = _searchController.text;
    // Clearing search must update the stage immediately so the unfiltered
    // collection returns without waiting out the debounce.
    if (next.isEmpty) {
      _searchDebounce.runNow(() {
        if (!mounted || _searchQuery.isEmpty) return;
        setState(() => _searchQuery = '');
      });
      return;
    }
    _searchDebounce.run(() {
      if (!mounted || _searchQuery == next) return;
      setState(() => _searchQuery = next);
    });
  }

  void _openNowPlaying() {
    if (_currentSection == LibrarySection.nowPlaying &&
        _nowPlayingMorph.value > 0 &&
        _nowPlayingMorph.targetForward) {
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
    unawaited(_nowPlayingMorph.drive(true));
    if (mounted) setState(() {});
  }

  void _closeNowPlaying() {
    if (!_nowPlayingMorph.isAnimating && _nowPlayingMorph.value <= 0.0) {
      if (_currentSection == LibrarySection.nowPlaying) {
        setState(() => _currentSection = _previousSection);
      }
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
      _nowPlayingMorph.snap(false);
      restore();
    } else {
      _nowPlayingMorph.drive(false).then((_) {
        if (_nowPlayingMorph.targetForward) return;
        restore();
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

    if (_nowPlayingMorph.value > 0 || _nowPlayingMorph.targetForward) {
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
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
                  _searchFocus.requestFocus(),
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () =>
                  _searchFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                  _searchFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_currentSection == LibrarySection.settings) {
                  // Esc closes the embedded Settings first so it can never
                  // race the Now Playing morph for the same keypress.
                  widget.onCloseSettings?.call();
                } else if (_nowPlayingMorph.value > 0 ||
                    _nowPlayingMorph.targetForward) {
                  _closeNowPlaying();
                }
              },
            },
            child: FocusScope(
              node: _shellFocusScope,
              autofocus: true,
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
                      // is inert and subtly recedes in scale on the GPU.
                      KeyedSubtree(
                        key: const ValueKey('library-shell-stage'),
                        child: AnimatedBuilder(
                          animation: _nowPlayingMorph.progress,
                          child: RepaintBoundary(
                            child: Column(
                              children: [
                                Expanded(
                                  child: _buildBodyRow(
                                    width,
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
                          builder: (context, child) {
                            final progress = _nowPlayingMorph.value.clamp(
                              0.0,
                              1.0,
                            );
                            final sheetUp = progress > 0;
                            final lowPower = AppMotion.lowPower(context);
                            final scale = (!lowPower && progress > 0.001)
                                ? (1.0 - 0.015 * progress)
                                : 1.0;
                            return ExcludeFocus(
                              excluding: sheetUp,
                              child: ExcludeSemantics(
                                excluding: sheetUp,
                                child: Transform.scale(
                                  scale: scale,
                                  child: child!,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      _buildNowPlayingScrim(),
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
    double shellWidth,
    bool isDesktopWide,
    bool isDesktopMedium,
    bool isCompact,
  ) {
    final effectiveSection = _currentSection == LibrarySection.nowPlaying
        ? _previousSection
        : _currentSection;
    final sidebarCollapsed = _sidebarCollapsedOverride ?? !isDesktopWide;
    final desiredExpanded = !sidebarCollapsed;
    if (isCompact) {
      _sidebarLayoutSynced = false;
    } else if (!_sidebarLayoutSynced) {
      _sidebarLayoutSynced = true;
      _sidebarSlide.snap(desiredExpanded);
    } else if (_sidebarSlide.targetExpanded != desiredExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _sidebarSlide.drive(desiredExpanded);
      });
    }
    return Row(
      children: [
        // 1. Navigation: collapsible 208px/64px sidebar on >=960, drawer on <960.
        if (!isCompact) ...[
          ToastRegion(
            child: AnimatedBuilder(
              animation: _sidebarSlide.progress,
              child: RepaintBoundary(
                child: ShellSideNav(
                  section: _currentSection,
                  onSelect: _selectSection,
                  collapsed: sidebarCollapsed,
                  expandProgress: _sidebarSlide.progress,
                  showSettings: widget.onSettings != null,
                  onToggleCollapse: () {
                    final nextCollapsed = !sidebarCollapsed;
                    setState(() {
                      _sidebarCollapsedOverride = nextCollapsed;
                    });
                    _sidebarSlide.drive(!nextCollapsed);
                  },
                ),
              ),
              builder: (context, child) {
                final t = _sidebarSlide.progress.value.clamp(0.0, 1.0);
                final width =
                    AppLayout.sidebarCollapsed +
                    (AppLayout.sidebarExpanded - AppLayout.sidebarCollapsed) *
                        t;
                return SizedBox(width: width, child: child);
              },
            ),
          ),
          VerticalDivider(width: 1, color: context.palette.border),
        ],

        // 2. Main Content Area: Top bar + Status Banner + Active Stage
        Expanded(
          child: RepaintBoundary(
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
                if (effectiveSection != LibrarySection.home)
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
                    onOpenFiles: widget.onOpenFiles,
                    onOpenUrl: widget.onOpenUrl,
                  ),
                // Main Stage View
                Expanded(
                  child: ShellWidthMotionScope(
                    listenable: _shellWidthMotion,
                    pendingWidthDelta: () =>
                        _pendingContentWidthDelta(isCompact),
                    columnBasisWidth: isCompact
                        ? shellWidth
                        : math.max(
                            0.0,
                            shellWidth - AppLayout.sidebarExpanded - 1,
                          ),
                    child: LibrarySearchScope(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      child: _buildContentStage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // 3. Docked Queue Panel
        if (!isCompact && (_isQueueOpen || _queueMounted))
          QueueSlideSlot(
            progress: _queueSlide.progress,
            panelWidth: AppLayout.queuePanelWidth + 1,
            child: RepaintBoundary(
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
                            onAddUrl: widget.onAddQueueUrl,
                            onClose: () => _setQueueOpen(false),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Width the content stage gains (+) or loses (-) once the sidebar and docked
  /// queue settle. 0 when both are at rest.
  double _pendingContentWidthDelta(bool isCompact) {
    if (isCompact) return 0;
    var delta = 0.0;
    const span = AppLayout.sidebarExpanded - AppLayout.sidebarCollapsed;
    final t = _sidebarSlide.progress.value.clamp(0.0, 1.0);
    final sidebarNow = AppLayout.sidebarCollapsed + span * t;
    final sidebarTarget = _sidebarSlide.targetExpanded
        ? AppLayout.sidebarExpanded
        : AppLayout.sidebarCollapsed;
    delta += sidebarNow - sidebarTarget;
    if (_isQueueOpen || _queueMounted) {
      const panel = AppLayout.queuePanelWidth + 1;
      final q = _queueSlide.progress.value.clamp(0.0, 1.0);
      delta += panel * q - (_isQueueOpen ? panel : 0.0);
    }
    return delta;
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
      child: AppSectionReveal(
        key: ValueKey<LibrarySection>(effectiveSection),
        child: stage,
      ),
    );
  }

  Widget _buildNowPlayingScrim() {
    return Positioned.fill(
      key: const ValueKey('library-shell-scrim'),
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _nowPlayingMorph.progress,
          builder: (context, _) {
            if (AppMotion.lowPower(context)) return const SizedBox.shrink();
            final progress = _nowPlayingMorph.value.clamp(0.0, 1.0);
            if (progress <= 0.001) return const SizedBox.shrink();
            return ColoredBox(
              color: Colors.black.withValues(alpha: 0.32 * progress),
            );
          },
        ),
      ),
    );
  }

  /// Morphing full Now Playing player sheet overlay.
  ///
  /// Expands smoothly upwards from the bottom edge to cover the entire window
  /// using spring physics and GPU-composited translation over the recessed stage.
  Widget _buildNowPlayingMorphOverlay() {
    return Positioned.fill(
      key: const ValueKey('library-shell-now-playing'),
      child: AnimatedBuilder(
        animation: _nowPlayingMorph.progress,
        // Keep the sheet widget stable across animation ticks so metadata,
        // artwork and controls are not rebuilt 60/120 times a second.
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
              onAddQueueFiles: widget.onAddQueueFiles,
              onAddQueueUrl: widget.onAddQueueUrl,
            ),
          ),
        ),
        builder: (context, child) {
          final progress = _nowPlayingMorph.value.clamp(0.0, 1.0);
          if (progress <= 0.0001) {
            return const IgnorePointer(child: SizedBox.shrink());
          }

          final reduced = AppMotion.reduce(context);
          final lowPower = AppMotion.lowPower(context);
          final inFlight = !lowPower && progress < 0.999;
          final slideOffset = reduced
              ? Offset.zero
              : Offset(0.0, 1.0 - progress);
          final topRadius = inFlight ? 16.0 * (1.0 - progress) : 0.0;

          return FractionalTranslation(
            translation: slideOffset,
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(topRadius),
              ),
              clipBehavior: inFlight ? Clip.antiAlias : Clip.none,
              child: child,
            ),
          );
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
          onAddUrl: widget.onAddQueueUrl,
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
      animation: _miniPlayerVisibility.progress,
      child: RepaintBoundary(
        child: SizedBox(height: height, child: bar),
      ),
      builder: (context, child) {
        final visibility = _miniPlayerVisibility.value.clamp(0.0, 1.0);
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
