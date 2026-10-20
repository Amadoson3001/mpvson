import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/playback_statistics.dart';
import 'package:mpvson/ui/player/views/playback_info_dialog.dart';

void main() {
  test(
    'reports active decoding and converts sync seconds to milliseconds',
    () async {
      final statistics = await PlaybackStatistics.read(
        (name) async => switch (name) {
          'hwdec-current' => 'no',
          'avsync' => '-0.0125',
          'container-fps' => '23.9760239',
          'demuxer-cache-duration' => '2.34',
          'frame-drop-count' => '4',
          _ => '',
        },
      );
      expect(statistics.values['Active decoder'], 'Software');
      expect(statistics.values['Audio/video difference'], '-12.5 ms');
      expect(statistics.values['Source frame rate'], '23.976 fps');
      expect(statistics.values['Buffered media'], '2.3 s');
      expect(statistics.values['Frames dropped by output'], '4');
      expect(statistics.values['Video codec'], 'Unavailable');
    },
  );

  test(
    'unavailable, non-finite and stalled properties cannot block a sample',
    () async {
      final statistics = await PlaybackStatistics.read((name) {
        if (name == 'mpv-version') return Future.value('mpv 0.41.0');
        if (name == 'avsync') return Future.value('NaN');
        if (name == 'hwdec-current') throw StateError('No active decoder');
        return Completer<String>().future;
      }, timeout: const Duration(milliseconds: 10));
      expect(statistics.values['Playback engine'], 'mpv 0.41.0');
      expect(statistics.values['Audio/video difference'], 'Unavailable');
      expect(statistics.values['Active decoder'], 'Unavailable');
      expect(statistics.values['Display width'], 'Unavailable');
    },
  );

  testWidgets('refresh is explicit and late reads after closing are harmless', (
    tester,
  ) async {
    var reads = 0;
    final lateRead = Completer<PlaybackStatistics>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PlaybackInfoDialog(
                readStatistics: () {
                  reads++;
                  return reads == 1
                      ? Future.value(
                          const PlaybackStatistics({
                            'Active decoder': 'd3d11va',
                          }),
                        )
                      : lateRead.future;
                },
              ),
            ),
            child: const Text('Inspect'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
    expect(find.text('d3d11va'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(reads, 1);
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(reads, 2);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    lateRead.complete(const PlaybackStatistics({'Active decoder': 'Software'}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
