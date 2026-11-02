import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/app_dialog.dart';

void main() {
  Widget buildTestable(Widget child) {
    return MaterialApp(
      theme: AppTheme.darkTheme(),
      home: Scaffold(body: Builder(builder: (context) => child)),
    );
  }

  group('AppDialog', () {
    testWidgets('renders structured title, content, actions, and icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestable(
          const AppDialog(
            icon: Icon(Icons.info_outline, key: Key('dialog-icon')),
            title: Text('Test Dialog Title'),
            content: Text('This is dialog content.'),
            actions: [Text('Action 1'), Text('Action 2')],
          ),
        ),
      );

      expect(find.byKey(const Key('dialog-icon')), findsOneWidget);
      expect(find.text('Test Dialog Title'), findsOneWidget);
      expect(find.text('This is dialog content.'), findsOneWidget);
      expect(find.text('Action 1'), findsOneWidget);
      expect(find.text('Action 2'), findsOneWidget);
    });

    testWidgets('renders custom child layout', (tester) async {
      await tester.pumpWidget(
        buildTestable(
          const AppDialog(
            child: SizedBox(
              width: 300,
              height: 200,
              child: Text('Custom Child Content'),
            ),
          ),
        ),
      );

      expect(find.text('Custom Child Content'), findsOneWidget);
    });

    testWidgets(
      'applies Dialog surface background, shape radius, and elevation',
      (tester) async {
        await tester.pumpWidget(
          buildTestable(
            const AppDialog(
              title: Text('Appearance Test'),
              content: Text('Checking shape and colors'),
            ),
          ),
        );

        final dialogFinder = find.byType(Dialog);
        expect(dialogFinder, findsOneWidget);

        final dialogWidget = tester.widget<Dialog>(dialogFinder);
        expect(dialogWidget.elevation, 12.0);
        expect(dialogWidget.clipBehavior, Clip.antiAlias);

        final shape = dialogWidget.shape as RoundedRectangleBorder;
        final borderRadius = shape.borderRadius as BorderRadius;
        expect(borderRadius.topLeft.x, AppRadii.artwork);
      },
    );

    testWidgets('AppDialog.show displays dialog and pops with result', (
      tester,
    ) async {
      String? result;

      await tester.pumpWidget(
        buildTestable(
          ElevatedButton(
            onPressed: () async {
              result = await AppDialog.show<String>(
                context: tester.element(find.byType(ElevatedButton)),
                builder: (context) => AppDialog(
                  title: const Text('Modal Title'),
                  content: const Text('Modal Content'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop('confirmed'),
                      child: const Text('Confirm'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('Open Modal'),
          ),
        ),
      );

      // Dialog is not visible initially
      expect(find.text('Modal Title'), findsNothing);

      // Tap button to open dialog
      await tester.tap(find.text('Open Modal'));
      await tester.pumpAndSettle();

      expect(find.text('Modal Title'), findsOneWidget);
      expect(find.text('Modal Content'), findsOneWidget);

      // Tap Confirm
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      // Dialog closed and result received
      expect(find.text('Modal Title'), findsNothing);
      expect(result, 'confirmed');
    });

    testWidgets('supports vertical actionsAxis', (tester) async {
      await tester.pumpWidget(
        buildTestable(
          const AppDialog(
            actionsAxis: Axis.vertical,
            title: Text('Vertical Actions'),
            actions: [Text('First Option'), Text('Second Option')],
          ),
        ),
      );

      expect(find.text('First Option'), findsOneWidget);
      expect(find.text('Second Option'), findsOneWidget);
    });

    testWidgets('supports scrollable content', (tester) async {
      await tester.pumpWidget(
        buildTestable(
          const AppDialog(
            scrollable: true,
            title: Text('Scrollable Dialog'),
            content: SizedBox(height: 1000, child: Text('Long content')),
          ),
        ),
      );

      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('Long content'), findsOneWidget);
    });
  });
}
