import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/ui/core/components/animated_grid_reflow.dart';

class _ReflowHarness extends StatelessWidget {
  const _ReflowHarness({
    required this.columns,
    this.width = 1000,
    this.reduceMotion = false,
  });

  final int columns;
  final double width;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    const spacing = 20.0;
    const mainSpacing = 24.0;
    final itemWidth = (width - (columns - 1) * spacing) / columns;
    final itemHeight = itemWidth * 9 / 16 + 68;

    return MaterialApp(
      home: AppPreferencesScope(
        preferences: DesktopPreferences(reduceMotion: reduceMotion),
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 800,
              child: GridReflowScope(
                metrics: GridReflowMetrics(
                  columns: columns,
                  itemWidth: itemWidth,
                  itemHeight: itemHeight,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: mainSpacing,
                ),
                child: GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: mainSpacing,
                    mainAxisExtent: itemHeight,
                  ),
                  itemCount: 10,
                  itemBuilder: (context, index) => GridReflowItem(
                    key: ValueKey('item-$index'),
                    index: index,
                    child: SizedBox.expand(
                      key: ValueKey('card-$index'),
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'window column change lands immediately in new grid with featherlight settle',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const _ReflowHarness(columns: 4, width: 1000));
      await tester.pumpAndSettle();

      // Item 4 starts on row 2, column 1 in a 4-column grid.
      final card4Finder = find.byKey(const ValueKey('card-4'));
      final rectBefore = tester.getRect(card4Finder);
      expect(rectBefore.left, closeTo(0.0, 0.5));
      expect(rectBefore.top, greaterThan(150.0));

      // Switch to 5 columns (OS window maximize/restore).
      await tester.pumpWidget(const _ReflowHarness(columns: 5, width: 1144));

      // Card 4 lands directly in row 1, col 5 (no heavy diagonal flight across rows),
      // while the single-layer settle plays smoothly.
      final fadeFinder = find.descendant(
        of: find.byType(GridReflowScope),
        matching: find.byType(FadeTransition),
      );
      final fade = tester.widget<FadeTransition>(fadeFinder);
      expect(fade.opacity.value, closeTo(0.88, 0.02));

      await tester.pump(const Duration(milliseconds: 65));
      expect(fade.opacity.value, greaterThan(0.92));
      expect(fade.opacity.value, lessThan(1.0));

      await tester.pumpAndSettle();
      expect(fade.opacity.value, 1.0);
      final rectSettled = tester.getRect(card4Finder);
      expect(rectSettled.top, closeTo(0.0, 0.5));
      expect(rectSettled.right, closeTo(1144.0, 0.5));
    },
  );

  testWidgets('reduced motion skips settle transition on column change', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const _ReflowHarness(columns: 4, width: 1000, reduceMotion: true),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      const _ReflowHarness(columns: 5, width: 1144, reduceMotion: true),
    );

    expect(
      find.descendant(
        of: find.byType(GridReflowScope),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    final rect = tester.getRect(find.byKey(const ValueKey('card-4')));
    expect(rect.top, closeTo(0.0, 0.5));
    expect(rect.right, closeTo(1144.0, 0.5));
  });

  testWidgets(
    'StableGridReflowBox lays out grid once on frame 0 and glides in lockstep with shell motion',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      var gridBuildCount = 0;
      final sidebarWidth = ValueNotifier<double>(208.0);
      var targetSidebar = 208.0;
      addTearDown(sidebarWidth.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppPreferencesScope(
            preferences: const DesktopPreferences(),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1280,
                height: 800,
                child: Row(
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: sidebarWidth,
                      builder: (context, w, _) => SizedBox(width: w),
                    ),
                    Expanded(
                      child: ShellWidthMotionScope(
                        listenable: sidebarWidth,
                        pendingWidthDelta: () =>
                            sidebarWidth.value - targetSidebar,
                        columnBasisWidth: 1280.0 - 208.0,
                        child: StableGridReflowBox(
                          metricsBuilder: (width, columnBasisWidth) {
                            const gutter = 32.0;
                            final avail = (width - 2 * gutter).clamp(
                              0.0,
                              double.infinity,
                            );
                            final basisAvail = (columnBasisWidth - 2 * gutter)
                                .clamp(0.0, double.infinity);
                            final cols = ((basisAvail + 20) / 280).ceil().clamp(
                              1,
                              12,
                            );
                            final itemW = (avail - (cols - 1) * 20) / cols;
                            return GridReflowMetrics(
                              columns: cols,
                              itemWidth: itemW,
                              itemHeight: itemW * 9 / 16 + 68,
                              crossAxisSpacing: 20,
                              mainAxisSpacing: 24,
                              horizontalPadding: gutter,
                            );
                          },
                          builder: (context, metrics, isReflowing) {
                            gridBuildCount++;
                            return GridView.builder(
                              clipBehavior: isReflowing
                                  ? Clip.none
                                  : Clip.hardEdge,
                              padding: EdgeInsets.symmetric(
                                horizontal: metrics.horizontalPadding,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: metrics.columns,
                                    crossAxisSpacing: metrics.crossAxisSpacing,
                                    mainAxisSpacing: metrics.mainAxisSpacing,
                                    mainAxisExtent: metrics.itemHeight,
                                  ),
                              itemCount: 10,
                              itemBuilder: (context, index) => GridReflowItem(
                                key: ValueKey('s-item-$index'),
                                index: index,
                                child: SizedBox.expand(
                                  key: ValueKey('s-card-$index'),
                                  child: const ColoredBox(color: Colors.teal),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final card4 = find.byKey(const ValueKey('s-card-4'));
      final rectBefore = tester.getRect(card4);
      final buildsAtRest = gridBuildCount;

      // Start collapse (208 -> 64): column count stays anchored (4 cols), so
      // card 4 stays in row 2, col 1 and smoothly breathes wider in place with
      // ZERO cards flying across rows and ZERO intermediate GridView builds.
      targetSidebar = 64.0;
      sidebarWidth.value = 207.99;
      await tester.pump();
      final buildsAfterStart = gridBuildCount;
      final rectFrame0 = tester.getRect(card4);
      expect(rectFrame0.left, closeTo(rectBefore.left, 1.0));
      expect(rectFrame0.width, closeTo(rectBefore.width, 1.0));

      // Step through 10 intermediate frames: ZERO additional GridView builds,
      // and card 4 smoothly expands in width while staying in col 1!
      var prevWidth = rectFrame0.width;
      for (final nextW in <double>[
        180,
        160,
        140,
        120,
        100,
        88,
        78,
        72,
        68,
        65,
      ]) {
        sidebarWidth.value = nextW;
        await tester.pump();
        expect(gridBuildCount, buildsAfterStart);
        final currentWidth = tester.getRect(card4).width;
        expect(currentWidth, greaterThan(prevWidth));
        prevWidth = currentWidth;
      }

      // Final settle at 64px: card 4 stayed in row 2, col 1 (wider, never jumped rows).
      sidebarWidth.value = 64.0;
      await tester.pump();
      final rectSettled = tester.getRect(card4);
      expect(rectSettled.left, closeTo(64.0 + 32.0, 0.5));
      expect(rectSettled.top, greaterThan(150.0));
      expect(rectSettled.width, greaterThan(rectBefore.width + 20.0));
      expect(buildsAfterStart, greaterThan(buildsAtRest));
    },
  );
}
