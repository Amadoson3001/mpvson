import 'package:flutter/material.dart';

/// Keeps a slider's value indicator in the same animated semantics subtree.
///
/// Flutter versions without flutter/flutter#193372 can otherwise serialize an
/// orphan overlay node during a fade and freeze Windows accessibility updates.
/// See https://github.com/flutter/flutter/issues/190357.
class SliderOverlay extends StatelessWidget {
  const SliderOverlay({super.key, required this.child});

  final Slider child;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    alwaysSizeToContent: true,
    clipBehavior: Clip.none,
    child: child,
  );
}
