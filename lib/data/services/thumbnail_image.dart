import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Largest decoded edge the thumbnail cache will accept.
const int thumbnailMaximumDimension = 16384;

/// Largest decoded pixel count the thumbnail cache will accept.
const int thumbnailMaximumMegaPixels = 32 * 1000 * 1000;

/// Largest encoded image the extractor will read back from disk.
const int thumbnailMaximumExtractedBytes = 12 * 1024 * 1024;

/// True when [bytes] has a JPEG, PNG, WebP, or GIF header.
bool thumbnailBytesLookLikeImage(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final isJpeg =
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[bytes.length - 2] == 0xff &&
      bytes.last == 0xd9;
  final isPng =
      bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a;
  final isWebp =
      bytes.length >= 16 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
  final isGif =
      bytes.length >= 10 &&
      (ascii.decode(bytes.sublist(0, 6), allowInvalid: true) == 'GIF87a' ||
          ascii.decode(bytes.sublist(0, 6), allowInvalid: true) == 'GIF89a');
  return isJpeg || isPng || isWebp || isGif;
}

Future<bool> thumbnailImageIsDecodable(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width < 1 ||
        descriptor.height < 1 ||
        descriptor.width > thumbnailMaximumDimension ||
        descriptor.height > thumbnailMaximumDimension ||
        descriptor.width * descriptor.height > thumbnailMaximumMegaPixels) {
      return false;
    }
    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    return true;
  } on Object {
    return false;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
