import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_motion.dart';

void main() {
  testWidgets('reduced motion skips the reveal and returns zero duration', (
    tester,
  ) async {
    late Duration duration;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              duration = AppMotion.duration(context, AppMotion.reveal);
              return const AppMotionReveal(child: Text('Ready'));
            },
          ),
        ),
      ),
    );

    expect(duration, Duration.zero);
    expect(find.text('Ready'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppMotionReveal),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppMotionReveal),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
  });

  testWidgets('reveal settles to full opacity and natural scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppMotionReveal(
          duration: const Duration(milliseconds: 120),
          child: const SizedBox(key: ValueKey('revealed-surface')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    final reveal = find.byType(AppMotionReveal);
    final fade = tester.widget<FadeTransition>(
      find.descendant(of: reveal, matching: find.byType(FadeTransition)),
    );
    final scale = tester.widget<Transform>(
      find.descendant(of: reveal, matching: find.byType(Transform)),
    );

    expect(fade.opacity.value, 1);
    expect(scale.transform.getMaxScaleOnAxis(), closeTo(1, 0.0001));
    expect(find.byKey(const ValueKey('revealed-surface')), findsOneWidget);
  });
}
