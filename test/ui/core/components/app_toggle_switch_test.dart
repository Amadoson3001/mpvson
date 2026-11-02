import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/components/app_toggle_switch.dart';

void main() {
  group('AppToggleSwitch', () {
    testWidgets(
      'renders active and inactive states and triggers onChanged on tap',
      (tester) async {
        bool value = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Center(
                  child: AppToggleSwitch(
                    value: value,
                    onChanged: (val) {
                      setState(() => value = val);
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.byType(AppToggleSwitch), findsOneWidget);
        expect(value, isFalse);

        // Tap to toggle on
        await tester.tap(find.byType(AppToggleSwitch));
        await tester.pumpAndSettle();

        expect(value, isTrue);

        // Tap to toggle off
        await tester.tap(find.byType(AppToggleSwitch));
        await tester.pumpAndSettle();

        expect(value, isFalse);
      },
    );

    testWidgets('supports keyboard activation via Space', (tester) async {
      bool value = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Center(
                child: AppToggleSwitch(
                  value: value,
                  onChanged: (val) {
                    setState(() => value = val);
                  },
                ),
              ),
            ),
          ),
        ),
      );

      // Send Tab to focus
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      // Send Space to toggle
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(value, isTrue);
    });
  });
}
