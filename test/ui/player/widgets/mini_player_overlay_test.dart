import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/player/views/mini_player_overlay.dart';

import '../../../support/app_harness.dart';

void main() {
  testWidgets('Downward flick dismisses the docked mini player', (
    tester,
  ) async {
    final h = Harness.create();
    var dismissed = false;
    var expanded = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: 160,
              height: 90,
              child: MiniPlayerOverlay(
                controller: h.controller,
                onExpand: () => expanded = true,
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.fling(
      find.byType(MiniPlayerOverlay),
      const Offset(0, 120),
      2000,
    );
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
    expect(expanded, isFalse);

    await h.shutdown(tester);
  });

  testWidgets('Slow drags do not dismiss and tap still expands', (
    tester,
  ) async {
    final h = Harness.create();
    var dismissed = false;
    var expanded = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: 160,
              height: 90,
              child: MiniPlayerOverlay(
                controller: h.controller,
                onExpand: () => expanded = true,
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(MiniPlayerOverlay));
    // onDoubleTap is registered, so a single tap resolves after the
    // double-tap window elapses; pump past it.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(expanded, isTrue);

    await tester.fling(
      find.byType(MiniPlayerOverlay),
      const Offset(0, 40),
      300,
    );
    await tester.pumpAndSettle();
    expect(dismissed, isFalse);

    await h.shutdown(tester);
  });
}
