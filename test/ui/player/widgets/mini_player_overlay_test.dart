import 'package:flutter/gestures.dart';
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

  testWidgets('Tap expands immediately without double-tap delay', (
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
    await tester.pump();
    expect(expanded, isTrue);
    expect(dismissed, isFalse);

    await tester.fling(
      find.byType(MiniPlayerOverlay),
      const Offset(0, 40),
      300,
    );
    await tester.pumpAndSettle();
    expect(dismissed, isFalse);

    await h.shutdown(tester);
  });

  testWidgets('Mouse click with slight vertical jitter still expands', (
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
              width: 88,
              height: 50,
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

    final center = tester.getCenter(find.byType(MiniPlayerOverlay));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(1.5, 4.0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(expanded, isTrue);
    expect(dismissed, isFalse);

    await h.shutdown(tester);
  });
}
