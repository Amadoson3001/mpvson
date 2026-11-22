import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/player_hotkeys.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_content.dart';
import 'package:mpvson/ui/player/views/player_screen.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_playback_service.dart';

class _ControlledPlaybackService extends FakePlaybackService {
  PlaybackSnapshot _customState = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _customStates =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);

  @override
  PlaybackSnapshot get state => _customState;

  @override
  Stream<PlaybackSnapshot> get states => _customStates.stream;

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _customState = snapshot;
    _customStates.add(snapshot);
  }

  @override
  Future<void> open(String path, {bool play = true}) async {
    await super.open(path, play: play);
    emitSnapshot(super.state);
  }

  @override
  Future<void> stop() async {
    await super.stop();
    emitSnapshot(super.state.copyWith(clearError: true));
  }

  @override
  Future<void> dispose() async {
    await _customStates.close();
    await super.dispose();
  }
}

Future<(PlayerController, _ControlledPlaybackService, Directory)>
_createControllerHarness() async {
  final dir = await Directory.systemTemp.createTemp('mpvson-err-ctrl-');
  final playback = _ControlledPlaybackService();
  final sessions = SessionRepository(
    directory: dir,
    encoder: (session) => session.toJson().toString(),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  await controller.initialize();
  return (controller, playback, dir);
}

void main() {
  group('parsePlayerErrorMessage', () {
    test('splits multi-sentence yt-dlp guidance into headline and detail', () {
      const msg =
          'yt-dlp is required to play links from this site. '
          'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.';
      final parsed = parsePlayerErrorMessage(msg);
      expect(
        parsed.headline,
        'yt-dlp is required to play links from this site.',
      );
      expect(
        parsed.detail,
        'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.',
      );
    });

    test('splits colon-delimited open errors cleanly', () {
      const msg = 'Could not open video.mp4: File not found';
      final parsed = parsePlayerErrorMessage(msg);
      expect(parsed.headline, 'Could not open video.mp4');
      expect(parsed.detail, 'File not found');
    });

    test('does not split URLs or Windows drive paths', () {
      final urlParsed = parsePlayerErrorMessage(
        'https://example.com/videos/demo.mp4',
      );
      expect(urlParsed.headline, 'https://example.com/videos/demo.mp4');
      expect(urlParsed.detail, isNull);

      final winParsed = parsePlayerErrorMessage(
        r'C:\Users\mtech\Videos\sample_clip.mp4',
      );
      expect(winParsed.headline, r'C:\Users\mtech\Videos\sample_clip.mp4');
      expect(winParsed.detail, isNull);
    });

    test('keeps short single-line errors unsplit', () {
      final parsed = parsePlayerErrorMessage('Playback stopped unexpectedly');
      expect(parsed.headline, 'Playback stopped unexpectedly');
      expect(parsed.detail, isNull);
    });
  });

  group('PlayerErrorBanner', () {
    testWidgets('renders cleanly in Dark, OLED Black, and Light themes', (
      tester,
    ) async {
      const message =
          'yt-dlp is required to play links from this site. '
          'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.';
      final themes = <ThemeData>[
        AppTheme.darkTheme(),
        AppTheme.darkTheme(oledBlack: true),
        AppTheme.lightTheme(),
      ];

      for (final theme in themes) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: PlayerErrorBanner(
                  message: message,
                  onRetry: () {},
                  onDismiss: () {},
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.text('yt-dlp is required to play links from this site.'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.',
          ),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byTooltip('Dismiss'), findsOneWidget);
      }
    });

    testWidgets('hides Retry when onRetry is null and invokes Dismiss', (
      tester,
    ) async {
      var dismissed = false;
      var retried = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: PlayerErrorBanner(
                message: 'File not found',
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('File not found'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Copy'), findsNothing);
      await tester.tap(find.byTooltip('Dismiss'));
      expect(dismissed, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: PlayerErrorBanner(
                message: 'File not found',
                onRetry: () => retried = true,
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });

    testWidgets(
      'Copy button copies raw error text, shows Copied state, and resets cleanly',
      (tester) async {
        String? copiedClipboardText;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                final args = call.arguments as Map<Object?, Object?>;
                copiedClipboardText = args['text'] as String?;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        const message =
            'Could not open https://example.com/video: HTTP 403 Forbidden';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Center(
                child: PlayerErrorBanner(message: message, onDismiss: () {}),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Copy'));
        await tester.pump();
        expect(copiedClipboardText, message);
        expect(find.text('Copied'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 1900));
        expect(find.text('Copy'), findsOneWidget);
      },
    );
  });

  group('PlayerErrorOverlay', () {
    testWidgets(
      'stacks transient AppToast cleanly above error card without overlapping',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        String? activeError =
            'yt-dlp is required to play links from this site. '
            'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.';
        late BuildContext toastContext;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            builder: (context, child) => AppToastHost(child: child!),
            home: StatefulBuilder(
              builder: (context, setState) {
                toastContext = context;
                return Scaffold(
                  body: Stack(
                    children: [
                      const Positioned.fill(child: SizedBox()),
                      PlayerErrorOverlay(
                        message: activeError,
                        onRetry: () {},
                        onDismiss: () => setState(() => activeError = null),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        AppToast.show(toastContext, 'Added to library');
        await tester.pumpAndSettle();

        final toastRect = tester.getRect(find.text('Added to library'));
        final errorRect = tester.getRect(find.byType(PlayerErrorBanner));
        expect(toastRect.bottom, lessThanOrEqualTo(errorRect.top));

        // Dismiss the error overlay and verify exit completes without errors.
        await tester.tap(
          find.descendant(
            of: find.byType(PlayerErrorBanner),
            matching: find.byTooltip('Dismiss'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PlayerErrorBanner), findsNothing);
      },
    );

    testWidgets('supports reduced motion without lingering animation state', (
      tester,
    ) async {
      String? activeError = 'Playback failed: Network error';

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Stack(
                children: [
                  const Positioned.fill(child: SizedBox()),
                  PlayerErrorOverlay(
                    message: activeError,
                    onDismiss: () => setState(() => activeError = null),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PlayerErrorBanner), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.byType(PlayerErrorBanner), findsNothing);
    });

    testWidgets(
      'hidden PlayerErrorOverlay does not collapse a loose Stack inside Scaffold',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const contentKey = Key('stack-content');
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(child: SizedBox(key: contentKey)),
                  const PlayerErrorOverlay(message: null),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.getSize(find.byKey(contentKey)), const Size(1280, 800));
        expect(find.byType(PlayerErrorBanner), findsNothing);
      },
    );

    testWidgets(
      'PlayerScreen fills viewport on startup when error is null and displays/dismisses errors cleanly',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final setup = await tester.runAsync(_createControllerHarness);
        final (controller, playback, dir) = setup!;
        final updates = UpdateService();
        final engineUpdates = EngineUpdateService();
        addTearDown(() async {
          updates.dispose();
          engineUpdates.dispose();
          await tester.runAsync(() async {
            await controller.close(discard: true, force: true);
            controller.dispose();
            await playback.dispose();
            if (await dir.exists()) await dir.delete(recursive: true);
          });
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            builder: (context, child) => AppToastHost(
              child: AppPreferencesScope(
                preferences: const DesktopPreferences(),
                child: MediaAccentScope(controller: controller, child: child!),
              ),
            ),
            home: PlayerScreen(
              controller: controller,
              updates: updates,
              engineUpdates: engineUpdates,
              desktopWindow: false,
              enableNativeDrop: false,
              videoBuilder: (_, _) => const SizedBox(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getSize(find.byType(PlayerContent)),
          const Size(1280, 800),
        );
        expect(find.byType(PlayerErrorBanner), findsNothing);

        playback.emitSnapshot(
          playback.state.copyWith(
            error:
                'yt-dlp is required to play links from this site. '
                'Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PlayerErrorBanner), findsOneWidget);
        expect(
          tester.getSize(find.byType(PlayerContent)),
          const Size(1280, 800),
        );

        await tester.tap(
          find.descendant(
            of: find.byType(PlayerErrorBanner),
            matching: find.byTooltip('Dismiss'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PlayerErrorBanner), findsNothing);
        expect(controller.error, isNull);
        expect(
          tester.getSize(find.byType(PlayerContent)),
          const Size(1280, 800),
        );

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  group('PlayerController.clearError & Esc dismissal', () {
    test(
      'clearError suppresses stale same-source errors until new error or new load',
      () async {
        final (controller, playback, dir) = await _createControllerHarness();
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final file = File(p.join(dir.path, 'demo.mp4'))..createSync();
        await controller.openPaths(<String>[file.path]);
        final boundary = playback.state.sourceStart;

        playback.emitSnapshot(
          playback.state.copyWith(error: 'Network interrupted'),
        );
        expect(controller.error, 'Network interrupted');

        controller.clearError();
        expect(controller.error, isNull);

        // Stale snapshot from the same sourceStart & message must stay cleared.
        playback.emitSnapshot(
          playback.state.copyWith(volume: 85, error: 'Network interrupted'),
        );
        expect(controller.error, isNull);

        // A genuinely different error message on the same source surfaces.
        playback.emitSnapshot(
          playback.state.copyWith(error: 'Decoder timeout'),
        );
        expect(controller.error, 'Decoder timeout');

        // Dismiss again, then verify a retry (new sourceStart) can surface errors.
        controller.clearError();
        expect(controller.error, isNull);

        playback.emitSnapshot(
          playback.state.copyWith(
            sourceStart: boundary + 1,
            clearNativeSource: true,
            sourceLoaded: false,
            error: 'Network interrupted',
          ),
        );
        expect(controller.error, 'Network interrupted');
      },
    );

    testWidgets('Escape clears controller error when not fullscreen', (
      tester,
    ) async {
      final setup = await tester.runAsync(_createControllerHarness);
      final (controller, playback, dir) = setup!;
      var fullscreen = false;
      final hotkeyHandler = PlayerHotkeyHandler(
        controller: controller,
        getHotkeys: () => PlayerHotkeys.defaults,
        isQueueOpen: () => false,
        isContextMenuOpen: () => false,
        isFullscreen: () => fullscreen,
        isDesktopWindow: true,
        isNativeWindow: true,
        hasLibraryRepository: true,
        getSeekStepSeconds: () => 5,
        getFocusedQueueEntryId: () => null,
        isControlsFocusActive: () => false,
        isQueueFocusActive: () => false,
        isInsidePlayer: (_) => true,
        onCloseContextMenu: () {},
        onCloseQueue: () {},
        onToggleQueue: () {},
        onOpenContextMenu: () {},
        onToggleFullscreen: () {},
        onSetFullscreen: (value) async => fullscreen = value,
        onToggleMiniPlayer: () {},
        onOpenFiles: () {},
        onOpenUrl: () {},
        onOpenLibrary: () {},
        onRemoveQueueEntry: (_) async {},
        onAdjustVolume: (_) {},
        onToggleMute: () {},
        onAdjustDelay: ({required audio, required later}) async {},
        onShowPlaybackInfo: () {},
        onShowControls: () {},
      );
      addTearDown(() async {
        hotkeyHandler.dispose();
        await tester.runAsync(() async {
          await controller.close(discard: true, force: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      });

      final file = File(p.join(dir.path, 'demo.mp4'))..createSync();
      await tester.runAsync(() => controller.openPaths(<String>[file.path]));
      playback.emitSnapshot(playback.state.copyWith(error: 'Failed to decode'));
      expect(controller.error, 'Failed to decode');

      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            autofocus: true,
            onKeyEvent: hotkeyHandler.handleKey,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();

      // Fullscreen takes Escape priority first.
      fullscreen = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(fullscreen, isFalse);
      expect(controller.error, 'Failed to decode');

      // Second Escape clears the error notification.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.error, isNull);

      await tester.runAsync(() => controller.close(discard: true, force: true));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
