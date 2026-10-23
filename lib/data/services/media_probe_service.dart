import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/media_kind.dart';
import '../../domain/models/media_metadata.dart';

@immutable
class ProbeResult {
  const ProbeResult({
    required this.canonicalSource,
    required this.path,
    required this.kind,
    required this.metadata,
    required this.fileSize,
    required this.modifiedAt,
    this.hasEmbeddedArtwork = false,
  });

  final String canonicalSource;
  final String path;
  final MediaKind kind;
  final MediaMetadata metadata;
  final int fileSize;
  final DateTime modifiedAt;
  final bool hasEmbeddedArtwork;
}

class ProbeCancelledException implements Exception {
  const ProbeCancelledException([
    this.message = 'Probe operation was cancelled',
  ]);
  final String message;

  @override
  String toString() => 'ProbeCancelledException: $message';
}

abstract class MediaProbeService {
  Future<ProbeResult> probe(String filePath, {int? priority});
  Future<String?> resolveArtwork(String filePath, {bool embeddedOnly = false});
  void cancelAll();
  void dispose();
}
