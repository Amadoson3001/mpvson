import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/settings/settings_update_section.dart';
import 'package:mpvson/ui/player/views/update_center_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UpdateService updates;
  late EngineUpdateService engineUpdates;

  setUp(() {
    updates = UpdateService(currentVersion: '1.2.0');
    engineUpdates = EngineUpdateService(
      appVersion: '1.2.0',
      supportedMediaKitVersion: '1.2.6',
    );
  });

  Widget buildTestWidget(Widget child) => MaterialApp(
    theme: AppTheme.darkTheme(),
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets(
    'AboutSettingsSection renders brand header and status cards cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildTestWidget(
          AboutSettingsSection(
            updates: updates,
            engineUpdates: engineUpdates,
            engineVersion: 'v0.42.0-dev',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mpvson'), findsOneWidget);
      expect(find.text('v1.2.0'), findsOneWidget);
      expect(find.text('Update center'), findsOneWidget);
      expect(find.text('Application updates'), findsOneWidget);
      expect(find.text('Playback engine'), findsOneWidget);
      expect(find.text('libmpv v0.42.0-dev'), findsOneWidget);
      expect(find.text('Rendering pipeline'), findsOneWidget);
      expect(find.text('Open source & license'), findsOneWidget);
    },
  );

  testWidgets('AboutSettingsSection opens UpdateCenterDialog on tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      buildTestWidget(
        AboutSettingsSection(
          updates: updates,
          engineUpdates: engineUpdates,
          engineVersion: 'v0.42.0',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Update center'));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateCenterDialog), findsOneWidget);
    expect(find.text('Updates & about'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UpdateCenterDialog),
        matching: find.text('Playback engine'),
      ),
      findsOneWidget,
    );
    expect(find.text('Application'), findsOneWidget);
  });

  testWidgets(
    'Status tiles are informational and do not open UpdateCenterDialog',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildTestWidget(
          AboutSettingsSection(
            updates: updates,
            engineUpdates: engineUpdates,
            engineVersion: 'v0.42.0',
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final tile in [
        'Application updates',
        'Playback engine',
        'Engine channel & distribution',
      ]) {
        await tester.tap(find.text(tile), warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      expect(find.byType(UpdateCenterDialog), findsNothing);
    },
  );

  testWidgets(
    'UpdateCenterDialog renders without overflows at standard dialog size',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildTestWidget(
          UpdateCenterDialog(
            updates: updates,
            engineUpdates: engineUpdates,
            engineVersion: 'v0.42.0-dev-g3138fc8ee',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(UpdateCenterDialog), findsOneWidget);
      expect(find.text('Updates & about'), findsOneWidget);
      expect(find.text('Update channel'), findsOneWidget);
      expect(find.text('Check engine updates'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    },
  );

  testWidgets(
    'Release highlights parses clean bullets and avoids wall of text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      const longAssNotes = '''
# mpv v0.39.0 Release Notes
============================
Automated Windows build artifacts generated from commit abc1234.
SHA-256 checksums available in assets.

### Features
* Added support for new Vulkan presentation modes
* Improved hardware decoding pipeline on Windows D3D11
* Demuxer: fix buffer overflow when parsing malformed mkv tags
* Audio: rework spatial audio mapping for 7.1 channels
* Fixed issue where subtitle styles were not reloading dynamically

Full changelog: https://github.com/mpv-player/mpv/releases/tag/v0.39.0
Build commit: 849a37bc89d201e74a
''';

      await tester.pumpWidget(
        buildTestWidget(
          const Column(children: [_TestNotesHost(notes: longAssNotes)]),
        ),
      );
      await tester.pumpAndSettle();

      // Verify highlights are displayed concisely
      expect(find.text('Highlights'), findsOneWidget);
      expect(find.text('View full notes'), findsOneWidget);

      // Only clean highlight lines are rendered, not the header or URLs
      expect(
        find.textContaining('Added support for new Vulkan presentation modes'),
        findsOneWidget,
      );
      expect(find.textContaining('# mpv v0.39.0 Release Notes'), findsNothing);
      expect(find.textContaining('Full changelog: https://'), findsNothing);

      // Tap to expand
      await tester.tap(find.text('View full notes'));
      await tester.pumpAndSettle();

      expect(find.text('Show less'), findsOneWidget);
      expect(
        find.textContaining('Automated Windows build artifacts'),
        findsOneWidget,
      );

      // Tap to collapse
      await tester.tap(find.text('Show less'));
      await tester.pumpAndSettle();

      expect(find.text('View full notes'), findsOneWidget);
    },
  );

  testWidgets('Release notes containing only a link do not crash the preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // Every line of these notes is filtered out (links / rules), so the
    // internal `lines` list is empty. This used to crash on `lines.first`.
    const linkOnlyNotes = '''
https://github.com/mpvson/mpvson/releases/tag/v1.3.0
---

''';

    await tester.pumpWidget(
      buildTestWidget(
        const Column(children: [_TestNotesHost(notes: linkOnlyNotes)]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Highlights'), findsOneWidget);
    // The raw notes are surfaced as the fallback highlight line.
    expect(
      find.textContaining('https://github.com/mpvson/mpvson/releases'),
      findsOneWidget,
    );
  });

  testWidgets(
    'P0-5: Release notes containing markdown link-only notes render cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      const markdownLinkNotes = '''
[Full Changelog](https://github.com/mpvson/mpvson/compare/v1.2.0...v1.3.0)
---
''';

      await tester.pumpWidget(
        buildTestWidget(
          const Column(children: [_TestNotesHost(notes: markdownLinkNotes)]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Highlights'), findsOneWidget);
      // Strips markdown link syntax to display the link text as highlight.
      expect(find.textContaining('Full Changelog'), findsOneWidget);
    },
  );
}

class _TestNotesHost extends StatelessWidget {
  const _TestNotesHost({required this.notes});
  final String notes;

  @override
  Widget build(BuildContext context) {
    return ReleaseNotesPreview(notes: notes);
  }
}
