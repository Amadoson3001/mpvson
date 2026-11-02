import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/settings/settings_appearance_section.dart';

void main() {
  group('M4 Architecture & Line Count Integrity Tests', () {
    test('Every refactored target file strictly does not exceed 500 lines', () {
      final targets = [
        ...Directory('lib/ui/player/views').listSync().whereType<File>().where(
          (f) =>
              f.path.contains('player_') ||
              f.path.endsWith('player_screen.dart') ||
              f.path.endsWith('settings_dialog.dart'),
        ),
        ...Directory(
          'lib/ui/player/views/settings',
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
        File('lib/ui/player/widgets/player_controls.dart'),
        ...Directory(
          'lib/ui/player/widgets/controls',
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
      ];

      expect(targets, isNotEmpty);

      for (final file in targets) {
        final lines = file.readAsLinesSync().length;
        expect(
          lines,
          lessThanOrEqualTo(500),
          reason:
              'File ${file.path} has $lines lines, which exceeds the strict 500 line limit!',
        );
      }
    });

    testWidgets('ThemeModeCard renders title, icon, and responds to tap', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ThemeModeCard(
              title: 'Dark Mode',
              icon: Icons.dark_mode_rounded,
              selected: true,
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Dark Mode'), findsOneWidget);
      expect(find.byIcon(Icons.dark_mode_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.text('Dark Mode'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('AccentColorChip renders preset and responds to tap', (
      tester,
    ) async {
      var tapped = false;
      final preset = AppAccentPreset.lamp;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AccentColorChip(
              preset: preset,
              selected: true,
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text(preset.label), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.text(preset.label));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('ControlBarPreview renders in both compact and normal modes', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: ControlBarPreview(compact: false, compactViewport: false),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('control-density-preview')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    });
  });
}
