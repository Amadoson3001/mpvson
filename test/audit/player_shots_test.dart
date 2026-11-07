import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/playback_service.dart';

import '../support/app_harness.dart';
import '../support/audit_helpers.dart';
import '../support/screenshot.dart';
import 'player_harness.dart';

/// Visual review of the video stage, chrome, queue and context menu. Never part
/// of the normal run. Use:
///   flutter test test/audit/player_shots_test.dart --dart-define=SHOTS=true
///     --dart-define=SHOT_DIR=player --dart-define=SHOT_ONLY=dark_1240
const bool _enabled = bool.fromEnvironment('SHOTS');
const String _only = String.fromEnvironment('SHOT_ONLY');

bool _want(String tag) => _only.isEmpty || tag.contains(_only);

PlaybackSnapshot _state(Harness h) => h.playback.state;

void main() {
  setUpAll(loadAppFonts);

  for (final dark in [true, false]) {
    for (final size in const [Size(1240, 780), Size(720, 480)]) {
      final tag = '${dark ? 'dark' : 'light'}_${size.width.toInt()}';
      if (!_want(tag)) continue;

      testWidgets('player chrome $tag', (tester) async {
        for (final video in [FakeVideo.bright, FakeVideo.dark]) {
          final h = await bootPlayer(
            tester,
            size: size,
            dark: dark,
            video: video,
          );
          await capture(tester, '${tag}_chrome_${video.name}_playing');
          h.playback.emit(_state(h).copyWith(isPlaying: false));
          await settle(tester);
          await capture(tester, '${tag}_chrome_${video.name}_paused');
          if (video == FakeVideo.bright) {
            h.playback.emit(_state(h).copyWith(isBuffering: true));
            await tester.pump(const Duration(milliseconds: 300));
            await capture(tester, '${tag}_chrome_buffering');
            h.playback.emit(
              _state(
                h,
              ).copyWith(isBuffering: false, error: 'Could not open the file.'),
            );
            await settle(tester);
            await capture(tester, '${tag}_chrome_error');
          }
          await h.shutdown(tester);
        }
      }, skip: !_enabled);

      testWidgets('player 1.5x text $tag', (tester) async {
        final h = await bootPlayer(
          tester,
          size: size,
          dark: dark,
          textScale: 1.5,
          video: FakeVideo.bright,
        );
        await capture(tester, '${tag}_chrome_x1.5');
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('player queue $tag', (tester) async {
        final h = await bootPlayer(
          tester,
          size: size,
          dark: dark,
          video: FakeVideo.dark,
          names: [
            'A movie with a very long title that keeps going and going.mkv',
            'Song one.mp3',
            'c.mp4',
            'Another track.flac',
          ],
        );
        await tester.tap(find.byTooltip('Queue (4)').first);
        await settle(tester);
        await capture(tester, '${tag}_queue_open');
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('player context menu $tag', (tester) async {
        final h = await bootPlayer(tester, size: size, dark: dark);
        // The right-click gesture below adds another mouse pointer, so the
        // boot hover must go first (one live mouse pointer at a time).
        await releasePlayerHover(tester);
        final at = Offset(size.width * 0.3, size.height * 0.3);
        final g = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await g.addPointer(location: at);
        await g.down(at);
        await g.up();
        await settle(tester);
        await capture(tester, '${tag}_context_menu');
        await tester.tap(find.text('Playback speed').first);
        await settle(tester);
        await capture(tester, '${tag}_context_menu_speed');
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('player feedback $tag', (tester) async {
        final h = await bootPlayer(
          tester,
          size: size,
          dark: dark,
          video: FakeVideo.bright,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 250));
        await capture(tester, '${tag}_feedback_volume');
        await settle(tester);
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('player audio queue sheet $tag', (tester) async {
        final h = buildHarness(dark: dark);
        configureView(tester, size: size);
        await tester.pumpWidget(playerApp(h));
        await settle(tester);
        await openMedia(tester, h, [
          'Long Track Title That Keeps Going.mp3',
          'b.mp3',
          'c.mp3',
          'Video.mkv',
        ]);
        for (final tip in ['Open queue', 'Queue']) {
          final f = find.byTooltip(tip);
          if (f.evaluate().isNotEmpty) {
            await tester.tap(f.first, warnIfMissed: false);
            await settle(tester);
            // Distinct name: shots_test.dart's "shots audio" also captures
            // ${tag}_audio_queue, and one write must not clobber the other.
            await capture(tester, '${tag}_player_audio_queue');
            break;
          }
        }
        await h.shutdown(tester);
      }, skip: !_enabled);

      testWidgets('player empty and ready $tag', (tester) async {
        final h = buildHarness(dark: dark, populated: false);
        configureView(tester, size: size);
        await tester.pumpWidget(playerApp(h));
        await settle(tester);
        await capture(tester, '${tag}_empty');
        await h.shutdown(tester);
      }, skip: !_enabled);
    }
  }
}
