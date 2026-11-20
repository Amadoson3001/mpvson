/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/utils/query_decoders.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/video_size_coordinator.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// Width of the video (from [VideoParams]).
  int? videoParamsWidth;

  /// Height of the video (from [VideoParams]).
  int? videoParamsHeight;

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  NativePlayer get platform => player.platform as NativePlayer;

  Future<void> setProperty(String key, String value) async {
    await platform.setProperty(key, value, waitForInitialization: false);
  }

  Future<void> setProperties(Map<String, String> properties) async {
    // ORDER IS IMPORTANT.
    for (final entry in properties.entries) {
      await setProperty(entry.key, entry.value);
    }
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;
  bool _disposed = false;
  late final VideoSizeCoordinator _sizeCoordinator;

  /// {@macro native_video_controller}
  NativeVideoController._(
    super.player,
    super.configuration,
  )   : width = configuration.width,
        height = configuration.height {
    _sizeCoordinator = VideoSizeCoordinator(
      initialWidth: configuration.width,
      initialHeight: configuration.height,
      applyNative: (targetWidth, targetHeight) async {
        if (_disposed) return;
        final handle = await player.handle;
        if (_disposed) return;
        await _channel.invokeMethod(
          'VideoOutputManager.SetSize',
          {
            'handle': handle.toString(),
            'width': targetWidth?.toString() ?? 'null',
            'height': targetHeight?.toString() ?? 'null',
          },
        );
        if (_disposed) return;
        width = _sizeCoordinator.overrideWidth;
        height = _sizeCoordinator.overrideHeight;
      },
    );
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        if (_disposed) return;
        if ([0, null].contains(event.dw) || [0, null].contains(event.dh)) {
          return;
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        if (videoParamsWidth == width && videoParamsHeight == height) {
          return;
        }

        videoParamsWidth = width;
        videoParamsHeight = height;

        await _sizeCoordinator.updateSourceDimensions(width, height);
      }),
    );
  }

  /// {@macro native_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Update [configuration] to have default values.
    configuration = configuration.copyWith(
      vo: configuration.vo ?? 'libmpv',
      hwdec: configuration.hwdec ?? 'auto',
    );

    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // In case no video-decoders are found, this means media_kit_libs_***_audio is being used.
    // Thus, --vid=no is required to prevent libmpv from trying to decode video (otherwise bad things may happen).
    //
    // Search for common H264 decoder to check if video support is available.
    final decoders = await queryDecoders(handle);
    if (!decoders.contains('h264')) {
      throw UnsupportedError(
        '[VideoController] is not available.'
        ' '
        'Please use media_kit_libs_***_video instead of media_kit_libs_***_audio.',
      );
    }

    // Creation:
    final controller = NativeVideoController._(
      player,
      configuration,
    );

    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    // Wait until first texture ID is received or native initialization fails.
    // We are not waiting on the native-side itself because it will block the UI thread.
    final completer = Completer<void>();
    _createCompleters[handle] = completer;
    void listener() {
      final value = controller.id.value;
      if (value != null && !completer.isCompleted) {
        debugPrint('NativeVideoController: Texture ID: $value');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    try {
      try {
        await controller.setProperties(
          {
            'vo': configuration.vo!,
            'hwdec': configuration.hwdec!,
            'vid': 'auto',
            'hwdec-codecs': 'h264,hevc,mpeg2video,vp9,av1,vp8,mpeg4,vc1',
            'vd-lavc-dr': 'yes',
            'framedrop': 'vo',
            'hwdec-extra-frames': '4',
            if (Platform.isWindows || Platform.isLinux) 'opengl-es': 'yes',
          },
        );
        await _channel.invokeMethod(
          'VideoOutputManager.Create',
          {
            'handle': handle.toString(),
            'configuration': {
              'width': configuration.width.toString(),
              'height': configuration.height.toString(),
              'enableHardwareAcceleration':
                  configuration.enableHardwareAcceleration,
            },
          },
        );
        await completer.future;
      } finally {
        controller.id.removeListener(listener);
        if (identical(_createCompleters[handle], completer)) {
          _createCompleters.remove(handle);
        }
      }
      return controller;
    } on Object {
      // Failed output creation must not cache a controller without a texture.
      // Remove its player teardown callback before releasing it here.
      player.platform?.release.remove(controller._dispose);
      try {
        await controller._dispose();
      } on Object {
        // Keep the original initialization failure as the reported error.
      }
      rethrow;
    }
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
  }) async {
    if (_disposed) return;
    await _sizeCoordinator.setSize(width: width, height: height);
  }

  @override
  Future<void> setRenderVisibility(bool visible) async {
    final handle = await player.handle;
    await _channel.invokeMethod(
      'VideoOutputManager.SetVisibility',
      {
        'handle': handle.toString(),
        'visible': visible,
      },
    );
  }

  /// Returns native renderer diagnostics on platforms that support it.
  @override
  Future<Map<String, Object?>> getNativeStats() async {
    if (_disposed) return const <String, Object?>{};
    try {
      final handle = await player.handle;
      final raw = await _channel.invokeMethod<Object?>(
        'VideoOutputManager.GetStats',
        {'handle': handle.toString()},
      );
      if (raw is Map) {
        return raw.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } on MissingPluginException {
      // Unsupported on platforms without GetStats.
    } on PlatformException {
      // Best-effort diagnostics.
    }
    return const <String, Object?>{};
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sizeCoordinator.dispose();
    super.dispose();
    await videoParamsSubscription?.cancel();
    final handle = await player.handle;
    if (identical(_controllers[handle], this)) _controllers.remove(handle);
    await _channel.invokeMethod(
      'VideoOutputManager.Dispose',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();
  static final _createCompleters = HashMap<int, Completer<void>>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler(
          (MethodCall call) async {
            try {
              debugPrint(call.method.toString());
              debugPrint(call.arguments.toString());
              switch (call.method) {
                case 'VideoOutput.Error':
                  {
                    final int handle = call.arguments['handle'];
                    final String error = (call.arguments['error'] as String?) ??
                        'VideoOutput initialization failed.';
                    final completer = _createCompleters.remove(handle);
                    if (completer != null && !completer.isCompleted) {
                      completer.completeError(
                        PlatformException(
                          code: 'VIDEO_OUTPUT_INIT_FAILED',
                          message: error,
                        ),
                      );
                    }
                    break;
                  }
                case 'VideoOutput.Resize':
                  {
                    // Notify about updated texture ID & [Rect].
                    final int handle = call.arguments['handle'];
                    final Rect rect = Rect.fromLTWH(
                      call.arguments['rect']['left'] * 1.0,
                      call.arguments['rect']['top'] * 1.0,
                      call.arguments['rect']['width'] * 1.0,
                      call.arguments['rect']['height'] * 1.0,
                    );
                    final int id = call.arguments['id'];
                    _controllers[handle]?.rect.value = rect;
                    _controllers[handle]?.id.value = id;
                    // Notify about the first frame being rendered.
                    if (rect.width > 0 && rect.height > 0) {
                      final completer = _controllers[handle]
                          ?.waitUntilFirstFrameRenderedCompleter;
                      if (!(completer?.isCompleted ?? true)) {
                        completer?.complete();
                      }
                    }
                    break;
                  }
                default:
                  {
                    break;
                  }
              }
            } catch (exception, stacktrace) {
              debugPrint(exception.toString());
              debugPrint(stacktrace.toString());
            }
          },
        );
}
