import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';

import '../../support/app_harness.dart';
import '../../support/audit_helpers.dart';

/// Parent-owned Settings flag, mirroring how player_content.dart drives the
/// embedded settings sheet through [LibraryShell.showSettings].
class _SettingsFlag {
  bool showSettings = false;
  int settingsClosed = 0;

  /// Set by [_pumpShell]; flips [showSettings] the same way the coordinator's
  /// `openSettings()` does (the gear button inside Now Playing).
  void Function()? toggleSettings;
}

Future<void> _pumpShell(
  WidgetTester tester,
  Harness h,
  _SettingsFlag flag,
  FocusNode homeFocus,
  FocusNode settingsFocus,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: StatefulBuilder(
        builder: (context, setState) {
          flag.toggleSettings = () =>
              setState(() => flag.showSettings = !flag.showSettings);
          return LibraryShell(
            repository: h.library,
            controller: h.controller,
            home: Focus(
              focusNode: homeFocus,
              autofocus: true,
              child: const SizedBox.shrink(key: Key('home-stage')),
            ),
            settings: Focus(
              focusNode: settingsFocus,
              child: const SizedBox.shrink(key: Key('settings-stage')),
            ),
            folders: const SizedBox.shrink(key: Key('folders-stage')),
            showSettings: flag.showSettings,
            onSettings: () => setState(() => flag.showSettings = true),
            onCloseSettings: () {
              flag.settingsClosed++;
              setState(() => flag.showSettings = false);
            },
          );
        },
      ),
    ),
  );
  await settle(tester);
}

/// Loads two audio files through the real controller so the mini player bar
/// appears, exactly like the audit harness does.
Future<void> _loadAudio(WidgetTester tester, Harness h) async {
  final files = await makeMediaFiles(tester, ['a.mp3', 'b.mp3']);
  await tester.runAsync(() async {
    await h.controller.openPaths(files);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await settle(tester);
}

/// Taps the mini player's title area, which opens Now Playing.
Future<void> _tapMiniPlayer(WidgetTester tester) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.tapAt(Offset(120, size.height - 55));
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryShell navigation state', () {
    testWidgets(
      'opening Settings over Now Playing resets the sheet and keeps the '
      'pre-sheet section',
      (tester) async {
        configureView(tester, size: const Size(1240, 780));
        final h = buildHarness();
        final flag = _SettingsFlag();
        final homeFocus = FocusNode(debugLabel: 'home-stage-focus');
        final settingsFocus = FocusNode(debugLabel: 'settings-stage-focus');
        await _pumpShell(tester, h, flag, homeFocus, settingsFocus);
        await _loadAudio(tester, h);

        // Now Playing opens from the mini player.
        await _tapMiniPlayer(tester);
        expect(find.byType(NowPlayingView), findsOneWidget);

        // Settings opens over the sheet (as the coordinator's gear button
        // does): the sheet is gone and the real pre-sheet section (home)
        // sits behind the settings stage.
        flag.toggleSettings!();
        await settle(tester);
        expect(flag.showSettings, isTrue);
        expect(find.byKey(const Key('settings-stage')), findsOneWidget);
        expect(find.byType(NowPlayingView), findsNothing);
        settingsFocus.requestFocus();
        await tester.pump();

        // Esc closes Settings and restores the pre-sheet section, never a
        // stale Now Playing restore.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(flag.settingsClosed, 1);
        expect(find.byKey(const Key('settings-stage')), findsNothing);
        expect(find.byKey(const Key('home-stage')), findsOneWidget);
        expect(find.byType(NowPlayingView), findsNothing);

        // Both nav items work after the round trip.
        await tester.tap(find.text('Music'));
        await settle(tester);
        expect(find.text('Songs'), findsWidgets);
        await tester.tap(find.text('Home'));
        await settle(tester);
        expect(find.byKey(const Key('home-stage')), findsOneWidget);

        // Now Playing can still be reopened from the mini player.
        await _tapMiniPlayer(tester);
        expect(find.byType(NowPlayingView), findsOneWidget);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'a section click during the closing animation wins over the stale '
      'delayed restore',
      (tester) async {
        configureView(tester, size: const Size(1240, 780));
        final h = buildHarness();
        final flag = _SettingsFlag();
        final homeFocus = FocusNode(debugLabel: 'home-stage-focus');
        final settingsFocus = FocusNode(debugLabel: 'settings-stage-focus');
        await _pumpShell(tester, h, flag, homeFocus, settingsFocus);
        await _loadAudio(tester, h);

        await _tapMiniPlayer(tester);
        expect(find.byType(NowPlayingView), findsOneWidget);

        // Esc starts the sheet's closing animation; the click lands while it
        // is still animating out. The first 1ms pump starts the ticker, the
        // second advances it mid-reverse.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 110));
        await tester.tap(find.text('Music'), warnIfMissed: false);
        await settle(tester);

        // The clicked section stays: the sheet's delayed restore must be
        // discarded instead of landing the shell back on the old section.
        expect(find.text('Songs'), findsWidgets);
        expect(find.byKey(const Key('home-stage')), findsNothing);
        expect(find.byType(NowPlayingView), findsNothing);

        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Songs'), findsWidgets);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'opening Now Playing from the mini player while Settings is open '
      'closes Settings and keeps the pre-sheet section',
      (tester) async {
        configureView(tester, size: const Size(1240, 780));
        final h = buildHarness();
        final flag = _SettingsFlag();
        final homeFocus = FocusNode(debugLabel: 'home-stage-focus');
        final settingsFocus = FocusNode(debugLabel: 'settings-stage-focus');
        await _pumpShell(tester, h, flag, homeFocus, settingsFocus);
        await _loadAudio(tester, h);

        flag.toggleSettings!();
        await settle(tester);
        expect(find.byKey(const Key('settings-stage')), findsOneWidget);

        await _tapMiniPlayer(tester);
        expect(find.byType(NowPlayingView), findsOneWidget);
        expect(find.byKey(const Key('settings-stage')), findsNothing);
        expect(flag.settingsClosed, 1);
        homeFocus.requestFocus();
        await tester.pump();

        // Closing Now Playing returns to the real pre-sheet section (home),
        // not to the Settings stage.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byKey(const Key('home-stage')), findsOneWidget);
        expect(find.byType(NowPlayingView), findsNothing);

        await h.shutdown(tester);
      },
    );
  });
}
