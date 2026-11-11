import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/widgets/empty_library.dart';

void main() {
  testWidgets('Remove button is mounted without hover and removes the entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final entry = MediaEntry(
      id: 'entry-1',
      path: r'C:\Videos\clip.mp4',
      title: 'clip.mp4',
      lastPlayed: DateTime(2026, 1, 5),
    );
    MediaEntry? removed;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: EmptyLibrary(
            recent: [entry],
            onOpenFiles: () {},
            onOpenUrl: () {},
            onOpenRecent: (_) {},
            onRemoveRecent: (e) => removed = e,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The control exists in the tree from the first frame; no hover needed.
    final removeButton = find.byTooltip('Remove from recently played');
    expect(removeButton, findsOneWidget);

    // Hovering the row reveals it for interaction.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.text('clip.mp4')));
    await tester.pumpAndSettle();

    await tester.tap(removeButton);
    await tester.pumpAndSettle();

    expect(removed?.id, 'entry-1');
  });

  testWidgets('Remove button participates in the semantics tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final entry = MediaEntry(
      id: 'entry-2',
      path: r'C:\Videos\other.mp4',
      title: 'other.mp4',
      lastPlayed: DateTime(2026, 2, 9),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: EmptyLibrary(
            recent: [entry],
            onOpenFiles: () {},
            onOpenUrl: () {},
            onOpenRecent: (_) {},
            onRemoveRecent: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final handle = tester.getSemantics(find.byType(IconButton));
    expect(handle.flagsCollection.isButton, isTrue);
    // Child text merges into the row node instead of being excluded, which
    // proves excludeSemantics is dropped: the path text only comes from the
    // merged child, never from the row's own label.
    expect(handle.label, contains(r'C:\Videos\other.mp4'));
  });
}
