import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_library_navigation.dart';
import 'package:mpvson/ui/player/views/player_top_bar.dart';
import 'package:mpvson/ui/player/widgets/queue_panel.dart';
import 'package:path/path.dart' as p;

import '../../support/library_view_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Queue drag and drop & mini-player dock', () {
    testWidgets(
      'dragging a queue item body reorders the queue without playing it, while tapping plays',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(800, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final dir = Directory.systemTemp.createTempSync('mpvson_queue_drag_');
        final playback = FakePlaybackService();
        final sessions = SessionRepository(
          directory: dir,
          encoder: (session) => session.toJson().toString(),
        );
        final controller = PlayerController(
          playback: playback,
          sessions: sessions,
        );
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        });

        final one = File(p.join(dir.path, 'alpha.mp4'))
          ..writeAsBytesSync(const <int>[0, 1]);
        final two = File(p.join(dir.path, 'beta.mp4'))
          ..writeAsBytesSync(const <int>[0, 2]);
        final three = File(p.join(dir.path, 'gamma.mp4'))
          ..writeAsBytesSync(const <int>[0, 3]);

        await tester.runAsync(
          () => controller.openPaths(<String>[one.path, two.path, three.path]),
        );

        await tester.pumpWidget(
          buildLibraryTestApp(
            controller: controller,
            home: SizedBox(
              width: 340,
              height: 600,
              child: QueuePanel(
                controller: controller,
                onClose: () {},
                onQueueFocus: (_) {},
                onAddFiles: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(controller.current?.title, 'alpha');

        // Grabbing the row title directly and dragging it above `beta` moves
        // `gamma` into slot 1 without replacing active playback (`alpha`).
        final gammaCenter = tester.getCenter(find.text('gamma'));
        final betaCenter = tester.getCenter(find.text('beta'));
        final deltaY = betaCenter.dy - gammaCenter.dy;
        final gesture = await tester.startGesture(gammaCenter);
        await tester.pump();
        const steps = 6;
        for (var step = 1; step <= steps; step++) {
          await gesture.moveBy(Offset(0, deltaY / steps));
          await tester.pump(const Duration(milliseconds: 24));
        }
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(controller.current?.title, 'alpha');
        expect(controller.queue.map((e) => e.title).toList(), <String>[
          'alpha',
          'gamma',
          'beta',
        ]);

        // Pressing Next plays the item dragged into the next queue slot.
        await tester.runAsync(() => controller.next());
        await tester.pump();
        expect(controller.current?.title, 'gamma');

        // Clicking an item without dragging still plays it.
        await tester.tap(find.text('beta'));
        await tester.pump();
        expect(controller.current?.title, 'beta');

        // Let seek-preview idle timer release and close controller cleanly.
        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'PlayerTopBar shows a modern down-arrow mini-player button without Home text',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: PlayerTopBar(
                currentTitle: 'Sample Video',
                controlsVisible: true,
                hasLibraryRepository: true,
                isMiniPlayer: false,
                onPointerEnter: () {},
                onPointerExit: () {},
                onBackToHome: () => tapped = true,
                onExitMiniPlayer: () {},
              ),
            ),
          ),
        );

        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
        expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
        expect(find.text('Home'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('player-mini-button')));
        await tester.pump();
        expect(tapped, isTrue);
      },
    );

    test(
      'PlayerLibraryNavigation openLibrary preserves settingsOpen and active page request',
      () async {
        final dir = Directory.systemTemp.createTempSync('mpvson_nav_');
        final playback = FakePlaybackService();
        final sessions = SessionRepository(
          directory: dir,
          encoder: (session) => session.toJson().toString(),
        );
        final controller = PlayerController(
          playback: playback,
          sessions: sessions,
        );
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        });

        final video = File(p.join(dir.path, 'video.mp4'))
          ..writeAsBytesSync(const <int>[0, 1]);
        await controller.openPaths(<String>[video.path]);

        final navigation = PlayerLibraryNavigation(
          controller: controller,
          hasLibraryRepository: true,
          onExitMiniPlayer: () {},
          onVisibilityChanged: () {},
        );
        addTearDown(navigation.dispose);

        navigation.openSettings();
        expect(navigation.isShowingLibrary, isTrue);
        expect(navigation.settingsOpen, isTrue);
        final initialHomeRequest = navigation.homeNavigationRequest;

        navigation.returnToPlayer(controller.current?.id);
        expect(navigation.isShowingLibrary, isFalse);
        expect(navigation.settingsOpen, isTrue);

        // Minimizing back to the in-app library keeps Settings open and avoids
        // forcing a reset back to Home.
        navigation.openLibrary();
        expect(navigation.isShowingLibrary, isTrue);
        expect(navigation.settingsOpen, isTrue);
        expect(navigation.homeNavigationRequest, initialHomeRequest);
      },
    );
  });
}
