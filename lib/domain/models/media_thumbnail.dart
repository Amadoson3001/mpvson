import 'dart:typed_data';

/// An immutable image and its source media duration, when known.
///
/// [Uint8List] itself is mutable, so the input is copied into one immutable
/// view. Callers can reuse that stable buffer with image widgets.
class MediaThumbnail {
  MediaThumbnail({required Uint8List bytes, this.duration = Duration.zero})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  /// Stable immutable bytes suitable for reuse by image decoders.
  final Uint8List bytes;

  int get byteLength => bytes.length;

  final Duration duration;
}
