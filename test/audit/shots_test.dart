import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/audit_helpers.dart';
import '../support/screenshot.dart';

/// Visual review only, never part of the normal run. Writes PNGs to
/// build/shots/. Use:
///   flutter test test/audit/shots_test.dart --dart-define=SHOTS=true
/// Optional: --dart-define=SHOT_PREFIX=music  (only tests whose tag contains it)
const bool _enabled = bool.fromEnvironment('SHOTS');
const String _only = String.fromEnvironment('SHOT_ONLY');

bool _want(String tag) => _only.isEmpty || tag.contains(_only);

void main() {
  setUpAll(loadAppFonts);

  for (final dark in [true, false]) {
    for (final size in const [Size(1240, 780), Size(720, 480)]) {
      final tag = '${dark ? 'dark' : 'light'}_${size.width.toInt()}';
      if (!_want(tag)) continue;

      testWidgets('shots sections $tag', (tester) async {
        final h = buildHarness(dark: dark);
        configureView(tester, size: size);
        await tester.pumpWidget(h.app());
        await settle(tester);
        for (final s in navSections) {
          await tapNav(tester, s);
          await capture(tester, '${tag}_$s');
          if (s == 'Music') {
            for (final t in ['Albums', 'Artists']) {
              await tapText(tester, t);
              await capture(tester, '${tag}_Music_$t');
            }
          }
          if (s == 'Settings') {
            for (final p in [
              'Playback',
              'Video & audio',
              'Shortcuts',
              'Desktop & system',
              'About & engine',
            ]) {
              await tapText(tester, p);
              await capture(
                tester,
                '${tag}_Settings_${p.replaceAll(RegExp(r'\W+'), '')}',
              );
            }
          }
        }
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('shots audio $tag', (tester) async {
        final h = buildHarness(dark: dark);
        configureView(tester, size: size);
        await tester.pumpWidget(h.app());
        await settle(tester);
        await openMedia(tester, h, [
          'Starlight Serenade.flac',
          'Midnight Echoes - Ambient Mix.flac',
          'Solar Wind Symphony.mp3',
          'Neon Horizon - Synthwave Chill.wav',
          'Velvet Moon Acoustics.flac',
          'Aura Borealis - Deep Drift.mp3',
        ]);
        await capture(tester, '${tag}_audio_home');
        await tester.tapAt(Offset(120, size.height - 55));
        await settle(tester);
        await capture(tester, '${tag}_audio_nowplaying');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        for (final tip in ['Open queue', 'Queue']) {
          final f = find.byTooltip(tip);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first, warnIfMissed: false);
            await settle(tester);
            await capture(tester, '${tag}_audio_queue');
            break;
          }
        }
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('shots video $tag', (tester) async {
        final h = buildHarness(dark: dark);
        configureView(tester, size: size);
        await tester.pumpWidget(h.app());
        await settle(tester);
        await openMedia(tester, h, ['A movie with a title.mkv', 'b.mp3']);
        await hover(tester, size.center(Offset.zero));
        await capture(tester, '${tag}_video_chrome');
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('shots dialogs $tag', (tester) async {
        final h = buildHarness(dark: dark);
        configureView(tester, size: size);
        await tester.pumpWidget(h.app());
        await settle(tester);
        await tapText(tester, 'Open URL');
        await capture(tester, '${tag}_dialog_url');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        await tapNav(tester, 'Playlists');
        await tapText(tester, 'New playlist');
        await capture(tester, '${tag}_dialog_new_playlist');
        await h.shutdown(tester);
      }, skip: !_enabled);
    }
  }
}
