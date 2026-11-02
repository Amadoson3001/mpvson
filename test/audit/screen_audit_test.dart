import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/audit_helpers.dart';

/// Renders the real app across window size x text scale x theme x data state
/// and fails on any layout exception or any text outside the app font.
///
/// Run one slice while iterating:
///   flutter test test/audit/screen_audit_test.dart --plain-name "min720x480"
void main() {
  for (final dark in [true, false]) {
    for (final scale in [1.0, 1.5]) {
      for (final entry in auditSizes.entries) {
        for (final state in ['empty', 'full', 'audio', 'video']) {
          final name = '${dark ? 'dark' : 'light'} x$scale ${entry.key} $state';
          testWidgets(name, (tester) async {
            final h = buildHarness(dark: dark, populated: state != 'empty');
            final size = entry.value;
            final problems = <String>[];
            configureView(tester, size: size, textScale: scale);

            problems.addAll(
              await auditStep(tester, 'boot', () async {
                await tester.pumpWidget(h.app());
                await settle(tester);
              }),
            );

            if (state == 'audio' || state == 'video') {
              final names = state == 'audio'
                  ? [
                      'Long Track Title That Keeps Going And Going.mp3',
                      'b.mp3',
                      'c.mkv',
                    ]
                  : ['c.mkv', 'Long Track Title That Keeps Going.mp3', 'b.mp3'];
              problems.addAll(
                await auditStep(tester, 'open-$state', () async {
                  await openMedia(tester, h, names);
                  await hover(tester, size.center(Offset.zero));
                }),
              );
              if (state == 'video') {
                problems.addAll(
                  await auditStep(tester, 'video-menu', () async {
                    final g = await tester.createGesture(
                      kind: PointerDeviceKind.mouse,
                      buttons: kSecondaryMouseButton,
                    );
                    await g.addPointer(location: size.center(Offset.zero));
                    await g.down(size.center(Offset.zero));
                    await g.up();
                    await settle(tester);
                    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                    await settle(tester);
                  }),
                );
                problems.addAll(
                  await auditStep(tester, 'video-queue', () async {
                    await tapQueueToggle(tester);
                  }),
                );
                // Return to the library for the section sweep.
                await tapText(tester, 'Home');
                await settle(tester);
              }
            }

            for (final s in navSections) {
              problems.addAll(
                await auditStep(tester, s, () => tapNav(tester, s)),
              );
              if (s == 'Music') {
                for (final tab in ['Albums', 'Artists', 'Songs']) {
                  problems.addAll(
                    await auditStep(tester, 'Music/$tab', () async {
                      await tapText(tester, tab);
                    }),
                  );
                }
              }
              if (s == 'Settings') {
                for (final page in [
                  'Playback',
                  'Video & audio',
                  'Shortcuts',
                  'Desktop & system',
                  'About & engine',
                  'Appearance',
                ]) {
                  problems.addAll(
                    await auditStep(tester, 'Settings/$page', () async {
                      await tapText(tester, page);
                    }),
                  );
                }
              }
            }

            if (state == 'audio') {
              problems.addAll(
                await auditStep(tester, 'now-playing', () async {
                  await tapNav(tester, 'Home');
                  await tester.tapAt(Offset(120, size.height - 55));
                  await settle(tester);
                  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                  await settle(tester);
                }),
              );
              problems.addAll(
                await auditStep(tester, 'queue', () => tapQueueToggle(tester)),
              );
            }

            if (state == 'full' || state == 'empty') {
              problems.addAll(
                await auditStep(tester, 'dialog-url', () async {
                  await tapNav(tester, 'Home');
                  await tapText(tester, 'Open URL');
                  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                  await settle(tester);
                }),
              );
              problems.addAll(
                await auditStep(tester, 'dialog-new-playlist', () async {
                  await tapNav(tester, 'Playlists');
                  if (!await tapText(tester, 'New playlist')) {
                    await tapText(tester, 'Create playlist');
                  }
                  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                  await settle(tester);
                }),
              );
            }

            await h.shutdown(tester);
            expect(
              problems.toSet().toList(),
              isEmpty,
              reason: problems.toSet().join('\n'),
            );
          });
        }
      }
    }
  }
}

Future<void> tapQueueToggle(WidgetTester tester) async {
  for (final tip in ['Open queue', 'Queue']) {
    final f = find.byTooltip(tip);
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      return;
    }
  }
}
