import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/components/media_tile.dart';

void main() {
  testWidgets('MediaTile exposes one labeled tap target', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: MediaTile(
                artwork: const SizedBox.expand(),
                title: 'Album',
                subtitle: 'Artist',
                onTap: () {},
                trailing: IconButton(
                  tooltip: 'Playlist actions',
                  onPressed: () {},
                  icon: const Icon(Icons.more_vert),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final tile = tester.getSemantics(find.byType(MediaTile));
    expect(tile.label, 'Album, Artist');
    expect(tile.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(tile.getSemanticsData().flagsCollection.isButton, isTrue);

    final menu = tester.getSemantics(find.byTooltip('Playlist actions'));
    expect(menu.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    handle.dispose();
  });
}
