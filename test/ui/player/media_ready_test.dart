import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/widgets/media_ready.dart';

void main() {
  group('MediaReady Widget Tests', () {
    final testEntry = MediaEntry(
      id: 'entry-ready-1',
      path: r'E:\Music\English music\song.mp4',
      title: 'Test Video Title',
      lastPlayed: DateTime(2026, 1, 1),
    );

    testWidgets('renders resume button without back or close actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      var playCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme(),
          home: Scaffold(
            body: MediaReady(
              entry: testEntry,
              position: const Duration(seconds: 107),
              duration: const Duration(seconds: 300),
              isOpening: false,
              onPlay: () => playCalled = true,
            ),
          ),
        ),
      );

      // Title & position text
      expect(find.text('Test Video Title'), findsOneWidget);
      expect(find.text('Ready to resume'), findsOneWidget);
      expect(find.text('Continue at 01:47'), findsOneWidget);

      // Play button exists
      expect(find.byKey(const ValueKey('resume-current')), findsOneWidget);
      // Back to files and close were deleted from MediaReady
      expect(find.byKey(const ValueKey('ready-back-to-library')), findsNothing);
      expect(find.byKey(const ValueKey('ready-close')), findsNothing);

      // Tap Play
      await tester.tap(find.byKey(const ValueKey('resume-current')));
      expect(playCalled, isTrue);
    });
  });
}
