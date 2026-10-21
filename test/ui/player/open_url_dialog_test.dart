import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/widgets/open_url_dialog.dart';

void main() {
  testWidgets(
    'keeps URLs without a host in the dialog and accepts a correction',
    (tester) async {
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  opened = await showDialog<String>(
                    context: context,
                    builder: (_) => const OpenUrlDialog(),
                  );
                },
                child: const Text('Show dialog'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show dialog'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'https:///movie.mp4');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      expect(find.byType(OpenUrlDialog), findsOneWidget);
      expect(find.text('Enter a valid http or https address.'), findsOneWidget);
      expect(opened, isNull);

      await tester.enterText(
        find.byType(TextField),
        '  https://example.org/movie.mp4?token=value  ',
      );
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid http or https address.'), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened, 'https://example.org/movie.mp4?token=value');
      expect(tester.takeException(), isNull);
    },
  );
}
