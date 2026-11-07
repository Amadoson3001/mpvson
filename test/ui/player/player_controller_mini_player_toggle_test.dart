import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../support/app_harness.dart';

/// Player stand-in whose queue already holds a video entry, so the layout
/// manager's mini-player gate lets the toggle through without a real engine.
class _VideoQueueController extends PlayerController {
  _VideoQueueController()
    : super(playback: FakePlaybackService(), sessions: SessionRepository());

  @override
  MediaEntry? get current => MediaEntry(
    id: 'clip-1',
    path: r'C:\Media\clip.mp4',
    title: 'Clip',
    lastPlayed: DateTime(2025, 1, 1),
  );
}

/// Window state the real window manager plugin would keep, reached by
/// intercepting the `window_manager` method channel.
class _SimulatedWindow {
  _SimulatedWindow() : enterBounds = const Rect.fromLTWH(120, 90, 1280, 720) {
    bounds = enterBounds;
  }

  late Rect bounds;
  late final Rect enterBounds;
  bool maximized = false;
  bool alwaysOnTop = false;

  /// When set, the next call whose method matches [gateMethod] does not
  /// complete until the gate does, freezing that transition mid-flight.
  Completer<void>? gate;
  String? gateMethod;

  /// The bounds `enterMiniPlayer` computes from the pre-mini window size.
  Rect get miniBounds => Rect.fromLTWH(
    enterBounds.right - miniPlayerSize.width,
    enterBounds.top,
    miniPlayerSize.width,
    miniPlayerSize.height,
  );
}

Future<Object?> _handleCall(_SimulatedWindow window, MethodCall call) async {
  final gate = window.gate;
  if (gate != null && window.gateMethod == call.method) {
    window.gate = null;
    window.gateMethod = null;
    await gate.future;
  }
  final arguments = call.arguments;
  switch (call.method) {
    case 'getBounds':
      return {
        'x': window.bounds.left,
        'y': window.bounds.top,
        'width': window.bounds.width,
        'height': window.bounds.height,
      };
    case 'setBounds':
      final map = arguments! as Map<Object?, Object?>;
      window.bounds = Rect.fromLTWH(
        (map['x']! as num).toDouble(),
        (map['y']! as num).toDouble(),
        (map['width']! as num).toDouble(),
        (map['height']! as num).toDouble(),
      );
      return null;
    case 'setMinimumSize':
    case 'setMaximumSize':
      return null;
    case 'setAlwaysOnTop':
      final map = arguments! as Map<Object?, Object?>;
      window.alwaysOnTop = map['isAlwaysOnTop']! as bool;
      return null;
    case 'isMaximized':
      return window.maximized;
    case 'maximize':
      window.maximized = true;
      return null;
    case 'unmaximize':
      window.maximized = false;
      return null;
    case 'isFullScreen':
      return false;
    default:
      return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('window_manager');

  PlayerLayoutManager buildManager(
    _VideoQueueController controller, {
    void Function(bool isMiniPlayer)? onMiniPlayerChanged,
  }) {
    final manager = PlayerLayoutManager(
      controller: controller,
      desktopWindow: true,
      isShowingLibrary: () => false,
      showMessage: (message) {},
      showFeedback: (icon, label, {centered = false}) {},
      onMiniPlayerChanged: onMiniPlayerChanged,
    );
    addTearDown(manager.dispose);
    return manager;
  }

  _VideoQueueController buildController() {
    final controller = _VideoQueueController();
    addTearDown(() async {
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    return controller;
  }

  _SimulatedWindow buildWindow() {
    final window = _SimulatedWindow();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => _handleCall(window, call));
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return window;
  }

  test(
    'a toggle during exit cannot capture the mini bounds as restore bounds',
    () async {
      final window = buildWindow();
      final manager = buildManager(
        buildController(),
        onMiniPlayerChanged: (v) {},
      );

      final originalBounds = window.bounds;
      final miniBounds = window.miniBounds;

      await manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isTrue);
      expect(window.bounds, miniBounds);

      // Freeze the exit right after it flipped the state, so the restore is
      // still pending when the next toggle arrives.
      final gate = Completer<void>();
      window.gate = gate;
      window.gateMethod = 'setAlwaysOnTop';

      final exiting = manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isFalse);

      // The double toggle lands while the exit is still restoring the window.
      await manager.toggleMiniPlayer();
      expect(
        manager.isMiniPlayer,
        isFalse,
        reason:
            'the re-entry must be swallowed; capturing the mini bounds '
            'here would corrupt the restore state',
      );
      expect(window.bounds, miniBounds);

      gate.complete();
      await exiting;

      expect(
        window.bounds,
        originalBounds,
        reason: 'the exit must restore the true pre-mini bounds',
      );
      expect(window.alwaysOnTop, isFalse);

      // Re-entering still restores the mini dimensions.
      await manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isTrue);
      expect(window.bounds, miniBounds);

      // And the following exit restores the honest bounds once more: the
      // mini bounds captured during the aborted toggle never became restore
      // bounds.
      await manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isFalse);
      expect(window.bounds, originalBounds);
    },
  );

  test(
    'a toggle during enter is swallowed until the transition settles',
    () async {
      final window = buildWindow();
      final manager = buildManager(buildController());

      final miniBounds = window.miniBounds;

      // Freeze the enter before it stores its restore bounds.
      final gate = Completer<void>();
      window.gate = gate;
      window.gateMethod = 'isMaximized';

      final entering = manager.toggleMiniPlayer();
      await manager.toggleMiniPlayer();
      expect(
        manager.isMiniPlayer,
        isFalse,
        reason: 'the second toggle must wait for the running enter',
      );

      gate.complete();
      await entering;

      expect(manager.isMiniPlayer, isTrue);
      expect(window.bounds, miniBounds);
    },
  );

  test(
    'a settled enter then exit restores the original window bounds',
    () async {
      final window = buildWindow();
      final manager = buildManager(buildController());

      final originalBounds = window.bounds;
      final miniBounds = window.miniBounds;

      await manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isTrue);
      expect(window.bounds, miniBounds);
      expect(window.alwaysOnTop, isTrue);

      await manager.toggleMiniPlayer();
      expect(manager.isMiniPlayer, isFalse);
      expect(window.bounds, originalBounds);
      expect(window.alwaysOnTop, isFalse);
    },
  );
}
