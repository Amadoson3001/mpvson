import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/player_queue_layout.dart';
import 'package:mpvson/ui/player/views/queue_slide_transition.dart';

const _queuePanelKey = ValueKey<String>('queue-panel');
const _toggleKey = ValueKey('toggle');

/// Applies motion settings whenever its inherited dependencies change.
///
/// Mirrors `PlayerQueueLayout`, which owns the transition and re-reads the
/// settings from its own `didChangeDependencies`.
class _MotionSettingsApplier extends StatefulWidget {
  const _MotionSettingsApplier({
    required this.onApplyMotion,
    required this.child,
  });

  final void Function(BuildContext context) onApplyMotion;
  final Widget child;

  @override
  State<_MotionSettingsApplier> createState() => _MotionSettingsApplierState();
}

class _MotionSettingsApplierState extends State<_MotionSettingsApplier> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onApplyMotion(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Minimal host mirroring the library shell's queue mount rules.
class _QueueSlideHost extends StatefulWidget {
  const _QueueSlideHost();

  @override
  State<_QueueSlideHost> createState() => _QueueSlideHostState();
}

class _QueueSlideHostState extends State<_QueueSlideHost>
    with SingleTickerProviderStateMixin {
  late final QueueSlideTransition _slide;
  bool _open = false;
  bool _mounted = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _slide = QueueSlideTransition(
      vsync: this,
      initialOpen: false,
      onDismissed: _onDismissed,
    );
  }

  void _onDismissed() {
    if (!mounted || _open) return;
    setState(() => _mounted = false);
  }

  void _setOpen(bool next) {
    setState(() {
      _open = next;
      if (next) _mounted = true;
    });
    _slide.drive(next);
  }

  void setReducedMotion(bool value) {
    setState(() => _reduceMotion = value);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: _reduceMotion),
        child: _MotionSettingsApplier(
          onApplyMotion: _slide.applyMotion,
          child: Builder(
            builder: (context) => Scaffold(
              body: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  if (_open || _mounted)
                    QueueSlideSlot(
                      progress: _slide.progress,
                      child: SizedBox(
                        key: _queuePanelKey,
                        width: AppLayout.queuePanelWidth,
                        child: const ColoredBox(color: Color(0xFF336699)),
                      ),
                    ),
                  IconButton(
                    key: _toggleKey,
                    onPressed: () => _setOpen(!_open),
                    icon: const Icon(Icons.queue_music),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('rapid open→close→open keeps queue mounted', (tester) async {
    await tester.pumpWidget(const _QueueSlideHost());

    expect(find.byKey(_queuePanelKey), findsNothing);

    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byKey(_queuePanelKey), findsOneWidget);

    // Close, then reopen before the deferred unmount runs.
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(_queuePanelKey), findsOneWidget);
  });

  testWidgets('dismissal unmounts, and reopening mounts again', (tester) async {
    await tester.pumpWidget(const _QueueSlideHost());

    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_queuePanelKey), findsOneWidget);

    // Close and let the reverse finish: the deferred dismiss callback is the
    // only thing that unmounts the panel, and it has to survive its own frame.
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_queuePanelKey), findsNothing);

    // Reopening after a real dismissal must mount the panel again.
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_queuePanelKey), findsOneWidget);

    // And the slot reaches its full width once the forward finishes.
    final slot = tester.widget<QueueSlideSlot>(find.byType(QueueSlideSlot));
    expect(slot.progress.value, 1.0);
  });

  testWidgets('reduced motion enabled mid-transition settles at once', (
    tester,
  ) async {
    await tester.pumpWidget(const _QueueSlideHost());

    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(_queuePanelKey), findsOneWidget);
    final sliding = tester
        .widget<QueueSlideSlot>(find.byType(QueueSlideSlot))
        .progress
        .value;
    expect(sliding, greaterThan(0.0));
    expect(sliding, lessThan(1.0));

    // Turn reduced motion on while the panel is still sliding. A transition
    // already in flight keeps the duration it started with, so the motion
    // settings have to snap it rather than run out the original timing.
    final host = tester.state<_QueueSlideHostState>(
      find.byType(_QueueSlideHost),
    );
    host.setReducedMotion(true);
    await tester.pump();

    expect(
      tester.widget<QueueSlideSlot>(find.byType(QueueSlideSlot)).progress.value,
      1.0,
    );
  });
}
