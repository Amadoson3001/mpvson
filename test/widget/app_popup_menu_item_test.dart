import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/components/app_popup_menu_item.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: Center(child: child)),
    );
  }

  group('AppPopupMenuItem Widget Tests', () {
    testWidgets('renders icon, text, and responds to tap in PopupMenuButton', (
      tester,
    ) async {
      String? selectedValue;

      await tester.pumpWidget(
        buildApp(
          PopupMenuButton<String>(
            onSelected: (val) => selectedValue = val,
            itemBuilder: (context) => [
              AppPopupMenuItem<String>(
                value: 'play',
                icon: Icons.play_arrow,
                text: 'Play Video',
              ),
              AppPopupMenuItem<String>(
                value: 'folder',
                icon: Icons.folder_open,
                text: 'Show in folder',
              ),
            ],
            child: const Text('Open Menu'),
          ),
        ),
      );

      // Verify button is rendered
      expect(find.text('Open Menu'), findsOneWidget);

      // Open the popup menu
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      // Verify menu items are visible
      expect(find.text('Play Video'), findsOneWidget);
      expect(find.text('Show in folder'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.folder_open), findsOneWidget);

      // Tap on 'Show in folder'
      await tester.tap(find.text('Show in folder'));
      await tester.pumpAndSettle();

      // Verify callback fired
      expect(selectedValue, 'folder');
    });

    testWidgets('renders shortcut and trailing widget correctly', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          PopupMenuButton<String>(
            itemBuilder: (context) => [
              AppPopupMenuItem<String>(
                value: 'copy',
                icon: Icons.copy,
                text: 'Copy URL',
                shortcut: 'Ctrl+C',
                trailing: const Icon(Icons.check, size: 14),
              ),
            ],
            child: const Text('Menu'),
          ),
        ),
      );

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();

      expect(find.text('Copy URL'), findsOneWidget);
      expect(find.text('Ctrl+C'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets(
      'layout constraints: long text truncates gracefully without RenderFlex overflow',
      (tester) async {
        // In constrained popup item width (e.g. 150px), text truncates with ellipsis
        await tester.pumpWidget(
          buildApp(
            SizedBox(
              width: 150,
              child: AppPopupMenuItemContent(
                icon: Icons.movie,
                text:
                    'Very long video filename that definitely exceeds narrow width constraint.mp4',
              ),
            ),
          ),
        );

        // Pump frame and verify no layout exceptions were thrown
        expect(tester.takeException(), isNull);
        expect(find.byType(AppPopupMenuItemContent), findsOneWidget);
      },
    );

    testWidgets(
      'layout constraints with shortcut in standard desktop popup width (220px)',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            SizedBox(
              width: 220,
              child: AppPopupMenuItemContent(
                icon: Icons.movie,
                text: 'A rather long menu title that needs truncation',
                shortcut: 'Ctrl+Shift+P',
                trailing: const Icon(Icons.star, size: 14),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(AppPopupMenuItemContent), findsOneWidget);
      },
    );

    testWidgets('disabled item renders with enabled: false', (tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        buildApp(
          PopupMenuButton<String>(
            itemBuilder: (context) => [
              AppPopupMenuItem<String>(
                value: 'disabled_action',
                enabled: false,
                icon: Icons.block,
                text: 'Disabled Item',
                onTap: () => tapped = true,
              ),
            ],
            child: const Text('Menu'),
          ),
        ),
      );

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();

      expect(find.text('Disabled Item'), findsOneWidget);

      await tester.tap(find.text('Disabled Item'));
      await tester.pumpAndSettle();

      expect(tapped, isFalse);
    });
  });
}
