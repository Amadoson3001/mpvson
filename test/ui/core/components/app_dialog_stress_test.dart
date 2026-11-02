import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/app_dialog.dart';
import 'package:mpvson/ui/library/widgets/add_to_playlist_dialog.dart';
import 'package:mpvson/ui/library/widgets/playlist_create_dialog.dart';
import 'package:mpvson/ui/player/views/open_preference_dialog.dart';
import 'package:mpvson/ui/player/widgets/open_url_dialog.dart';

// --- Fakes for Empirical Verification ---

class FakeMediaLibraryRepository extends ChangeNotifier
    implements MediaLibraryRepository {
  List<PlaylistRecord> playlists = [];
  String? addedPlaylistId;
  List<String>? addedMediaIds;
  String? createdTitle;

  @override
  Future<List<PlaylistRecord>> getPlaylists() async => playlists;

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {
    addedPlaylistId = playlistId;
    addedMediaIds = mediaIds;
  }

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    createdTitle = title;
    final record = PlaylistRecord(
      id: 'pl-created-1',
      title: title,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      entryCount: 0,
    );
    playlists.add(record);
    return record;
  }

  @override
  Future<void> dispose() async {
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget buildTestApp({
  required Widget child,
  ThemeData? theme,
  ThemeMode themeMode = ThemeMode.dark,
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.darkTheme(),
    themeMode: themeMode,
    home: Scaffold(body: child),
  );
}

void main() {
  group('AppDialog Viewport & Layout Stress Tests', () {
    testWidgets(
      'Narrow viewport (320x480) - constraints & overflow resistance',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: const AppDialog(
              title: Text('Narrow Title'),
              content: Text('Content fitting narrow screen bounds cleanly.'),
              actions: [Text('Action')],
            ),
          ),
        );

        expect(find.text('Narrow Title'), findsOneWidget);
        expect(
          find.text('Content fitting narrow screen bounds cleanly.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Narrow viewport (320x480) - scrollable content under extreme height',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: AppDialog(
              scrollable: true,
              title: const Text('Long List'),
              content: Column(
                children: List.generate(
                  50,
                  (i) => SizedBox(height: 30, child: Text('Item $i')),
                ),
              ),
              actions: const [Text('Done')],
            ),
          ),
        );

        expect(find.text('Item 0'), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Drag scroll down
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Narrow viewport (320x480) - actionsAxis: vertical prevents row overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: const AppDialog(
              actionsAxis: Axis.vertical,
              title: Text('Vertical Stack'),
              content: Text('Testing vertical button stacking'),
              actions: [
                ElevatedButton(
                  onPressed: null,
                  child: Text('Very Long Action Button One'),
                ),
                ElevatedButton(
                  onPressed: null,
                  child: Text('Very Long Action Button Two'),
                ),
              ],
            ),
          ),
        );

        expect(find.text('Very Long Action Button One'), findsOneWidget);
        expect(find.text('Very Long Action Button Two'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Narrow viewport (320x480) - responsive actions wrap without RenderFlex overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: const AppDialog(
              maxWidth: 240,
              title: Text('Narrow Horizontal'),
              content: Text('Testing horizontal button wrapping'),
              actions: [
                TextButton(onPressed: null, child: Text('Cancel Action')),
                FilledButton(
                  onPressed: null,
                  child: Text('Confirm Action With Long Title'),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Cancel Action'), findsOneWidget);
        expect(find.text('Confirm Action With Long Title'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Standard viewport (1280x720) - max width & height constraints enforced',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: const AppDialog(
              maxWidth: 440,
              title: Text('Standard Viewport'),
              content: Text('Testing width clamp'),
            ),
          ),
        );

        final constrainedBoxFinder = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(ConstrainedBox),
        );
        final box = tester
            .widgetList<ConstrainedBox>(constrainedBoxFinder)
            .last;
        expect(box.constraints.maxWidth, 440.0);
        // maxHeight defaults to screenHeight - 80 = 720 - 80 = 640
        expect(box.constraints.maxHeight, 640.0);
      },
    );

    testWidgets(
      'Wide viewport (2560x1440) - centered layout and explicit custom constraints',
      (tester) async {
        tester.view.physicalSize = const Size(2560, 1440);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          buildTestApp(
            child: const AppDialog(
              constraints: BoxConstraints(maxWidth: 800, maxHeight: 600),
              title: Text('Wide Viewport'),
              content: Text('Testing constraints override'),
            ),
          ),
        );

        final constrainedBoxFinder = find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(ConstrainedBox),
        );
        final box = tester
            .widgetList<ConstrainedBox>(constrainedBoxFinder)
            .last;
        expect(box.constraints.maxWidth, 800.0);
        expect(box.constraints.maxHeight, 600.0);
      },
    );
  });

  group('Dialog 1: OpenPreferenceDialog Empirical Verification', () {
    testWidgets('dismisses with null on barrier tap', (tester) async {
      OpenBehaviorPreference? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await OpenPreferenceDialog.show(context);
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();
      expect(
        find.text('What should happen when you open new files?'),
        findsOneWidget,
      );

      // Tap modal barrier (top-left outside the dialog)
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(
        find.text('What should happen when you open new files?'),
        findsNothing,
      );
      expect(result, isNull);
    });

    testWidgets('returns keepPlayingAndEnqueue on primary button tap', (
      tester,
    ) async {
      OpenBehaviorPreference? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await OpenPreferenceDialog.show(context);
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep playing and add to queue'));
      await tester.pumpAndSettle();

      expect(result, OpenBehaviorPreference.keepPlayingAndEnqueue);
    });

    testWidgets('returns playNewFilesNow on secondary button tap', (
      tester,
    ) async {
      OpenBehaviorPreference? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await OpenPreferenceDialog.show(context);
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play new files now'));
      await tester.pumpAndSettle();

      expect(result, OpenBehaviorPreference.playNewFilesNow);
    });

    testWidgets(
      'verifies semantic color contrast (accentForeground) in dark and light themes',
      (tester) async {
        // 1. Dark theme check
        await tester.pumpWidget(
          buildTestApp(
            theme: AppTheme.darkTheme(),
            child: const OpenPreferenceDialog(),
          ),
        );

        final darkFilledBtn = tester.widget<FilledButton>(
          find.byType(FilledButton),
        );
        final darkFgColor = darkFilledBtn.style?.foregroundColor?.resolve({});
        final darkBgColor = darkFilledBtn.style?.backgroundColor?.resolve({});
        expect(darkFgColor, AppColors.ground);
        expect(darkBgColor, AppColors.lamp);

        // 2. Light theme check
        await tester.pumpWidget(
          buildTestApp(
            theme: AppTheme.lightTheme(),
            themeMode: ThemeMode.light,
            child: const OpenPreferenceDialog(key: Key('light-pref-dialog')),
          ),
        );
        await tester.pumpAndSettle();

        final lightFilledBtn = tester.widget<FilledButton>(
          find.byType(FilledButton),
        );
        final lightFgColor = lightFilledBtn.style?.foregroundColor?.resolve({});
        final lightBgColor = lightFilledBtn.style?.backgroundColor?.resolve({});
        expect(lightFgColor, Colors.white);
        expect(lightBgColor, AppColors.lampLight);
        // Ensure it is definitely not deepBackground (which is 0xFFF8FAFC in light theme)
        expect(lightFgColor != AppColors.lightGround, isTrue);
      },
    );
  });

  group('Dialog 2: OpenUrlDialog Empirical Verification', () {
    testWidgets('barrier dismisses and returns null', (tester) async {
      String? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await AppDialog.show<String>(
                  context: context,
                  builder: (_) => const OpenUrlDialog(),
                );
              },
              child: const Text('Open URL Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open URL Dialog'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('cancel button pops and returns null', (tester) async {
      String? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await AppDialog.show<String>(
                  context: context,
                  builder: (_) => const OpenUrlDialog(),
                );
              },
              child: const Text('Open URL Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open URL Dialog'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('validates URL, shows error, and submits valid URL', (
      tester,
    ) async {
      String? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await AppDialog.show<String>(
                  context: context,
                  builder: (_) => const OpenUrlDialog(),
                );
              },
              child: const Text('Open URL Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open URL Dialog'));
      await tester.pumpAndSettle();

      // Enter invalid URL
      await tester.enterText(
        find.byKey(const ValueKey('open-url-input')),
        'not-a-valid-url',
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Error shown, dialog remains open
      expect(find.text('Enter a valid http or https address.'), findsOneWidget);
      expect(result, isNull);

      // Enter valid URL
      await tester.enterText(
        find.byKey(const ValueKey('open-url-input')),
        'https://mpvson.org/video.mp4',
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(result, 'https://mpvson.org/video.mp4');
    });

    testWidgets(
      'verifies input text field border radii exactly equal AppRadii.artwork',
      (tester) async {
        await tester.pumpWidget(buildTestApp(child: const OpenUrlDialog()));

        final textField = tester.widget<TextField>(
          find.byKey(const ValueKey('open-url-input')),
        );
        final decoration = textField.decoration!;

        final border = decoration.border as OutlineInputBorder;
        expect(border.borderRadius, BorderRadius.circular(AppRadii.artwork));
        expect(border.borderRadius.topLeft.x, AppRadii.artwork);

        final enabledBorder = decoration.enabledBorder as OutlineInputBorder;
        expect(
          enabledBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(enabledBorder.borderRadius.topLeft.x, AppRadii.artwork);

        final focusedBorder = decoration.focusedBorder as OutlineInputBorder;
        expect(
          focusedBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(focusedBorder.borderRadius.topLeft.x, AppRadii.artwork);
      },
    );
  });

  group('Dialog 3: AddToPlaylistDialog Empirical Verification', () {
    testWidgets('shows empty state without RenderFlex overflow', (
      tester,
    ) async {
      final repo = FakeMediaLibraryRepository()..playlists = [];
      FlutterErrorDetails? overflowError;
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('RenderFlex overflowed')) {
          overflowError = details;
        } else {
          prevOnError?.call(details);
        }
      };
      addTearDown(() => FlutterError.onError = prevOnError);

      await tester.pumpWidget(
        buildTestApp(
          child: AddToPlaylistDialog(repository: repo, mediaId: 'media-123'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Create a playlist to add this item.'), findsOneWidget);
      // Confirmed resolved: maxWidth: 420 and responsive actions prevent any RenderFlex overflow
      expect(overflowError, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selects playlist and returns true after adding item', (
      tester,
    ) async {
      final repo = FakeMediaLibraryRepository()
        ..playlists = [
          PlaylistRecord(
            id: 'playlist-alpha',
            title: 'Synthwave Night',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            entryCount: 4,
          ),
        ];

      bool? result;
      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await AddToPlaylistDialog.show(
                  context,
                  repo,
                  'media-123',
                );
              },
              child: const Text('Add Item'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Add Item'));
      await tester.pumpAndSettle();

      expect(find.text('Synthwave Night'), findsOneWidget);
      expect(find.text('4 items'), findsOneWidget);

      await tester.tap(find.text('Synthwave Night'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(repo.addedPlaylistId, 'playlist-alpha');
      expect(repo.addedMediaIds, ['media-123']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancel button pops dialog with false', (tester) async {
      final repo = FakeMediaLibraryRepository();
      bool? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await AddToPlaylistDialog.show(
                  context,
                  repo,
                  'media-123',
                );
              },
              child: const Text('Add Item'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Add Item'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });
  });

  group('Dialog 4: PlaylistCreateDialog Empirical Verification', () {
    testWidgets('barrier dismisses and returns null', (tester) async {
      final repo = FakeMediaLibraryRepository();
      PlaylistRecord? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await PlaylistCreateDialog.show(context, repo);
              },
              child: const Text('New Playlist'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Playlist'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('cancel button pops and returns null', (tester) async {
      final repo = FakeMediaLibraryRepository();
      PlaylistRecord? result;

      await tester.pumpWidget(
        buildTestApp(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await PlaylistCreateDialog.show(context, repo);
              },
              child: const Text('New Playlist'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Playlist'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets(
      'validates empty title, then submits and returns created playlist',
      (tester) async {
        final repo = FakeMediaLibraryRepository();
        PlaylistRecord? result;

        await tester.pumpWidget(
          buildTestApp(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await PlaylistCreateDialog.show(context, repo);
                },
                child: const Text('New Playlist'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('New Playlist'));
        await tester.pumpAndSettle();

        // Submit empty
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a playlist title'), findsOneWidget);
        expect(result, isNull);

        // Submit valid title
        await tester.enterText(find.byType(TextField), 'Cyberpunk Beats');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(result, isNotNull);
        expect(result!.title, 'Cyberpunk Beats');
        expect(repo.createdTitle, 'Cyberpunk Beats');
      },
    );

    testWidgets(
      'verifies input text field border radii exactly equal AppRadii.artwork',
      (tester) async {
        final repo = FakeMediaLibraryRepository();
        await tester.pumpWidget(
          buildTestApp(child: PlaylistCreateDialog(repository: repo)),
        );

        final textField = tester.widget<TextField>(find.byType(TextField));
        final decoration = textField.decoration!;

        final enabledBorder = decoration.enabledBorder as OutlineInputBorder;
        expect(
          enabledBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(enabledBorder.borderRadius.topLeft.x, AppRadii.artwork);

        final focusedBorder = decoration.focusedBorder as OutlineInputBorder;
        expect(
          focusedBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(focusedBorder.borderRadius.topLeft.x, AppRadii.artwork);

        final errorBorder = decoration.errorBorder as OutlineInputBorder;
        expect(
          errorBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(errorBorder.borderRadius.topLeft.x, AppRadii.artwork);

        final focusedErrorBorder =
            decoration.focusedErrorBorder as OutlineInputBorder;
        expect(
          focusedErrorBorder.borderRadius,
          BorderRadius.circular(AppRadii.artwork),
        );
        expect(focusedErrorBorder.borderRadius.topLeft.x, AppRadii.artwork);
      },
    );
  });

  group(
    'Dialog 5: SettingsDialog Shell & AppDialog Specification Verification',
    () {
      testWidgets(
        'AppDialog correctly enforces settings dialog constraints (840x720, lg inset)',
        (tester) async {
          tester.view.physicalSize = const Size(1920, 1080);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          await tester.pumpWidget(
            buildTestApp(
              child: const AppDialog(
                maxWidth: 840,
                maxHeight: 720,
                insetPadding: EdgeInsets.all(AppSpace.lg),
                child: SizedBox(
                  width: 840,
                  height: 720,
                  child: Text('Settings Body Mock'),
                ),
              ),
            ),
          );

          final dialogFinder = find.byType(Dialog);
          expect(dialogFinder, findsOneWidget);

          final dialog = tester.widget<Dialog>(dialogFinder);
          expect(dialog.insetPadding, const EdgeInsets.all(AppSpace.lg));

          final constrainedBoxFinder = find.descendant(
            of: dialogFinder,
            matching: find.byType(ConstrainedBox),
          );
          final box = tester
              .widgetList<ConstrainedBox>(constrainedBoxFinder)
              .last;
          expect(box.constraints.maxWidth, 840.0);
          expect(box.constraints.maxHeight, 720.0);
          expect(find.text('Settings Body Mock'), findsOneWidget);
        },
      );
    },
  );
}
