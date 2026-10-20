import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_thumbnail.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_screen.dart';
import 'package:mpvson/ui/player/views/settings_dialog.dart';
import 'package:mpvson/ui/player/views/update_center_dialog.dart';
import 'package:mpvson/ui/player/widgets/media_ready.dart';
import 'package:mpvson/ui/player/widgets/queue_panel.dart';
import 'package:mpvson/ui/player/widgets/player_controls.dart';
import 'package:mpvson/ui/player/widgets/player_context_menu.dart';
import 'package:mpvson/ui/player/widgets/empty_library.dart';

void main() {
  for (final width in [600.0, 1240.0]) {
    testWidgets('video and audio tuning fits a $width pixel window', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        await _openSettings(tester);
        final navigation = find.byKey(
          ValueKey(
            width >= 700
                ? 'settings-navigation-rail'
                : 'settings-top-navigation',
          ),
        );
        await _selectSettingsSection(tester, navigation, 'Video & audio');
        expect(find.text('Quality preset'), findsOneWidget);
        await tester.tap(find.byType(DropdownButton<PlaybackQualityPreset>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Performance').last);
        await tester.pumpAndSettle();
        expect(
          fixture.controller.playbackSettings.qualityPreset,
          PlaybackQualityPreset.performance,
        );
        await _capturePreview(tester, 'video-audio-${width.toInt()}');
        final reset = find.byKey(const ValueKey('reset-playback-settings'));
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(fixture.controller.playbackSettings, PlaybackSettings.defaults);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }

  testWidgets('playback information opens from More and the I shortcut', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playback information'));
      await tester.pumpAndSettle();
      expect(find.text('Playback information'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      expect(find.text('Playback information'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Queue (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('queue-search')));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();
      expect(find.text('Playback information'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'native fullscreen reconciles overlapping and early resize notifications',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      const channel = MethodChannel('window_manager');
      final firstRead = Completer<bool>();
      var reads = 0;
      var nativeFullscreen = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'isFullScreen') {
          reads++;
          if (reads == 1) return firstRead.future;
          return nativeFullscreen;
        }
        return null;
      });
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: PlayerScreen(
              controller: fixture.controller,
              updates: fixture.updates,
              engineUpdates: fixture.engineUpdates,
              desktopWindow: true,
              enableNativeDrop: false,
              videoBuilder: (_, _) => const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester.binding.handleMetricsChanged();
        await tester.pump();
        tester.binding.handleMetricsChanged();
        await tester.pump();
        expect(reads, 1);
        firstRead.complete(false);
        await tester.pump();
        expect(
          reads,
          2,
          reason: 'An overlapping notification must not be dropped.',
        );
        // The OS flag changes after the resize read, with no further metrics or
        // playback notification. The trailing reconciliation must still find it.
        nativeFullscreen = true;
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pumpAndSettle();
        expect(reads, greaterThanOrEqualTo(3));
        await tester.pump(const Duration(milliseconds: 2300));
        await tester.pump(const Duration(milliseconds: 200));
        expect(_controlOpacity(tester), 0);
        expect(
          tester
              .widget<MouseRegion>(find.byKey(const ValueKey('video-surface')))
              .cursor,
          SystemMouseCursors.none,
        );
      } finally {
        if (!firstRead.isCompleted) firstRead.complete(false);
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  setUpAll(() async {
    if (!const bool.fromEnvironment('MPVSON_CAPTURE_UI')) return;
    final previewFrame = File('test-output/thumbnail-native/frame.png');
    if (await previewFrame.exists()) {
      _FakeThumbnailService._pngBytes = await previewFrame.readAsBytes();
    }
    final fonts = <String, String>{
      if (Platform.isWindows) 'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
    };
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      fonts['MaterialIcons'] =
          '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf';
    }
    for (final font in fonts.entries) {
      final file = File(font.value);
      if (!await file.exists()) continue;
      final loader = FontLoader(
        font.key,
      )..addFont(file.readAsBytes().then((bytes) => bytes.buffer.asByteData()));
      await loader.load();
    }
  });

  for (final size in [const Size(720, 480), const Size(1240, 780)]) {
    for (final textScale in [1.0, 1.5]) {
      testWidgets(
        'control density switches live at ${size.width.toInt()} with text scale $textScale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          final fixture = await _PlayerFixture.create();
          try {
            await fixture.controller.playIndex(0);
            await tester.pumpWidget(
              _buildApp(fixture, fullscreenSetter: (_) async {}),
            );
            await tester.pumpAndSettle();
            final strip = find.byKey(const ValueKey('player-control-strip'));
            final seek = find.byKey(const ValueKey('seek-slider'));
            final compactWidth = tester.getSize(seek).width;
            expect(fixture.controller.controlDensity, ControlDensity.compact);
            expect(tester.getSize(strip).height, 60);
            expect(tester.getSize(find.byTooltip('Pause')).height, 32);
            expect(tester.getSize(find.byTooltip('More options')).height, 32);
            expect(tester.getSize(find.byTooltip('Fullscreen')).height, 32);
            expect(compactWidth, greaterThan(size.width - 24));
            if (textScale == 1) {
              await _capturePreview(
                tester,
                'density-compact-${size.width.toInt()}',
              );
            }

            await _openSettings(tester);
            final selector = find.byKey(
              const ValueKey('control-density-selector'),
            );
            expect(selector, findsOneWidget);
            expect(
              tester.widget<SegmentedButton<ControlDensity>>(selector).selected,
              {ControlDensity.compact},
            );
            if (textScale == 1) {
              expect(
                tester
                    .getRect(
                      find.byKey(const ValueKey('control-density-preview')),
                    )
                    .bottom,
                lessThan(tester.getRect(find.text('Done')).top),
              );
              await _capturePreview(
                tester,
                'density-settings-${size.width.toInt()}',
              );
            }
            await tester.tap(
              find.descendant(of: selector, matching: find.text('Normal')),
            );
            await tester.pumpAndSettle();
            expect(fixture.controller.controlDensity, ControlDensity.normal);
            expect(fixture.controller.hasMedia, isTrue);
            expect(fixture.controller.isPlaying, isTrue);
            if (textScale == 1) {
              await _capturePreview(
                tester,
                'density-settings-normal-${size.width.toInt()}',
              );
            }
            await tester.tap(find.text('Done'));
            await tester.pumpAndSettle();
            expect(tester.getSize(strip).height, 96);
            expect(tester.getSize(find.byTooltip('Pause')).height, 44);
            expect(tester.getSize(seek).width, lessThan(compactWidth));
            if (textScale == 1) {
              await _capturePreview(
                tester,
                'density-normal-${size.width.toInt()}',
              );
            }

            await _openSettings(tester);
            expect(
              tester.widget<SegmentedButton<ControlDensity>>(selector).selected,
              {ControlDensity.normal},
            );
            await tester.tap(
              find.descendant(of: selector, matching: find.text('Compact')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Done'));
            await tester.pumpAndSettle();
            expect(tester.getSize(strip).height, 60);
            final seekRect = tester.getRect(seek);
            await tester.tapAt(
              Offset(seekRect.left + seekRect.width * 0.4, seekRect.center.dy),
            );
            await tester.pumpAndSettle();
            expect(
              fixture.controller.position.inSeconds,
              closeTo(fixture.controller.duration.inSeconds * 0.4, 2),
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.byTooltip('Queue (2)'));
            await tester.pumpAndSettle();
            expect(find.byType(QueuePanel), findsOneWidget);
            await tester.tap(find.byTooltip('Remove second.mkv from queue'));
            await tester.pumpAndSettle();
            await tester.tap(
              find.descendant(
                of: find.byType(QueuePanel),
                matching: find.text('Undo'),
              ),
            );
            await tester.pumpAndSettle();
            expect(fixture.controller.queue, hasLength(2));
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync<void>(fixture.dispose);
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        },
      );
    }
  }

  testWidgets(
    'wheel volume works over video, coalesces trackpad input and ignores the queue',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await fixture.controller.setVolume(40);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        const videoPoint = Offset(450, 260);
        await _wheel(tester, videoPoint, const Offset(0, -120));
        expect(fixture.controller.volume, 45);
        expect(find.text('Volume 45%'), findsOneWidget);
        await _capturePreview(tester, 'volume-feedback');
        await _wheel(tester, videoPoint, const Offset(0, 20));
        expect(fixture.controller.volume, 40);
        for (var i = 0; i < 4; i++) {
          await _wheel(tester, videoPoint, const Offset(0, -4));
        }
        expect(fixture.controller.volume, 40);
        await _wheel(tester, videoPoint, const Offset(0, -4));
        expect(fixture.controller.volume, 45);
        await _wheel(tester, videoPoint, const Offset(120, 0));
        expect(fixture.controller.volume, 45);
        await fixture.controller.setVolume(98);
        await _wheel(tester, videoPoint, const Offset(0, -20));
        expect(fixture.controller.volume, 100);
        await fixture.controller.setVolume(2);
        await _wheel(tester, videoPoint, const Offset(0, 20));
        expect(fixture.controller.volume, 0);
        expect(find.text('Muted'), findsOneWidget);

        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        await _wheel(tester, const Offset(1100, 320), const Offset(0, -120));
        expect(fixture.controller.volume, 0);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const ValueKey('playback-feedback')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'fullscreen hides controls and cursor after mouse use but protects keyboard focus and dragging',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      final fullscreenCalls = <bool>[];
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(
          _buildApp(
            fixture,
            fullscreenSetter: (value) async {
              fullscreenCalls.add(value);
            },
          ),
        );
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
          pointer: 42,
        );
        await mouse.addPointer(location: const Offset(4, 4));
        final fullscreenPoint = tester.getCenter(find.byTooltip('Fullscreen'));
        await mouse.moveTo(fullscreenPoint);
        await mouse.down(fullscreenPoint);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true]);
        await tester.pump(const Duration(milliseconds: 2300));
        await tester.pump(const Duration(milliseconds: 200));
        expect(_controlOpacity(tester), 0);
        expect(
          tester
              .widget<MouseRegion>(find.byKey(const ValueKey('video-surface')))
              .cursor,
          SystemMouseCursors.none,
        );
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.none,
        );
        await _capturePreview(tester, 'fullscreen-hidden');

        await mouse.moveTo(fullscreenPoint + const Offset(1, 0));
        await tester.pump();
        expect(_controlOpacity(tester), 0);
        await mouse.moveTo(const Offset(600, 300));
        await tester.pumpAndSettle();
        expect(_controlOpacity(tester), 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        expect(_controlOpacity(tester), 1);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();

        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('seek-slider'))),
        );
        await tester.pumpAndSettle();
        final seekPoint = tester.getCenter(
          find.byKey(const ValueKey('seek-slider')),
        );
        await mouse.down(seekPoint);
        await mouse.moveTo(const Offset(650, 300));
        await tester.pump(const Duration(seconds: 4));
        expect(_controlOpacity(tester), 1);
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 2300));
        await tester.pump(const Duration(milliseconds: 200));
        expect(_controlOpacity(tester), 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true, false]);
        expect(_controlOpacity(tester), 1);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'video clicks pause, double-click toggles fullscreen and M restores volume',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      final fullscreenCalls = <bool>[];
      try {
        await fixture.controller.playIndex(0);
        await fixture.controller.setVolume(35);
        await tester.pumpWidget(
          _buildApp(
            fixture,
            fullscreenSetter: (value) async {
              fullscreenCalls.add(value);
            },
          ),
        );
        await tester.pumpAndSettle();
        const center = Offset(620, 320);
        await tester.tapAt(center);
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.controller.isPlaying, isFalse);
        expect(find.text('Paused'), findsOneWidget);
        await tester.tapAt(center);
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.controller.isPlaying, isTrue);
        await tester.tapAt(center);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.tapAt(center);
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true]);
        expect(fixture.controller.isPlaying, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.pumpAndSettle();
        expect(fixture.controller.volume, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.pumpAndSettle();
        expect(fixture.controller.volume, 35);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true, false]);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('open-url-input')),
          'https://media.example/film',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(fixture.controller.volume, 35);
        expect(fullscreenCalls, [true, false]);
        expect(find.text('Open URL'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  for (final size in [const Size(720, 480), const Size(1240, 780)]) {
    testWidgets(
      'right-click menu fits ${size.width.toInt()} and controls playback, speed and subtitles',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final fixture = await _PlayerFixture.create();
        final subtitleDirectory = Directory.systemTemp.createTempSync(
          'mpvson-subtitles-',
        );
        final subtitleFile =
            File('${subtitleDirectory.path}${Platform.pathSeparator}movie.srt')
              ..writeAsStringSync(
                '1\n00:00:00,000 --> 00:00:02,000\nTest subtitle\n',
              );
        var subtitlePickerCalls = 0;
        try {
          await fixture.controller.playIndex(0);
          await tester.pumpWidget(
            _buildApp(
              fixture,
              fullscreenSetter: (_) async {},
              subtitlePicker: () async {
                subtitlePickerCalls++;
                return subtitleFile.path;
              },
            ),
          );
          await tester.pumpAndSettle();
          final point = Offset(size.width - 12, size.height - 130);
          await _rightClick(tester, point);
          expect(find.text('Seek'), findsOneWidget);
          final pauseRect = tester.getRect(
            find.widgetWithText(MenuItemButton, 'Pause'),
          );
          final settingsRect = tester.getRect(
            find.widgetWithText(MenuItemButton, 'Settings'),
          );
          await _capturePreview(tester, 'context-${size.width.toInt()}');
          expect(pauseRect.top, greaterThanOrEqualTo(0));
          expect(settingsRect.bottom, lessThanOrEqualTo(size.height));
          await tester.pump(const Duration(seconds: 4));
          expect(_controlOpacity(tester), 1);
          await _capturePreview(tester, 'context-${size.width.toInt()}');
          await tester.tap(find.text('Playback speed'));
          await tester.pumpAndSettle();
          await _capturePreview(tester, 'context-speed-${size.width.toInt()}');
          await tester.tap(find.text('1.5×'));
          await tester.pumpAndSettle();
          expect(fixture.controller.rate, 1.5);
          expect(find.text('Seek'), findsNothing);

          await _rightClick(tester, point);
          await tester.tap(find.widgetWithText(MenuItemButton, 'Pause'));
          await tester.pumpAndSettle();
          expect(fixture.controller.isPlaying, isFalse);
          expect(_controlOpacity(tester), 1);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.f10);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pumpAndSettle();
          expect(find.text('Seek'), findsOneWidget);
          await tester.tap(find.text('Subtitles'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Off'));
          await tester.pumpAndSettle();
          expect(fixture.controller.currentSubtitleTrack.id, 'no');
          await _rightClick(tester, point);
          await tester.tap(find.text('Subtitles'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Load subtitle file'));
          await tester.pump();
          expect(subtitlePickerCalls, 1);
          await tester.runAsync(() async {
            final deadline = Stopwatch()..start();
            while (fixture.playback.lastSubtitlePath == null &&
                deadline.elapsed < const Duration(seconds: 1)) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          });
          await tester.pumpAndSettle();
          expect(fixture.playback.lastSubtitlePath, subtitleFile.path);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync<void>(fixture.dispose);
          subtitleFile.deleteSync();
          subtitleDirectory.deleteSync();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }

  testWidgets('720 by 480 uses a queue drawer and keeps text input intact', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create(
      thumbnails: _FakeThumbnailService(),
    );

    await tester.pumpWidget(_buildApp(fixture));
    await tester.pumpAndSettle();

    expect(find.byType(MediaReady), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-video')), findsNothing);
    expect(find.byType(QueuePanel), findsNothing);

    await tester.tap(find.byTooltip('Queue (2)'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    await _capturePreview(tester, 'queue-thumbnails-compact');

    final search = find.byKey(const ValueKey('queue-search'));
    await tester.enterText(search, 'second');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(QueuePanel),
        matching: find.text('second.mkv'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(QueuePanel),
        matching: find.text('first.mp4'),
      ),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('Queue'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fixture.controller.isPlaying, isFalse);

    await tester.tap(find.byTooltip('Close queue'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Open URL'), findsOneWidget);

    final urlField = find.byType(TextField);
    await tester.enterText(urlField, 'https://stream.example/watch/p');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('Open URL'), findsOneWidget);
    expect(fixture.controller.isPlaying, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync<void>(fixture.dispose);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('1240 by 780 docks the queue beside the native video surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create(
      thumbnails: _FakeThumbnailService(),
    );

    await tester.pumpWidget(_buildApp(fixture));
    await tester.pumpAndSettle();

    expect(find.byType(MediaReady), findsOneWidget);
    expect(find.byType(QueuePanel), findsNothing);
    await _capturePreview(tester, 'ready-wide');
    await tester.tap(find.byTooltip('Queue (2)'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    await _capturePreview(tester, 'queue-thumbnails-wide');
    expect(tester.getSize(find.byType(QueuePanel)).width, 352);
    expect(
      find.descendant(
        of: find.byType(QueuePanel),
        matching: find.text('first.mp4'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(QueuePanel),
        matching: find.text('second.mkv'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('resume-current')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
    await _capturePreview(tester, 'playback-queue-wide');

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Resume at 00:42'), findsOneWidget);
    await tester.tap(find.text('Resume at 00:42'));
    await tester.pumpAndSettle();
    expect(
      fixture.controller.current?.path,
      'https://media.example/second.mkv',
    );

    await _openSettings(tester);
    expect(find.text('Settings'), findsOneWidget);
    await _capturePreview(tester, 'settings-wide');
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Official mpv stable releases'), findsOneWidget);
    await tester.ensureVisible(find.text('Updates & about'));
    await tester.tap(find.text('Updates & about'));
    await tester.pumpAndSettle();
    expect(find.text('Not configured'), findsOneWidget);
    expect(
      find.text('Update checks are not configured for this build.'),
      findsOneWidget,
    );
    expect(find.text('Application'), findsOneWidget);
    expect(find.text('Playback engine'), findsAtLeastNWidgets(1));
    expect(find.text('Loaded engine version libmpv test fake'), findsOneWidget);
    expect(find.text('Source: Official mpv stable releases'), findsOneWidget);
    expect(
      find.text('Engine update checks are not configured for this build.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync<void>(fixture.dispose);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  testWidgets('temporary speed restores when window or text focus changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await fixture.controller.playIndex(0);
      await fixture.controller.setRate(1.25);
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Queue (2)'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 200));
      expect(fixture.controller.rate, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(fixture.controller.rate, 1.25);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 200));
      expect(fixture.controller.rate, 2);
      await tester.tap(find.byKey(const ValueKey('queue-search')));
      await tester.pump();
      expect(fixture.controller.rate, 1.25);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.controller.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('seeking, mute and speed menus remain usable during playback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await fixture.controller.playIndex(0);
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      final seek = find.byKey(const ValueKey('seek-slider'));
      final seekRect = tester.getRect(seek);
      expect(tester.getRect(find.byKey(const ValueKey('fake-video'))).top, 0);
      expect(find.text('Mpvson'), findsNothing);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(seekRect.center);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('seek-preview')), findsOneWidget);
      expect(find.text('02:00'), findsOneWidget);
      expect(fixture.controller.position, Duration.zero);
      await _capturePreview(tester, 'timeline-hover');
      await mouse.moveTo(Offset(seekRect.left + 1, seekRect.center.dy));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('seek-preview'))).left,
        greaterThanOrEqualTo(0),
      );
      await mouse.moveTo(Offset(seekRect.right - 1, seekRect.center.dy));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('seek-preview'))).right,
        lessThanOrEqualTo(1240),
      );
      await mouse.removePointer();
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        Offset(seekRect.left + seekRect.width * 0.25, seekRect.center.dy),
      );
      await drag.moveTo(
        Offset(seekRect.left + seekRect.width * 0.75, seekRect.center.dy),
      );
      await tester.pump();
      expect(fixture.controller.position, Duration.zero);
      await drag.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        fixture.controller.position,
        greaterThan(const Duration(minutes: 2)),
      );
      await tester.tapAt(
        Offset(seekRect.left + seekRect.width * 0.6, seekRect.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        fixture.controller.position,
        greaterThan(const Duration(minutes: 2)),
      );

      final volume = find.byKey(const ValueKey('volume-inline-slider'));
      await tester.tap(volume);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(fixture.controller.volume, 0);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pump();
      expect(fixture.controller.volume, greaterThan(0));

      await tester.tap(find.byTooltip('Playback speed'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      expect(_controlOpacity(tester), 1);
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(fixture.controller.rate, 1.5);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_controlOpacity(tester), 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('shuffle and repeat sit on the bottom bar as buttons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await fixture.controller.playIndex(0);
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      // Neither control hides in the overflow menu anymore.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Turn shuffle on'), findsNothing);
      expect(find.text('Repeat off'), findsNothing);
      await tester.tapAt(const Offset(620, 390));
      await tester.pumpAndSettle();

      final barTop = tester.getRect(find.byType(PlayerControls)).top;
      final shuffleButton = find.byKey(const ValueKey('shuffle-toggle'));
      final repeatButton = find.byKey(const ValueKey('repeat-toggle'));
      expect(shuffleButton, findsOneWidget);
      expect(repeatButton, findsOneWidget);
      expect(tester.getRect(shuffleButton).top, greaterThanOrEqualTo(barTop));
      expect(tester.getRect(repeatButton).top, greaterThanOrEqualTo(barTop));
      expect(find.byTooltip('Turn shuffle on'), findsOneWidget);
      expect(find.byTooltip('Repeat off'), findsOneWidget);

      // A hovering mouse keeps the bar open, as on a real desktop.
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(4, 4));
      await mouse.moveTo(tester.getCenter(shuffleButton));
      await mouse.down(tester.getCenter(shuffleButton));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.shuffle, isTrue);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: shuffleButton,
                matching: find.byType(IconButton),
              ),
            )
            .isSelected,
        isTrue,
      );

      await mouse.moveTo(tester.getCenter(repeatButton));
      await mouse.down(tester.getCenter(repeatButton));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.repeatMode, 'all');
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: repeatButton,
                matching: find.byType(IconButton),
              ),
            )
            .isSelected,
        isTrue,
      );

      await mouse.down(tester.getCenter(repeatButton));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.repeatMode, 'one');
      expect(find.byIcon(Icons.repeat_one_rounded), findsOneWidget);

      await mouse.down(tester.getCenter(repeatButton));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.repeatMode, 'off');
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: repeatButton,
                matching: find.byType(IconButton),
              ),
            )
            .isSelected,
        isFalse,
      );

      await mouse.moveTo(tester.getCenter(shuffleButton));
      await mouse.down(tester.getCenter(shuffleButton));
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(fixture.controller.shuffle, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('queue removal, undo and empty search stay actionable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Queue (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove first.mp4 from queue'));
      await tester.pumpAndSettle();
      expect(fixture.controller.queue.length, 1);
      await tester.tap(
        find.descendant(
          of: find.byType(QueuePanel),
          matching: find.text('Undo'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.controller.queue.length, 2);
      await tester.enterText(
        find.byKey(const ValueKey('queue-search')),
        'missing-film',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('queue-queue-first')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-queue-second')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'queue avoids playback-tick filtering and tracks transport and metadata',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('queue-search')),
          'first',
        );
        await tester.pumpAndSettle();

        final searchedSnapshot = fixture.controller.queueSnapshot;
        final filterCalls = searchedSnapshot.filterIndexedCallCount;
        expect(find.byKey(const ValueKey('queue-queue-first')), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*currently playing')),
          findsOneWidget,
        );

        for (var second = 1; second <= 4; second++) {
          fixture.playback.emitPosition(Duration(seconds: second));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          searchedSnapshot.filterIndexedCallCount,
          filterCalls,
          reason: 'Position ticks must not rebuild or refilter the queue',
        );

        await fixture.controller.togglePlayPause();
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*current item')),
          findsOneWidget,
          reason: 'The current row must follow pause without a queue rebuild',
        );
        expect(searchedSnapshot.filterIndexedCallCount, filterCalls);

        await fixture.controller.togglePlayPause();
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*currently playing')),
          findsOneWidget,
        );
        expect(searchedSnapshot.filterIndexedCallCount, filterCalls);

        fixture.playback.emitDuration(const Duration(minutes: 6));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('queue-duration-queue-first')),
              )
              .data,
          '06:00',
        );
        expect(
          fixture.controller.queueSnapshot.filterIndexedCallCount,
          greaterThan(filterCalls),
          reason: 'Resolved duration metadata must refresh queue rows',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'wide queue thumbnails preserve truthful playback semantics and add files',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final thumbnails = _FakeThumbnailService(
        unavailableIds: const <String>{'queue-second'},
      );
      final fixture = await _PlayerFixture.create(thumbnails: thumbnails);
      var pickerCalls = 0;
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(
          _buildAppWithMediaPicker(fixture, () async {
            pickerCalls++;
            return const ['https://media.example/added.mp4'];
          }),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        final queuePanel = find.byType(QueuePanel);

        final firstPosition = find.bySemanticsLabel(
          RegExp(r'first\.mp4.*track 1 of 2'),
        );
        final secondPosition = find.bySemanticsLabel(
          RegExp(r'second\.mkv.*track 2 of 2'),
        );
        expect(firstPosition, findsOneWidget);
        expect(secondPosition, findsOneWidget);
        expect(
          find.descendant(of: queuePanel, matching: find.text('01')),
          findsNothing,
        );
        expect(
          find.descendant(of: queuePanel, matching: find.text('02')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('queue-playing-queue-first')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('queue-current-queue-first')),
          findsNothing,
        );
        expect(
          find.descendant(of: queuePanel, matching: find.text('Playing')),
          findsNothing,
        );
        expect(
          find.descendant(of: queuePanel, matching: find.text('Current')),
          findsNothing,
        );

        final firstThumbnail = find.byKey(
          const ValueKey('queue-thumbnail-queue-first'),
        );
        final secondThumbnail = find.byKey(
          const ValueKey('queue-thumbnail-queue-second'),
        );
        expect(firstThumbnail, findsOneWidget);
        expect(secondThumbnail, findsOneWidget);
        final firstImage = find.descendant(
          of: firstThumbnail,
          matching: find.byType(Image),
        );
        expect(firstImage, findsOneWidget);
        final firstImageProvider = tester.widget<Image>(firstImage).image;
        final memoryImage = firstImageProvider is ResizeImage
            ? firstImageProvider.imageProvider as MemoryImage
            : firstImageProvider as MemoryImage;
        expect(memoryImage.bytes, equals(_FakeThumbnailService._pngBytes));
        expect(
          find.byKey(const ValueKey('queue-placeholder-queue-second-empty')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: secondThumbnail, matching: find.byType(Image)),
          findsNothing,
        );
        expect(fixture.controller.error, isNull);

        final titleFinder = find.byKey(
          const ValueKey('queue-title-queue-first'),
        );
        final pathFinder = find.byKey(const ValueKey('queue-path-queue-first'));
        expect(titleFinder, findsOneWidget);
        expect(pathFinder, findsOneWidget);
        final titleFontSize = tester.widget<Text>(titleFinder).style?.fontSize;
        final pathFontSize = tester.widget<Text>(pathFinder).style?.fontSize;
        expect(titleFontSize, isNotNull);
        expect(pathFontSize, isNotNull);
        expect(titleFontSize!, greaterThan(pathFontSize!));

        final duration = find.byKey(
          const ValueKey('queue-duration-queue-first'),
        );
        expect(duration, findsOneWidget);
        expect(tester.widget<Text>(duration).data, '04:00');
        final thumbnailRect = tester.getRect(firstThumbnail);
        final durationRect = tester.getRect(duration);
        expect(thumbnailRect.contains(durationRect.center), isTrue);
        expect(
          find.byKey(const ValueKey('queue-duration-queue-second')),
          findsNothing,
        );

        expect(find.byKey(const ValueKey('queue-add-files')), findsOneWidget);
        expect(find.bySemanticsLabel('2 videos in queue'), findsOneWidget);
        final playingSemantics = find.bySemanticsLabel(
          RegExp(r'first\.mp4.*currently playing'),
        );
        expect(playingSemantics, findsOneWidget);
        expect(
          tester.widget<Semantics>(playingSemantics).properties.selected,
          isTrue,
        );

        final loadsBeforePlaybackTicks = Map<String, int>.of(
          thumbnails.loadCountById,
        );
        for (var second = 1; second <= 3; second++) {
          fixture.playback.emitPosition(Duration(seconds: second));
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
        expect(thumbnails.loadCountById, loadsBeforePlaybackTicks);

        await fixture.controller.togglePlayPause();
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: queuePanel, matching: find.text('Playing')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('queue-playing-queue-first')),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*currently playing')),
          findsNothing,
        );
        final currentSemantics = find.bySemanticsLabel(
          RegExp(r'first\.mp4.*current item'),
        );
        expect(currentSemantics, findsOneWidget);
        expect(
          tester.widget<Semantics>(currentSemantics).properties.selected,
          isTrue,
        );
        expect(
          find.descendant(of: queuePanel, matching: find.text('Current')),
          findsNothing,
        );
        await fixture.controller.togglePlayPause();
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('queue-add-files')));
        await tester.pumpAndSettle();
        expect(pickerCalls, 1);
        expect(fixture.controller.queue, hasLength(3));
        expect(fixture.controller.queue.last.title, 'added.mp4');
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*track 1 of 3')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'added\.mp4.*track 3 of 3')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'queue revalidates replaced local artwork through the shared thumbnail cache',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'mpvson-queue-artwork-',
        );
        final source = File('${root.path}${Platform.pathSeparator}sample.mp4');
        await source.writeAsBytes(<int>[1, 2, 3], flush: true);
        final firstArtwork = await _solidPng(const Color(0xFFCC3344));
        final replacementArtwork = await _solidPng(const Color(0xFF3366CC));
        final replacementExtraction = Completer<void>();
        final extractor = _SequencedThumbnailExtractor(<Uint8List>[
          firstArtwork,
          replacementArtwork,
        ], secondExtractionGate: replacementExtraction.future);
        final thumbnailService = MediaKitThumbnailService(
          extractor: extractor,
          cacheDirectory: Directory(
            '${root.path}${Platform.pathSeparator}cache',
          ),
        );
        final entry = MediaEntry.fromPath(source.path, id: 'local-queue-item');
        final fixture = await _PlayerFixture.create(
          thumbnails: thumbnailService,
          session: PlaybackSession(
            queue: <MediaEntry>[entry],
            recent: const <MediaEntry>[],
            currentId: entry.id,
            volume: 100,
            saveNetworkUrls: false,
          ),
        );

        try {
          await tester.pumpWidget(_buildApp(fixture));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Queue (1)'));
          await tester.pump();
          await thumbnailService.load(entry);
          await tester.pumpAndSettle();

          expect(extractor.extractionCount, 1);
          final initialImage = find.descendant(
            of: find.byType(QueuePanel),
            matching: find.byType(Image),
          );
          expect(initialImage, findsOneWidget);
          expect(_queueImageBytes(tester, initialImage), firstArtwork);

          // Replace the media contents at the same path. The new queue row must
          // validate against the service fingerprint instead of reusing artwork
          // retained by a path-only widget cache.
          await (() async {
            await source.writeAsBytes(List<int>.filled(64, 0x7F), flush: true);
            await source.setLastModified(
              DateTime.now().add(const Duration(seconds: 2)),
            );
          })();
          await fixture.controller.openPaths(<String>[
            source.path,
          ], append: false);
          for (
            var attempt = 0;
            attempt < 20 && extractor.extractionCount < 2;
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(fixture.controller.queue, hasLength(1));
          expect(extractor.extractionCount, 2);
          final replacementImage = find.descendant(
            of: find.byType(QueuePanel),
            matching: find.byType(Image),
          );
          expect(replacementImage, findsOneWidget);
          expect(
            _queueImageBytes(tester, replacementImage),
            firstArtwork,
            reason:
                'Keep provisional artwork visible while replacement validates.',
          );

          replacementExtraction.complete();
          await thumbnailService.load(fixture.controller.queue.single);
          await tester.pumpAndSettle();

          final currentThumbnail = thumbnailService.peek(
            fixture.controller.queue.single,
          );
          expect(currentThumbnail, isNotNull);
          expect(
            _queueImageBytes(tester, replacementImage),
            currentThumbnail!.bytes,
          );
          expect(
            _queueImageBytes(tester, replacementImage),
            replacementArtwork,
          );

          // Closing and reopening the queue must reuse the service-owned entry;
          // the widget does not keep a second byte cache alive between mounts.
          await tester.tap(find.byTooltip('Close queue'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Queue (1)'));
          await tester.pumpAndSettle();
          expect(extractor.extractionCount, 2);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.dispose();
          await root.delete(recursive: true);
        }
      });
    },
  );

  for (final textScale in [1.5, 2.0]) {
    testWidgets('queue drawer fits at 720 by 480 with $textScale text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      final fixture = await _PlayerFixture.create(
        thumbnails: _FakeThumbnailService(),
      );
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsNothing);

        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsOneWidget);
        final panelRect = tester.getRect(find.byType(QueuePanel));
        expect(panelRect.width, 360);
        expect(panelRect.right, 720);
        expect(find.byKey(const ValueKey('queue-search')), findsOneWidget);
        expect(find.byTooltip('Close queue'), findsOneWidget);
        expect(find.byKey(const ValueKey('queue-add-files')), findsOneWidget);
        expect(find.bySemanticsLabel('2 videos in queue'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*currently playing')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*track 1 of 2')),
          findsOneWidget,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('queue-add-files'))).bottom,
          lessThanOrEqualTo(480),
        );
        final discoveredDuration = find.byKey(
          const ValueKey('queue-duration-queue-second'),
        );
        expect(tester.widget<Text>(discoveredDuration).data, '03:01');
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey('queue-thumbnail-queue-second')),
              )
              .contains(tester.getRect(discoveredDuration).center),
          isTrue,
        );
        expect(tester.takeException(), isNull);

        final search = find.byKey(const ValueKey('queue-search'));
        await tester.enterText(search, 'second');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('queue-queue-second')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('queue-queue-first')), findsNothing);
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('queue-queue-first')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Close queue'));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }

  testWidgets('one queue open state survives resizing and stays closed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 800);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await fixture.controller.playIndex(0);
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsNothing);

      // Open the inline panel at a wide width and give it state to preserve.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsOneWidget);
      expect(tester.getSize(find.byType(QueuePanel)).width, 352);
      final search = find.byKey(const ValueKey('queue-search'));
      await tester.enterText(search, 'second');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('queue-queue-second')), findsOneWidget);

      // Crossing the breakpoint keeps the same logical panel, its search text
      // and its filtered result instead of silently closing the queue.
      tester.view.physicalSize = const Size(720, 560);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-queue-second')), findsOneWidget);
      expect(
        tester.widget<TextField>(search).controller?.text,
        'second',
        reason: 'the panel keeps its search across a presentation change',
      );
      expect(find.byTooltip('Close queue'), findsOneWidget);

      // An explicit close stays closed after the window grows again.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsNothing);
      tester.view.physicalSize = const Size(1240, 800);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsNothing);

      // And the toggle opens exactly one panel again.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('wide settings use the side rail and preserve each section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      await _openSettings(tester);

      final navigation = find.byKey(const ValueKey('settings-navigation-rail'));
      expect(navigation, findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-top-navigation')),
        findsNothing,
      );
      final selector = find.byKey(const ValueKey('control-density-selector'));
      expect(selector, findsOneWidget);
      expect(
        tester.widget<SegmentedButton<ControlDensity>>(selector).selected,
        {fixture.controller.controlDensity},
      );
      await tester.tap(
        find.descendant(of: selector, matching: find.text('Normal')),
      );
      await tester.pumpAndSettle();
      expect(fixture.controller.controlDensity, ControlDensity.normal);

      await _selectSettingsSection(tester, navigation, 'Playback');
      expect(find.text('Shuffle'), findsOneWidget);
      expect(find.text('Playback speed'), findsOneWidget);
      await _selectSettingsSection(tester, navigation, 'Shortcuts');
      expect(find.text('Play or pause'), findsOneWidget);
      await _selectSettingsSection(tester, navigation, 'About');
      expect(find.text('Updates & about'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('stream URL persistence is opt-in and remembered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final stream = MediaEntry.fromPath(
      'https://media.example/stream.mp4?token=secret',
      id: 'stream-one',
      lastPlayed: DateTime(2026, 10, 14),
    );
    final fixture = await _PlayerFixture.create(
      session: PlaybackSession(queue: [stream], volume: 100),
    );
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      expect(fixture.controller.saveNetworkUrls, isFalse);
      // A stored URL that was never consented to is not restored at launch.
      expect(fixture.controller.queue, isEmpty);

      await _openSettings(tester);
      final navigation = find.byKey(const ValueKey('settings-navigation-rail'));
      await _selectSettingsSection(tester, navigation, 'Playback');

      final toggle = find.byKey(const ValueKey('save-network-urls-toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.textContaining('complete stream URLs'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(fixture.controller.saveNetworkUrls, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(
        fixture.sessions.session?.saveNetworkUrls,
        isTrue,
        reason: 'the choice is written to the session file',
      );

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await _openSettings(tester);
      await _selectSettingsSection(tester, navigation, 'Playback');
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        isTrue,
        reason: 'the setting is remembered across dialogs',
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(fixture.controller.saveNetworkUrls, isFalse);
      expect(fixture.sessions.session?.saveNetworkUrls, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'compact settings use top navigation and keep controls reachable at 1.5 scale',
    (tester) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      final fixture = await _PlayerFixture.create();
      try {
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        await _openSettings(tester);

        final navigation = find.byKey(
          const ValueKey('settings-top-navigation'),
        );
        expect(navigation, findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-navigation-rail')),
          findsNothing,
        );
        expect(
          tester.getRect(find.text('Done')).bottom,
          lessThanOrEqualTo(480),
        );

        final selector = find.byKey(const ValueKey('control-density-selector'));
        expect(selector, findsOneWidget);
        await tester.ensureVisible(
          find.descendant(of: selector, matching: find.text('Normal')),
        );
        await tester.tap(
          find.descendant(of: selector, matching: find.text('Normal')),
        );
        await tester.pumpAndSettle();
        expect(fixture.controller.controlDensity, ControlDensity.normal);

        await _selectSettingsSection(tester, navigation, 'Playback');
        expect(find.text('Shuffle'), findsOneWidget);
        await _selectSettingsSection(tester, navigation, 'Shortcuts');
        expect(find.text('Play or pause'), findsOneWidget);
        await _selectSettingsSection(tester, navigation, 'About');
        final updatesRow = find.text('Updates & about');
        await tester.ensureVisible(updatesRow);
        expect(updatesRow, findsOneWidget);
        await tester.tap(updatesRow);
        await tester.pumpAndSettle();
        expect(find.byType(UpdateCenterDialog), findsOneWidget);
        expect(
          tester.getRect(find.text('Close')).bottom,
          lessThanOrEqualTo(480),
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsDialog), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  for (final size in [const Size(720, 480), const Size(1240, 780)]) {
    testWidgets(
      'home and URL flow fit ${size.width.toInt()} by ${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final fixture = await _PlayerFixture.create(empty: true);
        try {
          await tester.pumpWidget(_buildApp(fixture));
          await tester.pumpAndSettle();
          expect(find.byType(EmptyLibrary), findsOneWidget);
          expect(find.byType(QueuePanel), findsNothing);
          expect(find.text('Open a video'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _capturePreview(tester, 'home-${size.width.toInt()}');

          await tester.tap(find.byKey(const ValueKey('open-url')));
          await tester.pumpAndSettle();
          final urlInput = find.byKey(const ValueKey('open-url-input'));
          await tester.enterText(urlInput, 'invalid-address');
          await tester.testTextInput.receiveAction(TextInputAction.go);
          await tester.pumpAndSettle();
          expect(
            find.text('Enter a valid http or https address.'),
            findsOneWidget,
          );
          expect(fixture.controller.current, isNull);
          await tester.enterText(urlInput, 'https://media.example/new.mp4');
          await _capturePreview(tester, 'url-${size.width.toInt()}');
          await tester.testTextInput.receiveAction(TextInputAction.go);
          await tester.pumpAndSettle();
          expect(
            fixture.controller.current?.path,
            'https://media.example/new.mp4',
          );
          expect(find.byType(PlayerControls), findsOneWidget);
          expect(find.byType(QueuePanel), findsNothing);
          expect(
            tester.getRect(find.byKey(const ValueKey('fake-video'))).top,
            0,
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('seek-slider'))).width,
            greaterThan(size.width - 64),
          );
          expect(
            tester.getCenter(find.byTooltip('More options')).dy,
            greaterThan(size.height - 60),
          );
          expect(tester.takeException(), isNull);
          await _capturePreview(tester, 'playback-${size.width.toInt()}');

          await _openSettings(tester);
          expect(find.text('Settings'), findsOneWidget);
          await _capturePreview(tester, 'settings-${size.width.toInt()}');
          await tester.tap(find.text('Shortcuts'));
          await tester.pumpAndSettle();
          expect(find.text('Play or pause'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync<void>(fixture.dispose);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }

  testWidgets(
    'compact queue drawer dismissed by Escape while search field has focus',
    (tester) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsOneWidget);

        final search = find.byKey(const ValueKey('queue-search'));
        expect(search, findsOneWidget);
        await tester.tap(search);
        await tester.pumpAndSettle();
        await tester.enterText(search, 'movie');
        await tester.pumpAndSettle();

        final primaryFocus = FocusManager.instance.primaryFocus;
        expect(
          primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(),
          isNotNull,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('drag reorder and Delete target the selected queue item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Queue (2)'));
      await tester.pumpAndSettle();
      expect(fixture.controller.queue[0].id, 'queue-first');
      expect(fixture.controller.queue[1].id, 'queue-second');

      final firstEntryFinder = find.byKey(const ValueKey('queue-queue-first'));
      expect(firstEntryFinder, findsOneWidget);
      final hover = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      final firstEntryCenter = tester.getCenter(firstEntryFinder);
      await hover.addPointer(location: firstEntryCenter);
      await hover.moveTo(firstEntryCenter);
      await tester.pumpAndSettle();
      final dragHandle = find.byKey(const ValueKey('queue-drag-queue-first'));
      expect(dragHandle, findsOneWidget);
      final dragHandleOpacity = find.descendant(
        of: dragHandle,
        matching: find.byType(AnimatedOpacity),
      );
      expect(dragHandleOpacity, findsOneWidget);
      expect(
        tester.widget<AnimatedOpacity>(dragHandleOpacity).opacity,
        greaterThan(0),
      );
      await hover.removePointer();
      final drag = await tester.startGesture(
        tester.getCenter(dragHandle),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 200));
      await drag.moveBy(const Offset(0, 145));
      await tester.pump(const Duration(milliseconds: 300));
      await drag.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.queue[0].id, 'queue-second');
      expect(fixture.controller.queue[1].id, 'queue-first');

      final reorderedFirstEntry = find.byKey(
        const ValueKey('queue-queue-first'),
      );
      final materialFinder = find.descendant(
        of: reorderedFirstEntry,
        matching: find.byType(Material),
      );
      final focusNode = Focus.of(tester.element(materialFinder.first));
      focusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(focusNode.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(fixture.controller.queue.length, 1);
      expect(fixture.controller.queue.first.id, 'queue-second');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'accessibility semantics expose queue count, items, and speed/track states',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel(RegExp(r'Queue, 2 videos')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'Playback speed, selected 1(×|\.0×)')),
          findsOneWidget,
        );

        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('2 videos in queue'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'first\.mp4.*currently playing')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp(r'second\.mkv')), findsOneWidget);

        await _openSettings(tester);
        await tester.tap(find.text('Playback'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SettingsDialog),
            matching: find.bySemanticsLabel(
              RegExp(r'Playback speed, selected 1(\.0)?'),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(SettingsDialog),
            matching: find.bySemanticsLabel(RegExp(r'Audio track, selected')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(SettingsDialog),
            matching: find.bySemanticsLabel(
              RegExp(r'Subtitles track, selected'),
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'focused slider consumes arrow keys and prevents global shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await fixture.controller.setVolume(50);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        final seekFinder = find.byKey(const ValueKey('seek-slider'));
        expect(seekFinder, findsOneWidget);
        await tester.tap(seekFinder);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<Slider>(),
          isNotNull,
        );

        final initialVolume = fixture.controller.volume;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(fixture.controller.volume, initialVolume);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(fixture.controller.volume, initialVolume);

        final volumeFinder = find.byKey(const ValueKey('volume-inline-slider'));
        expect(volumeFinder, findsOneWidget);
        await tester.tap(volumeFinder);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<Slider>(),
          isNotNull,
        );

        final posBefore = fixture.controller.position;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(fixture.controller.position, posBefore);
        expect(fixture.controller.volume, lessThan(initialVolume));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'right-click menu dismisses on left-click over video without toggling playback',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();
        expect(fixture.controller.isPlaying, isTrue);

        const clickPoint = Offset(600, 300);
        await _rightClick(tester, clickPoint);
        expect(find.text('Seek'), findsOneWidget);

        const videoPoint = Offset(200, 200);
        await tester.tapAt(videoPoint);
        await tester.pumpAndSettle();

        expect(find.text('Seek'), findsNothing);
        expect(fixture.controller.isPlaying, isTrue);

        await tester.tapAt(videoPoint);
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.controller.isPlaying, isFalse);
        expect(find.text('Paused'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('right-click menu dismisses on Resume video in MediaReady', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      expect(find.byType(MediaReady), findsOneWidget);

      const center = Offset(400, 250);
      await _rightClick(tester, center);
      expect(find.text('Settings'), findsOneWidget);

      final resumeButton = find.byKey(const ValueKey('resume-current'));
      expect(resumeButton, findsOneWidget);
      await tester.tap(resumeButton);
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsNothing);
      expect(fixture.controller.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'right-click menu dismisses on Escape without closing fullscreen or compact queue',
    (tester) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      final fullscreenCalls = <bool>[];
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(
          _buildApp(
            fixture,
            fullscreenSetter: (val) async => fullscreenCalls.add(val),
          ),
        );
        await tester.pumpAndSettle();

        // Open context menu over video surface
        await _rightClick(tester, const Offset(300, 200));
        expect(find.text('Seek'), findsOneWidget);

        // Escape closes context menu
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Seek'), findsNothing);

        // Enter fullscreen
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true]);

        // Open context menu while in fullscreen
        await _rightClick(tester, const Offset(300, 200));
        expect(find.text('Seek'), findsOneWidget);

        // Escape closes context menu without exiting fullscreen
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Seek'), findsNothing);
        expect(fullscreenCalls, [true]);

        // Next Escape exits fullscreen
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(fullscreenCalls, [true, false]);

        // Open compact queue drawer
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsOneWidget);

        // Escape closes compact queue drawer
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(QueuePanel), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('right-click menu dismisses on mouse wheel scroll over video', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    try {
      await fixture.controller.playIndex(0);
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      const videoPoint = Offset(450, 260);
      await _rightClick(tester, videoPoint);
      expect(find.text('Seek'), findsOneWidget);

      await _wheel(tester, const Offset(200, 200), const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(find.text('Seek'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'right-click menu repositions when right-clicking another point on video',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        const firstPoint = Offset(300, 200);
        await _rightClick(tester, firstPoint);
        expect(find.text('Seek'), findsOneWidget);
        final firstRect = tester.getRect(
          find.widgetWithText(MenuItemButton, 'Pause'),
        );

        const secondPoint = Offset(600, 400);
        await _rightClick(tester, secondPoint);
        expect(find.text('Seek'), findsOneWidget);
        final secondRect = tester.getRect(
          find.widgetWithText(MenuItemButton, 'Pause'),
        );

        expect(secondRect.left, greaterThan(firstRect.left));
        expect(secondRect.top, greaterThan(firstRect.top));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('right-click menu dismisses on empty library background tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create(empty: true);
    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();
      expect(find.byType(EmptyLibrary), findsOneWidget);

      const point = Offset(200, 200);
      await _rightClick(tester, point);
      expect(find.text('Settings'), findsOneWidget);

      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('right-click menu and submenus respect reduced motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();
    final menuController = MenuController();

    Widget buildMenu(bool disableAnimations) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: PlayerContextMenu(
            playerController: fixture.controller,
            menuController: menuController,
            onOpenFiles: () {},
            onOpenUrl: () {},
            onToggleQueue: () {},
            onSettings: () {},
            onLoadSubtitle: () {},
            onToggleMute: () {},
            onAdjustVolume: (_) {},
            onMenuVisibilityChanged: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    try {
      await fixture.controller.playIndex(0);
      await tester.pumpWidget(buildMenu(false));
      await tester.pumpAndSettle();
      await _rightClick(tester, const Offset(480, 300));

      MenuAnchor rightClickAnchor() => tester
          .widgetList<MenuAnchor>(find.byType(MenuAnchor))
          .firstWhere((anchor) => anchor.controller == menuController);

      expect(rightClickAnchor().animated, isTrue);
      var submenus = tester
          .widgetList<SubmenuButton>(find.byType(SubmenuButton))
          .toList();
      expect(submenus, isNotEmpty);
      expect(submenus.every((submenu) => submenu.animated), isTrue);

      menuController.close();
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildMenu(true));
      await tester.pumpAndSettle();
      await _rightClick(tester, const Offset(480, 300));

      expect(rightClickAnchor().animated, isFalse);
      submenus = tester
          .widgetList<SubmenuButton>(find.byType(SubmenuButton))
          .toList();
      expect(submenus, isNotEmpty);
      expect(submenus.every((submenu) => submenu.animated), isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'play and pause morph through AnimatedIcon and honor reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _PlayerFixture.create();
      var disableAnimations = false;

      Widget buildControls() => MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: disableAnimations),
            child: Scaffold(
              body: AnimatedBuilder(
                animation: fixture.controller,
                builder: (context, _) =>
                    PlayerControls(controller: fixture.controller),
              ),
            ),
          ),
        ),
      );

      double iconProgress() =>
          tester.widget<AnimatedIcon>(find.byType(AnimatedIcon)).progress.value;

      try {
        await fixture.controller.playIndex(0);
        await tester.pumpWidget(buildControls());
        await tester.pumpAndSettle();
        expect(iconProgress(), closeTo(1, 0.001));

        await tester.tap(find.byTooltip('Pause'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(fixture.controller.isPlaying, isFalse);
        expect(iconProgress(), greaterThan(0));
        expect(iconProgress(), lessThan(1));
        await tester.pumpAndSettle();
        expect(iconProgress(), closeTo(0, 0.001));
        expect(find.byTooltip('Play'), findsOneWidget);

        await tester.tap(find.byTooltip('Play'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(fixture.controller.isPlaying, isTrue);
        expect(iconProgress(), greaterThan(0));
        expect(iconProgress(), lessThan(1));
        await tester.pumpAndSettle();
        expect(iconProgress(), closeTo(1, 0.001));

        disableAnimations = true;
        await tester.pumpWidget(buildControls());
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Pause'));
        await tester.pumpAndSettle();
        expect(fixture.controller.isPlaying, isFalse);
        expect(iconProgress(), closeTo(0, 0.001));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('inline volume slider keeps its width after hover and use', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final fixture = await _PlayerFixture.create();

    try {
      await fixture.controller.playIndex(0);
      await fixture.controller.setVolume(40);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: fixture.controller,
              builder: (context, _) =>
                  PlayerControls(controller: fixture.controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final slider = find.byKey(const ValueKey('volume-inline-slider'));
      final strip = find.byKey(const ValueKey('player-control-strip'));
      expect(slider, findsOneWidget);
      final initialSliderRect = tester.getRect(slider);
      final initialStripRect = tester.getRect(strip);
      expect(initialSliderRect.width, greaterThan(0));

      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(slider));
      await mouse.moveTo(tester.getCenter(slider));
      await tester.pumpAndSettle();
      final hoveredSliderRect = tester.getRect(slider);
      final hoveredStripRect = tester.getRect(strip);
      expect(hoveredSliderRect.width, closeTo(initialSliderRect.width, 0.01));
      expect(hoveredSliderRect.left, closeTo(initialSliderRect.left, 0.01));
      expect(hoveredStripRect.size, initialStripRect.size);
      await mouse.moveTo(const Offset(20, 20));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      var sliderRect = tester.getRect(slider);
      var stripRect = tester.getRect(strip);
      expect(sliderRect.width, closeTo(initialSliderRect.width, 0.01));
      expect(sliderRect.left, closeTo(initialSliderRect.left, 0.01));
      expect(stripRect.size, initialStripRect.size);

      await tester.drag(slider, const Offset(18, 0));
      await tester.pumpAndSettle();

      sliderRect = tester.getRect(slider);
      stripRect = tester.getRect(strip);
      expect(fixture.controller.volume, isNot(40));
      expect(sliderRect.width, closeTo(initialSliderRect.width, 0.01));
      expect(sliderRect.left, closeTo(initialSliderRect.left, 0.01));
      expect(stripRect.size, initialStripRect.size);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'queue thumbnails decode with ResizeImage physical size clamped to 320',
    (tester) async {
      tester.view.physicalSize = const Size(1280 * 3.5, 800 * 3.5);
      tester.view.devicePixelRatio = 3.5;
      final thumbnailService = _FakeThumbnailService();
      final fixture = await _PlayerFixture.create(thumbnails: thumbnailService);

      try {
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Queue (2)'));
        await tester.pumpAndSettle();

        final imageFinder = find.descendant(
          of: find.byType(QueuePanel),
          matching: find.byType(Image),
        );
        expect(imageFinder, findsWidgets);

        for (final imageWidget in tester.widgetList<Image>(imageFinder)) {
          expect(imageWidget.image, isA<ResizeImage>());
          final resize = imageWidget.image as ResizeImage;
          expect(resize.width, lessThanOrEqualTo(320));
          expect(resize.height, lessThanOrEqualTo(320));
          expect(resize.width, 320);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('queue thumbnails preserve aspect ratio and fill their frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 780);
    tester.view.devicePixelRatio = 1;
    final artwork = await tester.runAsync(
      () => _solidPng(const Color(0xFF3366CC)),
    );
    final thumbnailService = _FakeThumbnailService(bytes: artwork);
    final fixture = await _PlayerFixture.create(thumbnails: thumbnailService);

    try {
      await tester.pumpWidget(_buildApp(fixture));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Queue (2)'));
      await tester.pumpAndSettle();

      final frame = find.byKey(const ValueKey('queue-thumbnail-queue-first'));
      final image = find.descendant(of: frame, matching: find.byType(Image));
      expect(image, findsOneWidget);

      final provider = tester.widget<Image>(image).image;
      expect(provider, isA<ResizeImage>());
      expect(
        (provider as ResizeImage).policy,
        ResizeImagePolicy.fit,
        reason: 'A 16:9 decode target must not stretch other aspect ratios',
      );
      final clip = find.ancestor(of: image, matching: find.byType(ClipRRect));
      expect(
        tester.getSize(image),
        tester.getSize(clip),
        reason:
            'BoxFit.cover needs an image that fills the framed content area; '
            'the outer container border is not part of that area.',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync<void>(fixture.dispose);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'queue scrolling debounces thumbnail extraction for 100ms and requests with ThumbnailPriority.high',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      final thumbnailService = _FakeThumbnailService();
      final entries = List<MediaEntry>.generate(
        30,
        (i) => MediaEntry.fromPath(
          'https://media.example/video_$i.mp4',
          id: 'video-$i',
        ),
      );
      final fixture = await _PlayerFixture.create(
        thumbnails: thumbnailService,
        session: PlaybackSession(
          queue: entries,
          currentId: entries.first.id,
          volume: 100,
          saveNetworkUrls: true,
        ),
      );

      try {
        await tester.pumpWidget(_buildApp(fixture));
        await tester.pumpAndSettle();

        // Open queue panel
        await tester.tap(find.byTooltip('Queue (30)'));
        await tester.pumpAndSettle();

        // Verify initial visible items requested thumbnails with ThumbnailPriority.high
        expect(thumbnailService.requestedPriorities, isNotEmpty);
        expect(
          thumbnailService.requestedPriorities.every(
            (priority) => priority == ThumbnailPriority.high,
          ),
          isTrue,
        );

        thumbnailService.requestedPriorities.clear();

        final listFinder = find.byKey(
          const PageStorageKey<String>('queue-list'),
        );
        expect(listFinder, findsOneWidget);

        // Start scrolling via drag
        await tester.drag(listFinder, const Offset(0, -300));
        await tester.pump();

        // During scroll and before debounce period (50ms), no new extractions should complete
        await tester.pump(const Duration(milliseconds: 50));

        // After 100ms debounce timer elapses, pending extractions trigger with ThumbnailPriority.high
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        expect(thumbnailService.requestedPriorities, isNotEmpty);
        expect(
          thumbnailService.requestedPriorities.every(
            (priority) => priority == ThumbnailPriority.high,
          ),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync<void>(fixture.dispose);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}

Widget _buildApp(
  _PlayerFixture fixture, {
  Future<void> Function(bool)? fullscreenSetter,
  Future<String?> Function()? subtitlePicker,
}) => RepaintBoundary(
  key: const ValueKey('ui-preview'),
  child: MpvsonApp(
    controller: fixture.controller,
    updates: fixture.updates,
    engineUpdates: fixture.engineUpdates,
    desktopWindow: fullscreenSetter != null,
    fullscreenSetter: fullscreenSetter,
    subtitlePicker: subtitlePicker,
    enableNativeDrop: false,
    videoBuilder: (_, _) =>
        const ColoredBox(key: ValueKey('fake-video'), color: Colors.black),
  ),
);

Widget _buildAppWithMediaPicker(
  _PlayerFixture fixture,
  Future<List<String>> Function() mediaPicker,
) => RepaintBoundary(
  key: const ValueKey('ui-preview'),
  child: MaterialApp(
    title: 'Mpvson',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark,
    home: PlayerScreen(
      controller: fixture.controller,
      updates: fixture.updates,
      engineUpdates: fixture.engineUpdates,
      desktopWindow: false,
      videoBuilder: (_, _) =>
          const ColoredBox(key: ValueKey('fake-video'), color: Colors.black),
      mediaPicker: mediaPicker,
      enableNativeDrop: false,
    ),
  ),
);

Future<void> _capturePreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('MPVSON_CAPTURE_UI')) return;
  final previewContext = tester.element(
    find.byKey(const ValueKey('ui-preview')),
  );
  final providers = tester
      .widgetList<Image>(find.byType(Image))
      .map((image) => image.image)
      .toList(growable: false);
  await tester.runAsync(() async {
    for (final provider in providers) {
      await precacheImage(provider, previewContext);
    }
  });
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 140));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('ui-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('test-output/desktop-ux/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

double _controlOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(PlayerControls),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

Future<void> _selectSettingsSection(
  WidgetTester tester,
  Finder navigation,
  String label,
) async {
  final destination = find.descendant(
    of: navigation,
    matching: find.text(label),
  );
  await tester.ensureVisible(destination);
  await tester.tap(destination);
  await tester.pumpAndSettle();
}

Future<void> _wheel(WidgetTester tester, Offset position, Offset delta) async {
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      position: position,
      scrollDelta: delta,
      kind: ui.PointerDeviceKind.mouse,
    ),
  );
  await tester.pump();
}

Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final mouse = await tester.createGesture(
    kind: ui.PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await mouse.addPointer(location: position);
  await mouse.down(position);
  await mouse.up();
  await mouse.removePointer();
  await tester.pumpAndSettle();
}

class _PlayerFixture {
  _PlayerFixture({
    required this.playback,
    required this.controller,
    required this.sessions,
    required this.updates,
    required this.engineUpdates,
  });

  final _FakePlaybackService playback;
  final PlayerController controller;
  final _MemorySessionRepository sessions;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;

  static Future<_PlayerFixture> create({
    bool empty = false,
    ThumbnailService? thumbnails,
    PlaybackSession? session,
  }) async {
    const firstPath = 'https://media.example/first.mp4';
    const secondPath = 'https://media.example/second.mkv';
    final first = MediaEntry.fromPath(
      firstPath,
      id: 'queue-first',
      lastPlayed: DateTime(2026, 10, 14),
    );
    final second = MediaEntry.fromPath(
      secondPath,
      id: 'queue-second',
      lastPlayed: DateTime(2026, 10, 15),
    );
    final repository = _MemorySessionRepository()
      ..session =
          session ??
          PlaybackSession(
            queue: empty ? [] : [first, second],
            recent: [
              second.copyWith(
                position: const Duration(seconds: 42),
                duration: const Duration(minutes: 4),
              ),
            ],
            currentId: empty ? null : first.id,
            volume: 100,
            // The fixture queue holds stream URLs, so the stored session records
            // that the user consented to keeping them; without consent the launch
            // path intentionally scrubs every network entry.
            saveNetworkUrls: true,
          );
    final playback = _FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: repository,
      thumbnails: thumbnails,
    );
    await controller.initialize();
    return _PlayerFixture(
      playback: playback,
      controller: controller,
      sessions: repository,
      updates: UpdateService(),
      engineUpdates: EngineUpdateService(),
    );
  }

  Future<void> dispose() async {
    await controller.close();
    updates.dispose();
    engineUpdates.dispose();
  }
}

/// In-memory session store for widget tests.
///
/// Every persistence entry point the controller awaits is overridden: the real
/// repository resolves the OS support directory and touches it through
/// `dart:io`, and real file I/O never completes inside the fake-async zone a
/// widget test runs in.
class _MemorySessionRepository extends SessionRepository {
  PlaybackSession? session;
  SessionProgress? progress;

  @override
  Future<void> init() async {}

  @override
  Future<PlaybackSession?> load() async => session;

  @override
  Future<SessionLoadResult> loadDetailed() async =>
      SessionLoadResult(session: session);

  @override
  Future<void> save(PlaybackSession value) async => session = value;

  @override
  Future<void> saveScrubbed(PlaybackSession value) async => session = value;

  @override
  Future<SessionProgress?> loadProgress() async => progress;

  @override
  Future<void> saveProgress(SessionProgress value) async => progress = value;

  @override
  Future<void> scrubNetworkUrls() async {
    final current = session;
    if (current != null && current.hasNetworkEntries) {
      session = current.withoutNetworkUrls();
    }
    progress = const SessionProgress();
  }
}

class _FakeThumbnailService implements ThumbnailService {
  _FakeThumbnailService({this.unavailableIds = const <String>{}, this.bytes});

  final Uint8List? bytes;

  static Uint8List _pngBytes = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
    ),
  );

  final Set<String> unavailableIds;
  final Map<String, int> loadCountById = <String, int>{};
  final List<ThumbnailPriority> requestedPriorities = <ThumbnailPriority>[];

  @override
  Future<MediaThumbnail?> load(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) async {
    requestedPriorities.add(priority);
    loadCountById.update(entry.id, (count) => count + 1, ifAbsent: () => 1);
    if (unavailableIds.contains(entry.id)) {
      throw StateError('No thumbnail available for ${entry.id}');
    }
    return MediaThumbnail(
      bytes: Uint8List.fromList(bytes ?? _pngBytes),
      duration: const Duration(minutes: 3, seconds: 1),
    );
  }

  @override
  void suspend() {}

  @override
  void resume() {}

  @override
  Future<void> dispose() async {}
}

class _SequencedThumbnailExtractor implements ThumbnailExtractor {
  _SequencedThumbnailExtractor(this._artwork, {this.secondExtractionGate});

  final List<Uint8List> _artwork;
  final Future<void>? secondExtractionGate;
  int extractionCount = 0;

  @override
  Future<ThumbnailExtraction?> extract(
    String source, {
    required Directory outputDirectory,
    ThumbnailCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) return null;
    final index = extractionCount++;
    if (index == 1 && secondExtractionGate != null) {
      await secondExtractionGate;
    }
    return ThumbnailExtraction(
      bytes: _artwork[index < _artwork.length ? index : _artwork.length - 1],
      duration: const Duration(minutes: 4),
    );
  }

  @override
  Future<Duration> probeDuration(
    String source, {
    ThumbnailCancellation? cancellation,
  }) async => const Duration(minutes: 4);

  @override
  Future<void> dispose() async {}
}

Uint8List _queueImageBytes(WidgetTester tester, Finder imageFinder) {
  final provider = tester.widget<Image>(imageFinder).image;
  final memoryImage = provider is ResizeImage
      ? provider.imageProvider as MemoryImage
      : provider as MemoryImage;
  return memoryImage.bytes;
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final image = await recorder.endRecording().toImage(2, 2);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

class _FakePlaybackService implements PlaybackService {
  String? lastSubtitlePath;
  final StreamController<PlaybackSnapshot> _stream =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  PlaybackSnapshot _state = const PlaybackSnapshot(
    duration: Duration(minutes: 4),
  );
  int _sourceStart = 0;
  VideoOutputPolicy _videoOutputPolicy = const VideoOutputPolicy();

  @override
  VideoOutputPolicy get videoOutputPolicy => _videoOutputPolicy;

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _videoOutputPolicy = policy;
  }

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _stream.stream;

  @override
  String get engineVersion => 'libmpv test fake';

  @override
  Player get player =>
      throw StateError('The injected video builder skips libmpv.');

  @override
  VideoController get videoController =>
      throw StateError('The injected video builder skips libmpv.');

  void _emit(PlaybackSnapshot state) {
    _state = state;
    _stream.add(state);
  }

  void emitPosition(Duration position) =>
      _emit(_state.copyWith(position: position));

  void emitDuration(Duration duration) =>
      _emit(_state.copyWith(duration: duration));

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    _sourceStart++;
    _emit(
      _state.copyWith(
        sourceStart: _sourceStart,
        nativeSource: MediaEntry.canonicalSource(path),
        sourceLoaded: true,
        isPlaying: play,
        isBuffering: false,
      ),
    );
  }

  @override
  Future<void> stop() async {
    _sourceStart++;
    _emit(
      _state.copyWith(
        sourceStart: _sourceStart,
        isPlaying: false,
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
  }

  @override
  Future<void> play() async => _emit(_state.copyWith(isPlaying: true));

  @override
  Future<void> pause() async => _emit(_state.copyWith(isPlaying: false));

  @override
  Future<void> seek(Duration position) async =>
      _emit(_state.copyWith(position: position));

  @override
  Future<void> setVolume(double value) async =>
      _emit(_state.copyWith(volume: value));

  @override
  Future<void> setRate(double value) async =>
      _emit(_state.copyWith(rate: value));

  @override
  Future<void> setShuffle(bool value) async =>
      _emit(_state.copyWith(shuffle: value));

  @override
  Future<void> setRepeatMode(String value) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async =>
      _emit(_state.copyWith(currentAudioTrack: track));

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async =>
      _emit(_state.copyWith(currentSubtitleTrack: track));

  @override
  Future<void> loadSubtitle(String path) async => lastSubtitlePath = path;

  @override
  Future<void> dispose() async => _stream.close();
}
