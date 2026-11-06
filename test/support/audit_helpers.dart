import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';

import 'app_harness.dart';

/// Window sizes every screen must survive. 720x480 is the app's minimum.
const auditSizes = <String, Size>{
  'min720x480': Size(720, 480),
  'narrow900x600': Size(900, 600),
  'mid1000x640': Size(1000, 640),
  'default1240x780': Size(1240, 780),
  'uhd1920x1080': Size(1920, 1080),
};

/// Library sections reachable from the navigation.
const navSections = [
  'Home',
  'Videos',
  'Music',
  'Playlists',
  'Folders',
  'Settings',
];

/// Builds a harness with a library that includes awkward data: very long
/// titles, CJK text, missing metadata, unavailable files, an unavailable
/// folder, and playlists with long and empty names.
Harness buildHarness({
  bool dark = true,
  bool populated = true,
}) => Harness.create(
  items: populated ? stressItems() : null,
  playlists: populated
      ? [
          PlaylistRecord(
            id: 'p1',
            title: 'Road trip playlist with a title long enough to wrap',
            createdAt: DateTime(2025),
            updatedAt: DateTime(2025),
            entryCount: 3,
          ),
          PlaylistRecord(
            id: 'p2',
            title: 'Empty',
            createdAt: DateTime(2025),
            updatedAt: DateTime(2025),
          ),
        ]
      : null,
  folders: populated
      ? [
          LibraryFolderRecord(
            path:
                'C:\\Users\\someone\\Music\\A very deeply nested\\folder\\path\\that is long',
            addedAt: DateTime(2025),
            fileCount: 1200,
          ),
          LibraryFolderRecord(
            path: 'D:\\Gone',
            addedAt: DateTime(2025),
            isAvailable: false,
          ),
        ]
      : null,
  prefs: DesktopPreferences(themeMode: dark ? ThemeMode.dark : ThemeMode.light),
);

/// Taps a label, opening the nav drawer first when the shell is compact.
Future<void> tapNav(WidgetTester tester, String label) async {
  var text = find.text(label);
  if (text.evaluate().isEmpty) {
    final menu = find.byTooltip('Open navigation');
    if (menu.evaluate().isNotEmpty) {
      await tester.tap(menu.first, warnIfMissed: false);
      await settle(tester);
      text = find.text(label);
    }
  }
  if (text.evaluate().isNotEmpty) {
    await tester.tap(text.first, warnIfMissed: false);
  } else {
    final tip = find.byTooltip(label);
    if (tip.evaluate().isEmpty) return;
    await tester.tap(tip.first, warnIfMissed: false);
  }
  await settle(tester);
}

/// Taps the first widget with [label] text if present. Returns whether it hit.
Future<bool> tapText(WidgetTester tester, String label) async {
  final f = find.text(label);
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await settle(tester);
  return true;
}

/// Creates real files, opens them in the controller and waits for the queue.
/// The first path becomes the current item. Extension picks audio or video.
Future<List<String>> openMedia(
  WidgetTester tester,
  Harness h,
  List<String> names,
) async {
  final files = await makeMediaFiles(tester, names);
  await tester.runAsync(() async {
    await h.controller.openPaths(files);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await settle(tester);
  return files;
}

/// Moves a mouse pointer to [at] so hover-only chrome appears.
/// Returns the gesture; remove its pointer before adding another mouse
/// device (the mouse tracker only tolerates one live mouse pointer).
Future<TestGesture> hover(WidgetTester tester, Offset at) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  await g.moveTo(at);
  await settle(tester);
  return g;
}

/// Runs [body] and returns layout errors plus font-family violations seen
/// afterwards, each prefixed with [where].
Future<List<String>> auditStep(
  WidgetTester tester,
  String where,
  Future<void> Function() body,
) async {
  final errors = await collectErrors(body);
  final out = <String>[for (final e in errors) '$where :: $e'];
  for (final f in fontIssues(tester)) {
    out.add('$where :: font $f');
  }
  return out;
}
