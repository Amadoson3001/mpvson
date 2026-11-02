import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wrap the app in this so [capture] can find a repaint boundary.
final GlobalKey screenshotKey = GlobalKey(debugLabel: 'screenshot');

bool _fontsLoaded = false;

/// Loads the real UI font and icon font; flutter_test substitutes boxes
/// otherwise, which makes screenshots useless for judging typography.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  Future<void> load(String family, String asset) async {
    final loader = FontLoader(family)..addFont(rootBundle.load(asset));
    await loader.load();
  }

  await load('Onest', 'assets/fonts/Onest-Variable.ttf');
  final icons = File(_materialIconsPath());
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  _fontsLoaded = true;
}

String _materialIconsPath() {
  final root = Platform.environment['FLUTTER_ROOT'] ?? _guessFlutterRoot();
  return '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

String _guessFlutterRoot() {
  final exe = Platform.resolvedExecutable.replaceAll('\\', '/');
  final idx = exe.indexOf('/bin/cache/');
  return idx > 0 ? exe.substring(0, idx) : '';
}

const String _shotDir = String.fromEnvironment('SHOT_DIR');

/// Writes a PNG of the current frame to `build/shots/[SHOT_DIR/]<name>.png`.
/// Pass `--dart-define=SHOT_DIR=mine` so parallel runs do not collide.
Future<void> capture(WidgetTester tester, String name) async {
  final boundary =
      screenshotKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = _shotDir.isEmpty ? 'build/shots' : 'build/shots/$_shotDir';
    final file = File('$dir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
}
