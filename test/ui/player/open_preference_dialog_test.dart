import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/open_preference_dialog.dart';

void main() {
  Widget buildTestApp({required void Function(BuildContext) onOpen}) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onOpen(context),
            child: const Text('Open Dialog'),
          ),
        ),
      ),
    );
  }

  group('OpenPreferenceDialog', () {
    testWidgets('renders title, description and options correctly', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          onOpen: (context) => OpenPreferenceDialog.show(context),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.byType(OpenPreferenceDialog), findsOneWidget);
      expect(
        find.text('What should happen when you open new files?'),
        findsOneWidget,
      );
      expect(
        find.text(
          'You can change this anytime in Settings > Desktop integration > Opening files.',
        ),
        findsOneWidget,
      );
      expect(find.text('Keep playing and add to queue'), findsOneWidget);
      expect(find.text('Play new files now'), findsOneWidget);
    });

    testWidgets('tapping "Keep playing and add to queue" returns keepPlayingAndEnqueue', (tester) async {
      OpenBehaviorPreference? result;
      await tester.pumpWidget(
        buildTestApp(
          onOpen: (context) async {
            result = await OpenPreferenceDialog.show(context);
          },
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep playing and add to queue'));
      await tester.pumpAndSettle();

      expect(find.byType(OpenPreferenceDialog), findsNothing);
      expect(result, OpenBehaviorPreference.keepPlayingAndEnqueue);
    });

    testWidgets('tapping "Play new files now" returns playNewFilesNow', (tester) async {
      OpenBehaviorPreference? result;
      await tester.pumpWidget(
        buildTestApp(
          onOpen: (context) async {
            result = await OpenPreferenceDialog.show(context);
          },
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play new files now'));
      await tester.pumpAndSettle();

      expect(find.byType(OpenPreferenceDialog), findsNothing);
      expect(result, OpenBehaviorPreference.playNewFilesNow);
    });

    testWidgets('dismissing dialog via barrier tap returns null', (tester) async {
      OpenBehaviorPreference? result;
      await tester.pumpWidget(
        buildTestApp(
          onOpen: (context) async {
            result = await OpenPreferenceDialog.show(context);
          },
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Tap outside the dialog on the modal barrier.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byType(OpenPreferenceDialog), findsNothing);
      expect(result, isNull);
    });

    testWidgets('dismissing dialog via escape key returns null', (tester) async {
      OpenBehaviorPreference? result;
      await tester.pumpWidget(
        buildTestApp(
          onOpen: (context) async {
            result = await OpenPreferenceDialog.show(context);
          },
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Press Escape key to dismiss dialog
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(OpenPreferenceDialog), findsNothing);
      expect(result, isNull);
    });
  });
}
