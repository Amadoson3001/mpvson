import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_harness.dart';
import '../../support/audit_helpers.dart';

void main() {
  testWidgets('compact Settings keeps the drawer and an explicit exit', (
    tester,
  ) async {
    final h = buildHarness(populated: false);
    configureView(tester, size: const Size(720, 480));
    await tester.pumpWidget(h.app());
    await settle(tester);

    await tapNav(tester, 'Settings');
    expect(find.text('Appearance'), findsWidgets);
    expect(find.byTooltip('Open navigation'), findsOneWidget);
    expect(find.byTooltip('Close settings'), findsOneWidget);

    // Navigation from Settings must actually reach another section.
    await tapNav(tester, 'Videos');
    expect(find.text('No videos found'), findsOneWidget);

    await h.shutdown(tester);
  });

  testWidgets('Close settings returns to the previous section', (tester) async {
    final h = buildHarness(populated: false);
    configureView(tester, size: const Size(720, 480));
    await tester.pumpWidget(h.app());
    await settle(tester);

    await tapNav(tester, 'Settings');
    expect(find.text('Appearance'), findsWidgets);

    await tester.tap(find.byTooltip('Close settings'));
    await settle(tester);

    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Open file'), findsWidgets);

    await h.shutdown(tester);
  });
}
