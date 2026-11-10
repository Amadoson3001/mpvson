import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_harness.dart';
import '../../support/audit_helpers.dart';

void main() {
  Finder recentTiles() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_RecentTile',
  );

  Finder dropZone() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_DropZoneCard',
  );

  Future<Harness> pumpHome(WidgetTester tester) async {
    final h = buildHarness(populated: false);
    configureView(tester, size: const Size(1920, 1080));
    await tester.pumpWidget(h.app());
    await settle(tester);
    final files = await makeMediaFiles(tester, [
      'a.mp3',
      'b.mp3',
      'c.mp3',
      'd.mp3',
    ]);
    for (final path in files) {
      await tester.runAsync(() async {
        await h.controller.openPaths([path]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);
    }
    await tapNav(tester, 'Home');
    await settle(tester);
    return h;
  }

  testWidgets('recent grid stays on the 960 measure with the header', (
    tester,
  ) async {
    final h = await pumpHome(tester);

    expect(recentTiles(), findsWidgets);
    final column = tester.getRect(dropZone());
    expect(column.width, moreOrLessEquals(960, epsilon: 1));
    final first = tester.getRect(recentTiles().first);
    final last = tester.getRect(recentTiles().last);
    expect(first.left, moreOrLessEquals(column.left, epsilon: 1));
    expect(last.right, moreOrLessEquals(column.right, epsilon: 1));

    await h.shutdown(tester);
  });

  testWidgets('recent tile action menu meets the minimum target', (
    tester,
  ) async {
    final h = await pumpHome(tester);

    final menus = find.byType(PopupMenuButton<String>);
    expect(menus, findsWidgets);
    final size = tester.getSize(menus.first);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));

    await h.shutdown(tester);
  });
}
