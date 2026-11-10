import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/tokens/motion.dart';
import 'package:mpvson/ui/player/views/settings/floating_video_settings.dart';

import '../../../../support/app_harness.dart';
import '../../../../support/audit_helpers.dart';

void main() {
  testWidgets('settings sections swap instantly without a cross-fade', (
    tester,
  ) async {
    final h = buildHarness(populated: false);
    configureView(tester, size: const Size(1240, 780));
    await tester.pumpWidget(h.app());
    await settle(tester);

    await tapNav(tester, 'Settings');
    await tester.tap(find.text('Playback').first);
    await settle(tester);

    await tester.tap(find.text('Video & audio').first);
    // A single frame must already show the new pane and drop the old one; a
    // cross-fade would keep both mounted while the opacity animates.
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Rendering engine'), findsOneWidget);
    expect(find.text('Queue & session'), findsNothing);

    await h.shutdown(tester);
  });

  testWidgets('floating video settings does not blur the video behind it', (
    tester,
  ) async {
    final h = Harness.create();
    configureView(tester, size: const Size(1240, 780));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              FloatingVideoSettings(
                controller: h.controller,
                pickSubtitle: () async => null,
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Video Settings'), findsOneWidget);
    // The near-opaque panel should not pay for a full-screen backdrop blur.
    expect(find.byType(BackdropFilter), findsNothing);

    await h.shutdown(tester);
  });

  testWidgets('stage transition is a single fade, not fade plus glide', (
    tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    const child = SizedBox.shrink();
    final result = AppMotion.stageTransition(
      hostContext,
      child,
      const AlwaysStoppedAnimation<double>(0.5),
    );
    if (AppMotion.lowPower(hostContext)) {
      expect(result, same(child));
    } else {
      expect(result, isA<FadeTransition>());
      expect((result as FadeTransition).child, same(child));
    }
  });
}
