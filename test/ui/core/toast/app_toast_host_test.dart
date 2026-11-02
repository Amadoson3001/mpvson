import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/toast/app_toast.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';

void main() {
  // Mirrors the real tree: AppToastHost sits in MaterialApp's builder, above
  // the Navigator. Toast content therefore has no app-level Overlay ancestor
  // and must carry its own (flutter#190357-style orphan overlays aside, the
  // close button's Tooltip asserts on one in debug builds).
  testWidgets(
    'toast renders its tooltip-enabled close button above the navigator',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppToastHost(child: child!),
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => AppToast.show(
                  context,
                  'Hello',
                  duration: const Duration(minutes: 1),
                ),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('show'));
      await tester.pump();

      expect(find.text('Hello'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(
        location: tester.getCenter(find.byIcon(Icons.close_rounded)),
      );
      addTearDown(gesture.removePointer);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Dismiss'), findsOneWidget);
    },
  );
}
