import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/library_navigation.dart';
import 'package:mpvson/ui/library/views/library_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShellSideNav sliding indicator', () {
    testWidgets(
      'renders sliding indicator and animates smoothly between sections',
      (tester) async {
        LibrarySection selectedSection = LibrarySection.home;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return SizedBox(
                    width: 208,
                    height: 700,
                    child: ShellSideNav(
                      section: selectedSection,
                      onSelect: (next) =>
                          setState(() => selectedSection = next),
                      collapsed: false,
                      showSettings: true,
                    ),
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Find the sliding indicator by Type
        final indicatorFinder = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_SlidingNavIndicator',
        );
        expect(indicatorFinder, findsOneWidget);

        final initialRect = tester.getRect(indicatorFinder);
        expect(initialRect.width, 208 - 16); // 192px width
        expect(initialRect.height, 40);

        // Tap on 'Videos'
        await tester.tap(find.text('Videos'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));

        // Indicator is in motion (intermediate position between Home and Videos)
        final midRect = tester.getRect(indicatorFinder);
        expect(midRect.top, greaterThan(initialRect.top));

        // Let animation finish
        await tester.pumpAndSettle();
        final videosRect = tester.getRect(indicatorFinder);
        expect(videosRect.top, greaterThan(midRect.top));
        expect(selectedSection, LibrarySection.videos);

        // Tap on 'Settings' at the bottom
        await tester.tap(find.text('Settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));

        final midSettingsRect = tester.getRect(indicatorFinder);
        expect(midSettingsRect.top, greaterThan(videosRect.top));

        await tester.pumpAndSettle();
        final settingsRect = tester.getRect(indicatorFinder);
        expect(settingsRect.top, greaterThan(midSettingsRect.top));
        expect(selectedSection, LibrarySection.settings);

        // Tap on 'Home' to slide back up
        await tester.tap(find.text('Home'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));

        final midHomeRect = tester.getRect(indicatorFinder);
        expect(midHomeRect.top, lessThan(settingsRect.top));

        await tester.pumpAndSettle();
        final finalHomeRect = tester.getRect(indicatorFinder);
        expect(finalHomeRect.top, initialRect.top);
        expect(selectedSection, LibrarySection.home);
      },
    );

    testWidgets('adapts smoothly when collapsed rail mode is active', (
      tester,
    ) async {
      LibrarySection selectedSection = LibrarySection.home;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return SizedBox(
                  width: 64,
                  height: 700,
                  child: ShellSideNav(
                    section: selectedSection,
                    onSelect: (next) => setState(() => selectedSection = next),
                    collapsed: true,
                    showSettings: false,
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final indicatorFinder = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_SlidingNavIndicator',
      );
      expect(indicatorFinder, findsOneWidget);

      final collapsedRect = tester.getRect(indicatorFinder);
      expect(collapsedRect.width, 48);
      expect(collapsedRect.height, 44);

      // Tap on Videos icon in rail
      await tester.tap(find.byIcon(Icons.movie_rounded));
      await tester.pumpAndSettle();

      expect(selectedSection, LibrarySection.videos);
      final newRect = tester.getRect(indicatorFinder);
      expect(newRect.top, greaterThan(collapsedRect.top));
      expect(newRect.width, 48);
      expect(newRect.height, 44);
    });
  });
}
