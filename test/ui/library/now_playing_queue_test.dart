import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';

import '../../support/app_harness.dart';
import '../../support/audit_helpers.dart';

void main() {
  Widget nowPlaying(Harness h, {VoidCallback? onOpenQueue}) => MaterialApp(
    theme: AppTheme.darkTheme(),
    home: NowPlayingView(
      controller: h.controller,
      onOpenQueue: onOpenQueue ?? () {},
      onAddQueueFiles: () {},
    ),
  );

  testWidgets('wide Now Playing docks the full queue panel', (tester) async {
    final h = Harness.create();
    configureView(tester, size: const Size(1240, 780));
    await tester.pumpWidget(nowPlaying(h));
    await openMedia(tester, h, ['a.mp3', 'b.mp3', 'c.mp3']);

    // The shared panel exposes search and removal; the old "Up Next" list was
    // read-only and hid the full queue entirely.
    expect(find.byKey(const ValueKey('queue-search')), findsOneWidget);
    expect(find.text('Search queue'), findsOneWidget);
    expect(find.text('Up Next'), findsNothing);

    await h.shutdown(tester);
  });

  testWidgets('closed side queue can be reopened from the header', (
    tester,
  ) async {
    final h = Harness.create();
    configureView(tester, size: const Size(1240, 780));
    await tester.pumpWidget(nowPlaying(h));
    await openMedia(tester, h, ['a.mp3', 'b.mp3', 'c.mp3']);

    await tester.tap(find.byTooltip('Close queue'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-search')), findsNothing);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-search')), findsOneWidget);

    await h.shutdown(tester);
  });

  testWidgets('narrow Now Playing keeps the queue button wired to the sheet', (
    tester,
  ) async {
    final h = Harness.create();
    var sheetOpened = false;
    configureView(tester, size: const Size(720, 480));
    await tester.pumpWidget(
      nowPlaying(h, onOpenQueue: () => sheetOpened = true),
    );
    await openMedia(tester, h, ['a.mp3', 'b.mp3', 'c.mp3']);

    expect(find.byKey(const ValueKey('queue-search')), findsNothing);
    await tester.tap(find.text('Queue'));
    expect(sheetOpened, isTrue);

    await h.shutdown(tester);
  });
}
