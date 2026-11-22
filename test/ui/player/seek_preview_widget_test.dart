import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/controls/seek_preview.dart';

import '../../support/fake_playback_service.dart';

void main() {
  late Directory tempDir;
  late PlayerController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'mpvson_seek_preview_test_',
    );
    controller = PlayerController(
      playback: FakePlaybackService(),
      sessions: SessionRepository(
        directory: tempDir,
        encoder: (session) => jsonEncode(session.toJson()),
      ),
    );
  });

  tearDown(() async {
    await controller.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets(
    'local video preview never shows loading spinner and renders live Texture',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '01:23',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(minutes: 1, seconds: 23),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: false,
              liveTextureId: 12,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 12);
    },
  );

  testWidgets(
    'local video preview shows no spinner even before texture is ready',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '00:45',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(seconds: 45),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: false,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('00:45'), findsOneWidget);
    },
  );

  testWidgets(
    'remote video preview still shows loading indicator while loading',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SeekPreview(
            label: '02:10',
            width: SeekPreview.videoWidth,
            caretOffset: 120,
            previewTime: const Duration(minutes: 2, seconds: 10),
            currentPosition: Duration.zero,
            controller: controller,
            previewState: const SeekPreviewState(
              status: SeekPreviewStatus.loading,
              isUpdating: true,
              isRemote: true,
            ),
            thumbnail: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );
}
