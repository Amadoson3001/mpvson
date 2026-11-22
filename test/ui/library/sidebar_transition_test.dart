import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/library/views/library_navigation.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'package:mpvson/ui/library/views/library_top_bar.dart';
import 'package:mpvson/ui/library/views/sidebar_transition.dart';
import 'package:mpvson/ui/library/views/videos_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/library_view_fixtures.dart';

class _SidebarTestHost extends StatefulWidget {
  const _SidebarTestHost({this.animationSpeed = AnimationSpeed.normal});

  final AnimationSpeed animationSpeed;

  @override
  State<_SidebarTestHost> createState() => _SidebarTestHostState();
}

class _SidebarTestHostState extends State<_SidebarTestHost>
    with SingleTickerProviderStateMixin {
  late final SidebarTransition _transition;
  bool _collapsed = false;
  bool _reduceMotion = false;
  late AnimationSpeed _speed;
  LibrarySection _section = LibrarySection.home;

  @override
  void initState() {
    super.initState();
    _speed = widget.animationSpeed;
    _transition = SidebarTransition(vsync: this, initialExpanded: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transition.applyMotion(context);
  }

  void setReducedMotion(bool value) {
    setState(() => _reduceMotion = value);
  }

  void toggle() {
    final nextCollapsed = !_collapsed;
    setState(() => _collapsed = nextCollapsed);
    _transition.drive(!nextCollapsed);
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: AppPreferencesScope(
        preferences: DesktopPreferences(
          reduceMotion: _reduceMotion,
          animationSpeed: _speed,
        ),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: _reduceMotion),
          child: _MotionApplier(
            onApply: _transition.applyMotion,
            child: Scaffold(
              body: Row(
                children: [
                  AnimatedBuilder(
                    animation: _transition.progress,
                    child: ShellSideNav(
                      section: _section,
                      onSelect: (next) => setState(() => _section = next),
                      collapsed: _collapsed,
                      expandProgress: _transition.progress,
                      showSettings: true,
                      onToggleCollapse: toggle,
                    ),
                    builder: (context, child) {
                      final t = _transition.progress.value.clamp(0.0, 1.0);
                      final width =
                          AppLayout.sidebarCollapsed +
                          (AppLayout.sidebarExpanded -
                                  AppLayout.sidebarCollapsed) *
                              t;
                      return SizedBox(width: width, child: child);
                    },
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MotionApplier extends StatefulWidget {
  const _MotionApplier({required this.onApply, required this.child});

  final void Function(BuildContext context) onApply;
  final Widget child;

  @override
  State<_MotionApplier> createState() => _MotionApplierState();
}

class _MotionApplierState extends State<_MotionApplier> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onApply(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('collapse and expand animate continuously without icon warp', (
    tester,
  ) async {
    await tester.pumpWidget(const _SidebarTestHost());
    await tester.pumpAndSettle();

    double sidebarWidth() => tester.getSize(find.byType(ShellSideNav)).width;
    double homeIconX() => tester.getCenter(find.byIcon(Icons.home_rounded)).dx;
    double homeIconY() => tester.getCenter(find.byIcon(Icons.home_rounded)).dy;
    double settingsIconY() =>
        tester.getCenter(find.byIcon(Icons.settings_rounded)).dy;
    double toggleX() =>
        tester.getCenter(find.byIcon(Icons.menu_open_rounded)).dx;

    expect(sidebarWidth(), AppLayout.sidebarExpanded);
    expect(homeIconX(), 30.0);
    final initialHomeY = homeIconY();
    final initialSettingsY = settingsIconY();
    expect(toggleX(), 182.0);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);

    // Every label must be vertically centered with its paired icon/button.
    expect(
      (tester.getCenter(find.text('Home')).dy - initialHomeY).abs(),
      lessThanOrEqualTo(1.0),
    );
    expect(
      (tester.getCenter(find.text('Settings')).dy - initialSettingsY).abs(),
      lessThanOrEqualTo(1.0),
    );
    expect(
      (tester.getCenter(find.text('Library')).dy -
              tester.getCenter(find.byIcon(Icons.menu_open_rounded)).dy)
          .abs(),
      lessThanOrEqualTo(1.0),
    );

    // Tap collapse toggle and sample frames across the spring transition.
    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pump();

    var prevWidth = sidebarWidth();
    var prevToggleX = toggleX();
    var sawPartialLabelOpacity = false;

    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final w = sidebarWidth();
      final hx = homeIconX();
      final tx = toggleX();

      // Width and toggle position move monotonically inward with zero overshoot.
      expect(w, lessThanOrEqualTo(prevWidth));
      expect(w, greaterThanOrEqualTo(AppLayout.sidebarCollapsed));
      expect(tx, lessThanOrEqualTo(prevToggleX));
      expect(tx, greaterThanOrEqualTo(32.0));

      // Icon stays anchored on the left (30 -> 32), never warping to center.
      expect(hx, inInclusiveRange(30.0, 32.0));
      // Vertical positions remain invariant (zero height jump).
      expect(homeIconY(), initialHomeY);
      expect(settingsIconY(), initialSettingsY);

      final homeText = find.text('Home');
      if (homeText.evaluate().isNotEmpty) {
        final opacityWidget = tester.widget<Opacity>(
          find.ancestor(of: homeText, matching: find.byType(Opacity)).first,
        );
        if (opacityWidget.opacity > 0.01 && opacityWidget.opacity < 0.99) {
          sawPartialLabelOpacity = true;
        }
      }

      prevWidth = w;
      prevToggleX = tx;
    }

    expect(sawPartialLabelOpacity, isTrue);

    await tester.pumpAndSettle();
    expect(sidebarWidth(), AppLayout.sidebarCollapsed);
    expect(homeIconX(), 32.0);
    expect(toggleX(), 32.0);
    expect(homeIconY(), initialHomeY);
    expect(settingsIconY(), initialSettingsY);
    expect(find.text('Home'), findsNothing);
    expect(find.text('Library'), findsNothing);

    // Tap expand toggle and verify continuous return without pop-in.
    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pump();

    prevWidth = sidebarWidth();
    prevToggleX = toggleX();
    var sawEmergingLabelOpacity = false;

    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final w = sidebarWidth();
      final hx = homeIconX();
      final tx = toggleX();

      expect(w, greaterThanOrEqualTo(prevWidth));
      expect(w, lessThanOrEqualTo(AppLayout.sidebarExpanded));
      expect(tx, greaterThanOrEqualTo(prevToggleX));
      expect(tx, lessThanOrEqualTo(182.0));
      expect(hx, inInclusiveRange(30.0, 32.0));
      expect(homeIconY(), initialHomeY);
      expect(settingsIconY(), initialSettingsY);

      final homeText = find.text('Home');
      if (homeText.evaluate().isNotEmpty) {
        final opacityWidget = tester.widget<Opacity>(
          find.ancestor(of: homeText, matching: find.byType(Opacity)).first,
        );
        if (opacityWidget.opacity > 0.01 && opacityWidget.opacity < 0.99) {
          sawEmergingLabelOpacity = true;
        }
      }

      prevWidth = w;
      prevToggleX = tx;
    }

    expect(sawEmergingLabelOpacity, isTrue);

    await tester.pumpAndSettle();
    expect(sidebarWidth(), AppLayout.sidebarExpanded);
    expect(homeIconX(), 30.0);
    expect(toggleX(), 182.0);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('mid-flight reversal preserves continuity and settles cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(const _SidebarTestHost());
    await tester.pumpAndSettle();

    double sidebarWidth() => tester.getSize(find.byType(ShellSideNav)).width;

    // Start collapsing.
    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));

    final midCollapseWidth = sidebarWidth();
    expect(midCollapseWidth, greaterThan(AppLayout.sidebarCollapsed));
    expect(midCollapseWidth, lessThan(AppLayout.sidebarExpanded));

    // Reverse mid-flight: width must not jump discontinuously.
    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pump();
    expect(sidebarWidth(), closeTo(midCollapseWidth, 0.5));

    await tester.pump(const Duration(milliseconds: 16));
    // Momentum carries briefly or turns smoothly without snapping to endpoints.
    expect(sidebarWidth(), greaterThan(AppLayout.sidebarCollapsed));
    expect(sidebarWidth(), lessThan(AppLayout.sidebarExpanded));

    await tester.pumpAndSettle();
    expect(sidebarWidth(), AppLayout.sidebarExpanded);
  });

  testWidgets('reduced motion enabled mid-transition settles immediately', (
    tester,
  ) async {
    await tester.pumpWidget(const _SidebarTestHost());
    await tester.pumpAndSettle();

    double sidebarWidth() => tester.getSize(find.byType(ShellSideNav)).width;

    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));

    final midWidth = sidebarWidth();
    expect(midWidth, greaterThan(AppLayout.sidebarCollapsed));
    expect(midWidth, lessThan(AppLayout.sidebarExpanded));

    final host = tester.state<_SidebarTestHostState>(
      find.byType(_SidebarTestHost),
    );
    host.setReducedMotion(true);
    await tester.pump();

    expect(sidebarWidth(), AppLayout.sidebarCollapsed);
  });

  testWidgets('indicator pill switches destinations smoothly without errors', (
    tester,
  ) async {
    await tester.pumpWidget(const _SidebarTestHost());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Folders'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_open_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('animation speed scales spring settling rate', (tester) async {
    Future<double> widthAfter80ms(AnimationSpeed speed) async {
      await tester.pumpWidget(_SidebarTestHost(animationSpeed: speed));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.menu_open_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      return tester.getSize(find.byType(ShellSideNav)).width;
    }

    final fastWidth = await widthAfter80ms(AnimationSpeed.fast);
    final slowWidth = await widthAfter80ms(AnimationSpeed.slow);

    // Fast closes much further than slow after the same 80ms elapsed.
    expect(fastWidth, lessThan(slowWidth - 15.0));
  });

  testWidgets(
    'LibraryShell Videos stage stays flush edge-to-edge on every frame of collapse and expand',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);

      late Directory dir;
      late FakePlaybackService playback;
      late PlayerController controller;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('mpvson_sidebar_test_');
        playback = FakePlaybackService();
        final sessions = SessionRepository(
          directory: dir,
          encoder: (session) => jsonEncode(session.toJson()),
        );
        controller = PlayerController(playback: playback, sessions: sessions);
        await controller.initialize();
      });
      final repo = FakeMediaLibraryRepository();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
        await tester.runAsync(() async {
          await repo.dispose();
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme(),
          home: AppToastHost(
            child: AppPreferencesScope(
              preferences: const DesktopPreferences(),
              child: MediaAccentScope(
                controller: controller,
                child: LibraryShell(
                  repository: repo,
                  controller: controller,
                  initialSection: LibrarySection.videos,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      void assertStageFlush() {
        final navRect = tester.getRect(find.byType(ShellSideNav));
        final topBarRect = tester.getRect(find.byType(LibraryTopBar));
        final videosRect = tester.getRect(find.byType(VideosView));

        // Content starts right after the 1px divider and stretches cleanly to
        // the right edge of the window with zero gap and zero clipping.
        expect(topBarRect.left, closeTo(navRect.right + 1.0, 0.5));
        expect(topBarRect.right, closeTo(1280.0, 0.5));
        expect(videosRect.left, closeTo(navRect.right + 1.0, 0.5));
        expect(videosRect.right, closeTo(1280.0, 0.5));
      }

      assertStageFlush();

      // Collapse sidebar and verify every sampled frame stays flush.
      await tester.tap(find.byIcon(Icons.menu_open_rounded));
      await tester.pump();
      assertStageFlush();

      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        assertStageFlush();
      }
      await tester.pumpAndSettle();
      assertStageFlush();

      // Expand sidebar and verify every sampled frame stays flush.
      await tester.tap(find.byIcon(Icons.menu_open_rounded));
      await tester.pump();
      assertStageFlush();

      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        assertStageFlush();
      }
      await tester.pumpAndSettle();
      assertStageFlush();

      expect(tester.takeException(), isNull);
    },
  );
}
