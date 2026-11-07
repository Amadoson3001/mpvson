import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';

import '../../support/app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NowPlayingView honest presentation', () {
    late Harness harness;

    setUp(() {
      harness = Harness.create();
    });

    /// Tears the view down and disposes the controller inside the test body,
    /// so the seek bar's idle-release timer never outlives the test.
    Future<void> shutdown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        harness.controller.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(seconds: 10));
    }

    Future<void> pumpStage(
      WidgetTester tester, {
      Size size = const Size(1280, 800),
    }) async {
      configureView(tester, size: size);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingView(
            controller: harness.controller,
            repository: harness.library,
            onBack: () {},
            onOpenQueue: () {},
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('renders no fabricated artist or album names', (tester) async {
      // openPaths stats the source on the real event loop, so it must run
      // outside the fake async zone.
      await tester.runAsync(
        () => harness.controller.openPaths(const <String>['C:\\Media\\a.mp3']),
      );
      await pumpStage(tester);

      expect(find.text('Celestial Soundscapes'), findsNothing);
      expect(find.text('Cosmic Harmonies'), findsNothing);
      expect(tester.takeException(), isNull);
      await shutdown(tester);
    });

    testWidgets('queue rows without a known duration read as --:--', (
      tester,
    ) async {
      // Entries opened from paths carry no duration, so every queue row must
      // show the unknown-duration placeholder instead of an invented time.
      await tester.runAsync(
        () => harness.controller.openPaths(const <String>[
          'C:\\Media\\a.mp3',
          'C:\\Media\\b.mp3',
        ]),
      );
      await pumpStage(tester);

      // Wide viewport shows the side queue panel with both rows.
      expect(find.text('--:--'), findsNWidgets(2));
      expect(find.byIcon(Icons.queue_music_rounded), findsWidgets);
      await shutdown(tester);
    });

    testWidgets('top-bar controls are 44×44 hit targets', (tester) async {
      await tester.runAsync(
        () => harness.controller.openPaths(const <String>['C:\\Media\\a.mp3']),
      );
      // The narrow viewport keeps the top-bar queue button visible.
      await pumpStage(tester, size: const Size(800, 600));

      for (final icon in <IconData>[
        Icons.arrow_back_rounded,
        Icons.queue_music_rounded,
        Icons.close_rounded,
      ]) {
        final button = find
            .ancestor(of: find.byIcon(icon), matching: find.byType(IconButton))
            .first;
        final buttonSize = tester.getSize(button);
        expect(buttonSize.width, greaterThanOrEqualTo(44), reason: '$icon');
        expect(buttonSize.height, greaterThanOrEqualTo(44), reason: '$icon');
      }
      await shutdown(tester);
    });
  });
}
