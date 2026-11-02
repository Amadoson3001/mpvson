import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/app_dialog.dart';
import 'package:mpvson/ui/library/widgets/add_to_playlist_dialog.dart';

class AdversarialFakeMediaLibraryRepository extends ChangeNotifier
    implements MediaLibraryRepository {
  List<PlaylistRecord> playlists = [];
  String? addedPlaylistId;
  List<String>? addedMediaIds;

  @override
  Future<List<PlaylistRecord>> getPlaylists() async => playlists;

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {
    addedPlaylistId = playlistId;
    addedMediaIds = mediaIds;
  }

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    final record = PlaylistRecord(
      id: 'pl-created-${playlists.length + 1}',
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

Widget buildHarness({required Widget child, double textScaleFactor = 1.0}) {
  return MaterialApp(
    theme: AppTheme.darkTheme(),
    home: Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(textScaleFactor)),
          child: Scaffold(body: Center(child: child)),
        );
      },
    ),
  );
}

void main() {
  group('Adversarial Challenger: AddToPlaylistDialog Viewport Matrix', () {
    final viewports = [
      const Size(280, 480), // Narrowest mobile
      const Size(320, 480), // Classic mobile
      const Size(320, 568), // iPhone SE
      const Size(360, 640), // Standard Android
      const Size(412, 915), // Pixel 7
      const Size(600, 800), // AppLayout.compactBreakpoint
      const Size(1024, 768), // Tablet / Desktop compact
      const Size(1280, 720), // 720p HD Desktop
      const Size(1920, 1080), // 1080p FHD Desktop
      const Size(3840, 2160), // 4K UHD Desktop
    ];

    for (final size in viewports) {
      testWidgets(
        'Empty state at viewport ${size.width.toInt()}x${size.height.toInt()} - 0 overflow',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final repo = AdversarialFakeMediaLibraryRepository()..playlists = [];

          await tester.pumpWidget(
            buildHarness(
              child: AddToPlaylistDialog(
                repository: repo,
                mediaId: 'adversarial-media-1',
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.text('Add to playlist'), findsOneWidget);
          expect(find.text('Cancel'), findsOneWidget);
          expect(find.text('New playlist'), findsOneWidget);
        },
      );

      testWidgets(
        'Populated with long titles at ${size.width.toInt()}x${size.height.toInt()} - 0 overflow',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final repo = AdversarialFakeMediaLibraryRepository()
            ..playlists = List.generate(
              15,
              (i) => PlaylistRecord(
                id: 'pl-$i',
                title:
                    'Super Long Adversarial Playlist Title Number $i With Extra Long Trailing Characters',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                entryCount: i * 7,
              ),
            );

          await tester.pumpWidget(
            buildHarness(
              child: AddToPlaylistDialog(
                repository: repo,
                mediaId: 'adversarial-media-2',
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group(
    'Adversarial Challenger: WCAG AA Accessibility Font Scale Stress (Up to 2.0x)',
    () {
      final fontScales = [1.25, 1.5, 1.75, 2.0];

      for (final scale in fontScales) {
        testWidgets(
          'AddToPlaylistDialog under text scale factor ${scale}x - 0 overflow',
          (tester) async {
            tester.view.physicalSize = const Size(360, 640);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });

            final repo = AdversarialFakeMediaLibraryRepository()
              ..playlists = [];

            await tester.pumpWidget(
              buildHarness(
                textScaleFactor: scale,
                child: AddToPlaylistDialog(
                  repository: repo,
                  mediaId: 'scale-test',
                ),
              ),
            );
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.byType(OverflowBar), findsOneWidget);
          },
        );
      }
    },
  );

  group('Adversarial Challenger: AppDialog OverflowBar Actions Wrap Mechanics', () {
    testWidgets(
      'OverflowBar wraps horizontal actions to vertical stack when constrained to 180px',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        bool button1Pressed = false;
        bool button2Pressed = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AppDialog(
                  maxWidth: 180,
                  title: const Text('Narrow Dialog'),
                  content: const Text('Constrained content body'),
                  actions: [
                    TextButton(
                      onPressed: () => button1Pressed = true,
                      child: const Text('First Long Action'),
                    ),
                    FilledButton(
                      onPressed: () => button2Pressed = true,
                      child: const Text('Second Long Action'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Verify both actions are rendered and laid out vertically
        final btn1Center = tester.getCenter(find.text('First Long Action'));
        final btn2Center = tester.getCenter(find.text('Second Long Action'));

        // If wrapped, the vertical position of button 2 will be below button 1
        expect(
          btn2Center.dy,
          greaterThan(btn1Center.dy),
          reason:
              'Actions should wrap vertically in OverflowBar when width is constrained',
        );

        // Verify interactability
        await tester.tap(find.text('First Long Action'));
        await tester.pumpAndSettle();
        expect(button1Pressed, isTrue);

        await tester.tap(find.text('Second Long Action'));
        await tester.pumpAndSettle();
        expect(button2Pressed, isTrue);
      },
    );

    testWidgets(
      'AppDialog with 4 wide actions stacks without overflow under 240px width',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AppDialog(
                  maxWidth: 240,
                  title: const Text('Four Actions Test'),
                  actions: const [
                    TextButton(onPressed: null, child: Text('Action 1')),
                    TextButton(onPressed: null, child: Text('Action 2')),
                    FilledButton(onPressed: null, child: Text('Action 3')),
                    FilledButton(onPressed: null, child: Text('Action 4')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Action 1'), findsOneWidget);
        expect(find.text('Action 2'), findsOneWidget);
        expect(find.text('Action 3'), findsOneWidget);
        expect(find.text('Action 4'), findsOneWidget);
      },
    );

    testWidgets(
      'AppDialog actionsAxis: Axis.vertical renders explicitly via Column',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AppDialog(
                  actionsAxis: Axis.vertical,
                  title: const Text('Vertical Actions Test'),
                  actions: const [
                    FilledButton(onPressed: null, child: Text('Stack Top')),
                    FilledButton(onPressed: null, child: Text('Stack Bottom')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(OverflowBar), findsNothing);
        expect(find.text('Stack Top'), findsOneWidget);
        expect(find.text('Stack Bottom'), findsOneWidget);
      },
    );
  });
}
