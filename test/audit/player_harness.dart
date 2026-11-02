import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/ui/player/views/player_stage.dart';

import '../support/app_harness.dart';
import '../support/audit_helpers.dart';
import '../support/screenshot.dart';

/// Stand-ins for the native video surface. The stock harness paints a flat
/// blue-gray box, which hides legibility problems of chrome over real footage.
enum FakeVideo { flat, bright, dark }

Widget fakeVideoSurface(FakeVideo kind) => switch (kind) {
  FakeVideo.flat => const ColoredBox(color: Color(0xFF223344)),
  FakeVideo.bright => const _FakeFootage(
    top: Color(0xFFF4F7FA),
    bottom: Color(0xFFE8DFC8),
    shape: Color(0xFFFFFFFF),
  ),
  FakeVideo.dark => const _FakeFootage(
    top: Color(0xFF05070A),
    bottom: Color(0xFF111418),
    shape: Color(0xFF1A2230),
  ),
};

class _FakeFootage extends StatelessWidget {
  const _FakeFootage({
    required this.top,
    required this.bottom,
    required this.shape,
  });

  final Color top;
  final Color bottom;
  final Color shape;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _FootagePainter(top: top, bottom: bottom, shape: shape),
    child: const SizedBox.expand(),
  );
}

class _FootagePainter extends CustomPainter {
  const _FootagePainter({
    required this.top,
    required this.bottom,
    required this.shape,
  });

  final Color top;
  final Color bottom;
  final Color shape;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          top,
          bottom,
        ]),
    );
    final paint = Paint()..color = shape;
    canvas.drawCircle(
      Offset(size.width * 0.72, size.height * 0.3),
      size.shortestSide * 0.16,
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.1,
        size.height * 0.55,
        size.width * 0.5,
        size.height * 0.45,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_FootagePainter oldDelegate) => false;
}

/// App with the desktop window flag on, so the full chrome (fullscreen button
/// and so on) is built, and a selectable fake video surface.
Widget playerApp(
  Harness h, {
  FakeVideo video = FakeVideo.flat,
  PlayerVideoBuilder? videoBuilder,
}) => RepaintBoundary(
  key: screenshotKey,
  child: MpvsonApp(
    controller: h.controller,
    updates: h.updates,
    engineUpdates: h.engineUpdates,
    appPreferences: h.prefs,
    libraryRepository: h.library,
    enableNativeDrop: false,
    desktopWindow: true,
    fullscreenSetter: (_) async {},
    videoBuilder: videoBuilder ?? (context, _) => fakeVideoSurface(video),
  ),
);

/// Boots the app at [size] and opens [names]; the first one becomes current.
Future<Harness> bootPlayer(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  bool dark = true,
  FakeVideo video = FakeVideo.flat,
  List<String> names = const ['A movie with a title.mkv', 'b.mp3', 'c.mp4'],
  bool openChrome = true,
}) async {
  final h = buildHarness(dark: dark);
  configureView(tester, size: size, textScale: textScale);
  await tester.pumpWidget(playerApp(h, video: video));
  await settle(tester);
  await openMedia(tester, h, names);
  if (openChrome) await hover(tester, size.center(Offset.zero));
  return h;
}

/// The pref object used by tests that need a non-default preference.
DesktopPreferences prefsFor({required bool dark}) =>
    DesktopPreferences(themeMode: dark ? ThemeMode.dark : ThemeMode.light);
