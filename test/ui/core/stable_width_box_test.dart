import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/components/stable_width_box.dart';

void main() {
  testWidgets(
    'lays out child at slot width plus widthDelta while keeping own size',
    (tester) async {
      var buildCount = 0;
      const childKey = ValueKey('child');

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              height: 200,
              child: StableWidthBox(
                widthDelta: 100,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    buildCount++;
                    return const SizedBox.expand(key: childKey);
                  },
                ),
              ),
            ),
          ),
        ),
      );

      expect(buildCount, 1);
      expect(tester.getSize(find.byType(StableWidthBox)), const Size(400, 200));
      expect(tester.getSize(find.byKey(childKey)), const Size(500, 200));
    },
  );

  testWidgets(
    'does not relayout child while slotWidth + widthDelta stays constant',
    (tester) async {
      var buildCount = 0;
      const childKey = ValueKey('stable-child');
      final stableChild = LayoutBuilder(
        builder: (context, constraints) {
          buildCount++;
          return const SizedBox.expand(key: childKey);
        },
      );

      final stateNotifier = ValueNotifier<(double, double)>((208.0, 144.0));
      addTearDown(stateNotifier.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              height: 400,
              child: ValueListenableBuilder<(double, double)>(
                valueListenable: stateNotifier,
                builder: (context, pair, _) {
                  final (sidebarWidth, delta) = pair;
                  return Row(
                    children: [
                      SizedBox(width: sidebarWidth, height: 400),
                      Expanded(
                        child: StableWidthBox(
                          widthDelta: delta,
                          child: stableChild,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(buildCount, 1);
      expect(tester.getSize(find.byKey(childKey)).width, 736.0);

      for (final next in <(double, double)>[
        (170.0, 106.0),
        (120.0, 56.0),
        (112.003, 48.0),
        (64.0, 0.0),
      ]) {
        stateNotifier.value = next;
        await tester.pump();
        expect(buildCount, 1);
      }

      expect(tester.getSize(find.byType(StableWidthBox)).width, 736.0);
      expect(tester.getSize(find.byKey(childKey)).width, 736.0);
    },
  );

  testWidgets('taps in the clipped overflow area do not reach the child', (
    tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Row(
            children: [
              SizedBox(
                width: 400,
                height: 200,
                child: StableWidthBox(
                  widthDelta: 150,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              const Expanded(child: SizedBox(height: 200)),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(450, 100));
    await tester.pump();
    expect(taps, 0);

    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('widthDelta 0 sizes child identically to slot width', (
    tester,
  ) async {
    const childKey = ValueKey('zero-delta-child');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 200,
            child: StableWidthBox(
              widthDelta: 0,
              child: const SizedBox.expand(key: childKey),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(StableWidthBox)), const Size(400, 200));
    expect(tester.getSize(find.byKey(childKey)), const Size(400, 200));
  });
}
