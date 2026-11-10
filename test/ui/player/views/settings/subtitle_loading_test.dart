import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/player/views/settings/settings_playback_section.dart';

import '../../../../support/app_harness.dart';

void main() {
  testWidgets('embedded subtitle load keeps the host route', (tester) async {
    final h = Harness.create();
    var picked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSettingsSection(
            controller: h.controller,
            embedded: true,
            pickSubtitle: () async {
              picked = true;
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.text('Load external subtitle…');
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(picked, isTrue);
    // Embedded settings share the host route, so the section must survive the
    // pick instead of being popped away with the whole library/player.
    expect(find.text('Load external subtitle…'), findsOneWidget);
    expect(find.text('Queue & session'), findsOneWidget);

    await h.shutdown(tester);
  });

  testWidgets('dialog subtitle load dismisses the settings route', (
    tester,
  ) async {
    final h = Harness.create();
    var picked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: SizedBox(
                      width: 480,
                      height: 560,
                      child: PlaybackSettingsSection(
                        controller: h.controller,
                        pickSubtitle: () async {
                          picked = true;
                          return null;
                        },
                      ),
                    ),
                  ),
                ),
                child: const Text('open settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();

    final tile = find.text('Load external subtitle…');
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(picked, isTrue);
    // Dialog mode keeps the existing dismiss-then-pick behavior.
    expect(find.text('Load external subtitle…'), findsNothing);
    expect(find.text('open settings'), findsOneWidget);

    await h.shutdown(tester);
  });
}
