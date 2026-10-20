import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/player/player_controller.dart';
import '../ui/player/widgets/queue_panel.dart';
import '../data/services/playback_statistics.dart';

/// Native verification only. The normal application never runs this workload.
Future<Map<String, Object?>> runPlaybackBenchmark({
  required PlayerController controller,
  required GlobalKey rootKey,
  required int cycles,
  required List<String> sources,
  required String progressPath,
  Duration warmup = const Duration(seconds: 5),
}) async {
  if (!Platform.isWindows || cycles < 1 || cycles > 1000) {
    throw ArgumentError(
      'Native texture benchmarks require Windows and 1–1000 cycles.',
    );
  }
  final timings = <ui.FrameTiming>[];
  final cycleRecords = <Map<String, Object?>>[];
  final progress = File(progressPath);
  Future<void> phase(String name) =>
      progress.writeAsString(jsonEncode({'phase': name}), flush: true);
  void collect(List<ui.FrameTiming> values) => timings.addAll(values);
  WidgetsBinding.instance.addTimingsCallback(collect);
  try {
    await phase('queue');
    final queueWatch = Stopwatch()..start();
    await controller.openPaths(sources);
    await _wait(
      () =>
          controller.hasMedia &&
          controller.isPlaying &&
          controller.duration > Duration.zero,
    );
    queueWatch.stop();
    if (controller.duration <
        Duration(seconds: cycles + warmup.inSeconds + 15)) {
      throw StateError(
        'The benchmark fixture is too short for uninterrupted playback.',
      );
    }
    final root = rootKey.currentContext! as Element;
    final queueButton = _find(root, (element) {
      final widget = element.widget;
      return widget is IconButton &&
          (widget.tooltip?.startsWith('Queue (') ?? false);
    });
    if (queueButton == null) throw StateError('Queue button was not found.');
    final coldWatch = Stopwatch()..start();
    (queueButton.widget as IconButton).onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final initialThumbnails = controller.queue.take(8).toList(growable: false);
    final thumbnails = await Future.wait(
      initialThumbnails.map(controller.loadThumbnail),
    );
    coldWatch.stop();
    if (thumbnails.any((thumbnail) => thumbnail == null)) {
      throw StateError('A visible queue fixture did not produce artwork.');
    }
    final warmWatch = Stopwatch()..start();
    await Future.wait(initialThumbnails.map(controller.loadThumbnail));
    warmWatch.stop();
    await _exerciseQueue(root);
    await phase('warmup');
    await Future<void>.delayed(warmup);
    timings.clear();
    final initialRss = ProcessInfo.currentRss;
    final playbackBefore = await readNativePlaybackStatistics(
      controller.player,
    );
    final handle = await controller.player.handle;
    Future<Map<String, Object?>> stats() async {
      final result =
          await const MethodChannel(
            'com.alexmercerind/media_kit_video',
          ).invokeMapMethod<String, Object?>(
            'VideoOutputManager.GetFrameStats',
            {'handle': handle.toString()},
          );
      if (result == null) {
        throw StateError('Native frame counters are unavailable.');
      }
      return result;
    }

    Future<double> nativePosition() async {
      final native = controller.player.platform;
      if (native is! NativePlayer) {
        throw StateError('Native playback is required.');
      }
      return double.parse(await native.getProperty('time-pos'));
    }

    await phase('cycles');
    for (var cycle = 1; cycle <= cycles; cycle++) {
      final positionBefore = await nativePosition();
      await windowManager.minimize();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final hidden = await stats();
      if (hidden['visible'] != false || !controller.player.state.playing) {
        throw StateError(
          'Video visibility or playback changed incorrectly while minimized.',
        );
      }
      final hiddenSerial = hidden['rendered']! as int;
      final restoreWatch = Stopwatch()..start();
      await windowManager.restore();
      Map<String, Object?> restored = const {};
      await _wait(() async {
        restored = await stats();
        return restored['visible'] == true &&
            (restored['consumed']! as int) > hiddenSerial;
      });
      restoreWatch.stop();
      final positionAfter = await nativePosition();
      if (!controller.player.state.playing || positionAfter <= positionBefore) {
        throw StateError(
          'Playback did not advance across minimize/restore cycle $cycle.',
        );
      }
      cycleRecords.add({
        'cycle': cycle,
        'restoreToTextureMs': restoreWatch.elapsedMicroseconds / 1000,
        'positionBeforeSeconds': positionBefore,
        'positionAfterSeconds': positionAfter,
        'renderedFrame': restored['rendered'],
        'consumedFrame': restored['consumed'],
        'outputWidth': restored['width'],
        'outputHeight': restored['height'],
        'rssBytes': ProcessInfo.currentRss,
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // Timings are delivered in batches. Let the last raster batch arrive.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await phase('complete');
    return {
      'cycles': cycles,
      'queueItems': controller.queue.length,
      'queueLoadMs': queueWatch.elapsedMicroseconds / 1000,
      'initialViewportThumbnails': initialThumbnails.length,
      'coldViewportThumbnailMs': coldWatch.elapsedMicroseconds / 1000,
      'warmViewportThumbnailMs': warmWatch.elapsedMicroseconds / 1000,
      'restoreMetric':
          'restore request to a fresh native texture consumed by Flutter raster',
      'restoreMetricLimit':
          'Includes polling latency; does not measure OS compositor scan-out.',
      'restoreToTextureMs': _percentiles(
        cycleRecords.map((row) => row['restoreToTextureMs']! as double),
      ),
      'uiFrameMs': _percentiles(
        timings.map((timing) => timing.buildDuration.inMicroseconds / 1000),
      ),
      'rasterFrameMs': _percentiles(
        timings.map((timing) => timing.rasterDuration.inMicroseconds / 1000),
      ),
      'frameTimingsCount': timings.length,
      'initialRssBytesAfterWarmup': initialRss,
      'finalRssBytes': ProcessInfo.currentRss,
      'playbackBeforeCycles': playbackBefore.values,
      'playbackAfterCycles': (await readNativePlaybackStatistics(
        controller.player,
      )).values,
      'cycleSamples': cycleRecords,
      'frameSamples': timings
          .map(
            (timing) => {
              'uiMs': timing.buildDuration.inMicroseconds / 1000,
              'rasterMs': timing.rasterDuration.inMicroseconds / 1000,
            },
          )
          .toList(growable: false),
    };
  } finally {
    WidgetsBinding.instance.removeTimingsCallback(collect);
    await windowManager.restore();
  }
}

Future<void> _exerciseQueue(Element root) async {
  final panel = _find(root, (element) => element.widget is QueuePanel);
  if (panel == null) throw StateError('Queue panel did not open.');
  final scrollable = _find(
    panel,
    (element) => element is StatefulElement && element.state is ScrollableState,
  );
  if (scrollable != null) {
    final position =
        ((scrollable as StatefulElement).state as ScrollableState).position;
    for (final fraction in [0.5, 1.0, 0.0]) {
      position.jumpTo(position.maxScrollExtent * fraction);
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
  }
  final search = _find(
    panel,
    (element) =>
        element.widget is TextField &&
        element.widget.key == const ValueKey('queue-search'),
  );
  if (search != null) {
    final field = search.widget as TextField;
    for (final query in ['fixture', '001', '']) {
      field.controller!.text = query;
      field.onChanged!(query);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}

Element? _find(Element root, bool Function(Element) matches) {
  if (matches(root)) return root;
  Element? found;
  root.visitChildElements((child) => found ??= _find(child, matches));
  return found;
}

Future<void> _wait(FutureOr<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Benchmark condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 8));
  }
}

Map<String, double> _percentiles(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) {
    throw StateError('The benchmark collected no timing samples.');
  }
  double percentile(double fraction) =>
      sorted[((sorted.length - 1) * fraction).ceil()];
  return {
    'min': sorted.first,
    'p50': percentile(0.5),
    'p95': percentile(0.95),
    'max': sorted.last,
  };
}
