import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_screen.dart';

import 'support/player_test_fakes.dart';
import 'support/semantics_update_recorder.dart';

void main() {
  RecordingTestBinding();
  testWidgets(
    'restored media changes accessibility from Resume to transport controls',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final semantics = tester.ensureSemantics();
      SemanticsUpdateRecorder.instance.reset();
      final entry =
          MediaEntry.fromPath(
            'https://media.example/restored.mp4',
            id: 'restored',
          ).copyWith(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 2),
          );
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: BlockingSessionRepository(
          blockDetailed: false,
          initialResult: SessionLoadResult(
            session: PlaybackSession(
              queue: [entry],
              currentId: entry.id,
              saveNetworkUrls: true,
            ),
          ),
        ),
      );
      final updates = UpdateService();
      final engineUpdates = EngineUpdateService();
      try {
        await controller.initialize();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              controller: controller,
              updates: updates,
              engineUpdates: engineUpdates,
              desktopWindow: false,
              enableNativeDrop: false,
              videoBuilder: (_, _) => const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Ready to resume'), findsOneWidget);
        await tester.tap(find.text('Resume video'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Ready to resume'), findsNothing);
        expect(find.bySemanticsLabel('Resume video'), findsNothing);
        expect(find.bySemanticsLabel('Playback controls'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byTooltip('Pause'))
              .getSemanticsData()
              .tooltip,
          'Pause',
        );
        expect(controller.error, isNull);
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Settings').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.byTooltip('Close settings'))
              .getSemanticsData()
              .tooltip,
          'Close settings',
        );
        await tester.tap(find.text('Video & audio'));
        await tester.pumpAndSettle();
        expect(find.text('Quality preset'), findsOneWidget);
        SemanticsData? brightness;
        void inspect(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (data.value == 'Brightness 0') brightness = data;
          node.visitChildren((child) {
            inspect(child);
            return true;
          });
        }

        inspect(
          tester.getSemantics(
            find.descendant(
              of: find.byKey(const ValueKey('playback-brightness')),
              matching: find.byType(Slider),
            ),
          ),
        );
        expect(brightness, isNotNull);
        expect(brightness!.increasedValue, 'Brightness +1');
        expect(brightness!.decreasedValue, 'Brightness -1');
        expect(SemanticsUpdateRecorder.instance.updateCount, greaterThan(1));
        expect(SemanticsUpdateRecorder.instance.violations, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => controller.close(discard: true));
        updates.dispose();
        engineUpdates.dispose();
        semantics.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
