import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_screen.dart';

import 'support/player_test_fakes.dart';

void main() {
  for (final size in <Size>[const Size(720, 480), const Size(1280, 800)]) {
    testWidgets('player keyboard and settings work at $size', (tester) async {
      await _withPlayer(tester, size, (harness) async {
        expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
        expect(harness.controller.isPlaying, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(harness.playback.pauseCalls, 1);
        expect(harness.controller.isPlaying, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.pumpAndSettle();
        expect(harness.controller.volume, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pumpAndSettle();
        expect(find.text('Queue'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('player-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Settings').last);
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);

        await tester.tap(find.byTooltip('Close settings'));
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsNothing);
      });
    });
  }

  testWidgets('queue removal can be undone from the player', (tester) async {
    await _withPlayer(tester, const Size(1280, 800), (harness) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(harness.controller.queue, hasLength(2));

      await tester.tap(find.byTooltip('Remove second.mp4 from queue'));
      await tester.pumpAndSettle();
      expect(harness.controller.queue, hasLength(1));
      expect(find.text('Undo'), findsWidgets);

      await tester.tap(find.text('Undo').first);
      await tester.pumpAndSettle();
      expect(harness.controller.queue, hasLength(2));
      expect(harness.controller.queue.last.title, 'second.mp4');
    });
  });
}

Future<void> _withPlayer(
  WidgetTester tester,
  Size size,
  Future<void> Function(_PlayerHarness harness) body,
) async {
  final harness = await _mountPlayer(tester, size);
  try {
    await body(harness);
  } finally {
    await harness.dispose(tester);
  }
}

Future<_PlayerHarness> _mountPlayer(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;

  final playback = FakePlaybackService();
  final sessions = BlockingSessionRepository(
    blockDetailed: false,
    initialResult: const SessionLoadResult(),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  final updateClient = MockClient((_) async => http.Response('', 400));
  final engineClient = MockClient((_) async => http.Response('', 400));
  final updates = UpdateService(client: updateClient, currentVersion: '1.0.0');
  final engineUpdates = EngineUpdateService(
    client: engineClient,
    appVersion: '1.0.0',
    currentVersion: '1.0.0',
  );

  await controller.initialize();
  await controller.openPaths(const <String>[
    'https://media.example/first.mp4',
    'https://media.example/second.mp4',
  ]);

  await tester.pumpWidget(
    MaterialApp(
      home: PlayerScreen(
        controller: controller,
        updates: updates,
        engineUpdates: engineUpdates,
        desktopWindow: false,
        enableNativeDrop: false,
        videoBuilder: (_, _) =>
            const ColoredBox(key: ValueKey('fake-video'), color: Colors.black),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _PlayerHarness(
    playback: playback,
    controller: controller,
    updates: updates,
    engineUpdates: engineUpdates,
    updateClient: updateClient,
    engineClient: engineClient,
  );
}

class _PlayerHarness {
  const _PlayerHarness({
    required this.playback,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.updateClient,
    required this.engineClient,
  });

  final FakePlaybackService playback;
  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final MockClient updateClient;
  final MockClient engineClient;

  Future<void> dispose(WidgetTester tester) async {
    if (controller.isPlaying) await controller.togglePlayPause();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.close(discard: true));
    updates.dispose();
    engineUpdates.dispose();
    updateClient.close();
    engineClient.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}
