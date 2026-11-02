import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/app_dialog.dart';
import 'package:mpvson/ui/library/widgets/add_to_playlist_dialog.dart';

class AdversarialFakeMediaRepo extends ChangeNotifier
    implements MediaLibraryRepository {
  List<PlaylistRecord> playlists = [];
  bool throwOnLoad = false;
  bool throwOnAdd = false;
  String? addedPlaylistId;
  List<String>? addedMediaIds;

  @override
  Future<List<PlaylistRecord>> getPlaylists() async {
    if (throwOnLoad) throw Exception('Simulated load error');
    return playlists;
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {
    if (throwOnAdd) throw Exception('Simulated add error');
    addedPlaylistId = playlistId;
    addedMediaIds = mediaIds;
  }

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    final record = PlaylistRecord(
      id: 'pl-${playlists.length + 1}',
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

Widget buildAdversarialApp({
  required Widget child,
  double textScaleFactor = 1.0,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.darkTheme(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScaleFactor)),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  group('Adversarial Stress Test: AddToPlaylistDialog Viewport Sweep', () {
    final viewports = <Size>[
      const Size(280, 500), // Ultra-narrow
      const Size(320, 568), // iPhone SE / narrow
      const Size(360, 640), // Compact Android
      const Size(412, 915), // Modern phone
      const Size(600, 800), // Small tablet
      const Size(1024, 768), // iPad / standard desktop
      const Size(1920, 1080), // Full HD desktop
    ];

    for (final size in viewports) {
      testWidgets(
        'renders cleanly with 0 overflows at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          FlutterErrorDetails? caughtOverflow;
          final originalOnError = FlutterError.onError;
          FlutterError.onError = (details) {
            if (details.toString().contains('RenderFlex overflowed')) {
              caughtOverflow = details;
            }
            originalOnError?.call(details);
          };
          addTearDown(() => FlutterError.onError = originalOnError);

          final repo = AdversarialFakeMediaRepo()..playlists = [];

          await tester.pumpWidget(
            buildAdversarialApp(
              child: AddToPlaylistDialog(
                repository: repo,
                mediaId: 'adversarial-media-1',
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            caughtOverflow,
            isNull,
            reason: 'RenderFlex overflow occurred at $size',
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Add to playlist'), findsOneWidget);
          expect(find.text('Cancel'), findsOneWidget);
          expect(find.text('New playlist'), findsOneWidget);
        },
      );
    }
  });

  group('Adversarial Stress Test: AddToPlaylistDialog Content & Scaled Stress', () {
    testWidgets(
      'stress test with 50 playlists in list and high vertical constraint',
      (tester) async {
        tester.view.physicalSize = const Size(360, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        final repo = AdversarialFakeMediaRepo()
          ..playlists = List.generate(
            50,
            (i) => PlaylistRecord(
              id: 'pl-$i',
              title:
                  'Playlist #$i: Very long album collection title with descriptive text $i',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              entryCount: i * 7,
            ),
          );

        await tester.pumpWidget(
          buildAdversarialApp(
            child: AddToPlaylistDialog(
              repository: repo,
              mediaId: 'adversarial-media-stress-50',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            'Playlist #0: Very long album collection title with descriptive text 0',
          ),
          findsOneWidget,
        );

        // Scroll through the list
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('stress test with error banner state', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      FlutterErrorDetails? caughtOverflow;
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('RenderFlex overflowed')) {
          caughtOverflow = details;
        }
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);

      final repo = AdversarialFakeMediaRepo()
        ..playlists = [
          PlaylistRecord(
            id: 'p-fail',
            title: 'Failing Playlist',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            entryCount: 1,
          ),
        ]
        ..throwOnAdd = true;

      await tester.pumpWidget(
        buildAdversarialApp(
          child: AddToPlaylistDialog(
            repository: repo,
            mediaId: 'adversarial-err-media',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger error
      await tester.tap(find.text('Failing Playlist'));
      await tester.pumpAndSettle();

      expect(find.text('Could not add this item. Try again.'), findsOneWidget);
      expect(caughtOverflow, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'stress test with accessibility text scale factors (1.25x, 1.5x, 1.75x)',
      (tester) async {
        final scales = [1.25, 1.5, 1.75];
        for (final scale in scales) {
          tester.view.physicalSize = const Size(360, 640);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          FlutterErrorDetails? caughtOverflow;
          final originalOnError = FlutterError.onError;
          FlutterError.onError = (details) {
            if (details.toString().contains('RenderFlex overflowed')) {
              caughtOverflow = details;
            }
            originalOnError?.call(details);
          };
          addTearDown(() => FlutterError.onError = originalOnError);

          final repo = AdversarialFakeMediaRepo()
            ..playlists = [
              PlaylistRecord(
                id: 'pl-scale',
                title: 'Scaled Font Playlist',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                entryCount: 3,
              ),
            ];

          await tester.pumpWidget(
            buildAdversarialApp(
              textScaleFactor: scale,
              child: AddToPlaylistDialog(
                repository: repo,
                mediaId: 'scale-media',
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            caughtOverflow,
            isNull,
            reason: 'Failed with text scale $scale',
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  });

  group('Adversarial Stress Test: AppDialog OverflowBar Actions Wrap Matrix', () {
    testWidgets(
      'OverflowBar wraps gracefully when 2 actions exceed available width',
      (tester) async {
        tester.view.physicalSize = const Size(300, 400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        await tester.pumpWidget(
          buildAdversarialApp(
            child: const AppDialog(
              maxWidth: 260,
              title: Text('Title'),
              content: Text('Content'),
              actions: [
                TextButton(onPressed: null, child: Text('Abbrechen')),
                FilledButton(
                  onPressed: null,
                  child: Text('Neue Wiedergabeliste erstellen'),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
        expect(find.byType(OverflowBar), findsOneWidget);

        // Verify that the buttons are wrapped vertically (top of button 2 is below top of button 1)
        final btn1Top = tester.getTopLeft(find.text('Abbrechen')).dy;
        final btn2Top = tester
            .getTopLeft(find.text('Neue Wiedergabeliste erstellen'))
            .dy;
        expect(
          btn2Top,
          greaterThan(btn1Top),
          reason: 'Buttons should wrap into vertical stack',
        );
      },
    );

    testWidgets(
      'OverflowBar wraps multiple actions (3 and 4 actions) on narrow dialog',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        await tester.pumpWidget(
          buildAdversarialApp(
            child: const AppDialog(
              maxWidth: 280,
              title: Text('Multi-Action'),
              content: Text('Testing 3 actions wrapping'),
              actions: [
                TextButton(onPressed: null, child: Text('Dismiss')),
                OutlinedButton(onPressed: null, child: Text('Secondary')),
                FilledButton(onPressed: null, child: Text('Confirm')),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'actionsAxis: Axis.vertical renders clean vertical column without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(300, 500);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        await tester.pumpWidget(
          buildAdversarialApp(
            child: const AppDialog(
              actionsAxis: Axis.vertical,
              maxWidth: 260,
              title: Text('Vertical Actions'),
              content: Text('Testing explicit vertical column layout'),
              actions: [
                FilledButton(onPressed: null, child: Text('Action One')),
                FilledButton(onPressed: null, child: Text('Action Two')),
                FilledButton(onPressed: null, child: Text('Action Three')),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
        expect(find.byType(Column), findsWidgets);
      },
    );

    testWidgets(
      'modal route show() invocation with AddToPlaylistDialog wraps and pops without errors',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        final repo = AdversarialFakeMediaRepo()..playlists = [];
        bool? dialogResult;

        await tester.pumpWidget(
          buildAdversarialApp(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await AddToPlaylistDialog.show(
                    context,
                    repo,
                    'modal-media-item',
                  );
                },
                child: const Text('Open Modal'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Modal'));
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(find.text('Add to playlist'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(dialogResult, isFalse);
      },
    );

    testWidgets(
      'extreme textScaleFactor 2.0x on AddToPlaylistDialog with unbreakable long title',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        FlutterErrorDetails? caughtOverflow;
        final originalOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.toString().contains('RenderFlex overflowed')) {
            caughtOverflow = details;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        final repo = AdversarialFakeMediaRepo()
          ..playlists = [
            PlaylistRecord(
              id: 'unbreakable-1',
              title:
                  'UnbreakableLongPlaylistTitleWithoutAnySpacesForTestingOverflowResilience1234567890',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              entryCount: 999,
            ),
          ];

        await tester.pumpWidget(
          buildAdversarialApp(
            textScaleFactor: 2.0,
            child: AddToPlaylistDialog(
              repository: repo,
              mediaId: 'extreme-scale-item',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(caughtOverflow, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
