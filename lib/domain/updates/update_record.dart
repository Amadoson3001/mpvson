import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'semantic_version.dart';

/// A verified desktop release archive recorded in updater storage.
final class UpdateRecord {
  const UpdateRecord({
    required this.version,
    required this.sha256,
    required this.fileName,
    required this.recordedAt,
    required this.fileSizeBytes,
  });

  final String version;
  final String sha256;
  final String fileName;
  final DateTime recordedAt;
  final int fileSizeBytes;

  Map<String, Object?> toJson() => {
    'version': version,
    'sha256': sha256,
    'fileName': fileName,
    'recordedAt': recordedAt.toIso8601String(),
    'fileSizeBytes': fileSizeBytes,
  };

  static UpdateRecord? fromJson(Object? data) {
    if (data is! Map<String, Object?>) return null;
    final version = data['version'];
    final sha256 = data['sha256'];
    final fileName = data['fileName'];
    final recordedAtValue = data['recordedAt'];
    final fileSizeBytes = data['fileSizeBytes'];

    if (version is! String ||
        sha256 is! String ||
        fileName is! String ||
        recordedAtValue is! String ||
        fileSizeBytes is! int) {
      return null;
    }
    try {
      SemanticVersion.parse(version);
    } catch (_) {
      return null;
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      return null;
    }
    final recordedAt = DateTime.tryParse(recordedAtValue);
    if (recordedAt == null) return null;

    if (fileName.isEmpty ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        fileName == '.' ||
        fileName == '..') {
      return null;
    }

    return UpdateRecord(
      version: version,
      sha256: sha256.toLowerCase(),
      fileName: fileName,
      recordedAt: recordedAt,
      fileSizeBytes: fileSizeBytes,
    );
  }
}

/// Manages persistence, cached bundle reuse, and archive retention in updater storage.
final class UpdateOwnershipStore {
  UpdateOwnershipStore(this.directory);

  final Directory directory;
  static const int maxRetainedArchives = 2;
  static const String manifestFileName = 'updates.json';

  File get _recordFile => File(p.join(directory.path, manifestFileName));

  Future<List<UpdateRecord>> loadRecords() async {
    final file = _recordFile;
    if (!await file.exists()) return [];
    try {
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) return [];
      final list = decoded['records'];
      if (list is! List<Object?>) return [];
      final results = <UpdateRecord>[];
      for (final item in list) {
        if (item is Map) {
          final stringMap = <String, Object?>{};
          for (final entry in item.entries) {
            if (entry.key is String) {
              stringMap[entry.key as String] = entry.value;
            }
          }
          final record = UpdateRecord.fromJson(stringMap);
          if (record != null) {
            results.add(record);
          }
        }
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRecords(List<UpdateRecord> records) async {
    await directory.create(recursive: true);
    final data = {
      'version': 1,
      'records': records.map((r) => r.toJson()).toList(),
    };
    final randomSuffix = Random.secure().nextInt(1 << 32).toRadixString(16);
    final tempFile = File(
      p.join(directory.path, '.$manifestFileName.$pid-$randomSuffix.tmp'),
    );
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await tempFile.writeAsString('${encoder.convert(data)}\n', flush: true);
      await tempFile.rename(_recordFile.path);
    } catch (_) {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<File?> findMatchingVerifiedBundle({
    required String version,
    required String sha256,
  }) async {
    final records = await loadRecords();
    final normalizedHash = sha256.toLowerCase();

    UpdateRecord? matchingRecord;
    for (final record in records.reversed) {
      if (record.version == version && record.sha256 == normalizedHash) {
        matchingRecord = record;
        break;
      }
    }
    if (matchingRecord == null) return null;

    final candidateFile = File(p.join(directory.path, matchingRecord.fileName));
    if (!await candidateFile.exists()) return null;
    if (!FileSystemEntity.isFileSync(candidateFile.path)) return null;

    final size = await candidateFile.length();
    if (size != matchingRecord.fileSizeBytes) return null;

    final actualHash = await computeSha256(candidateFile);
    if (actualHash != normalizedHash) return null;

    final updatedRecords = records
        .where((r) => r.fileName != matchingRecord!.fileName)
        .toList();
    updatedRecords.add(
      UpdateRecord(
        version: matchingRecord.version,
        sha256: matchingRecord.sha256,
        fileName: matchingRecord.fileName,
        recordedAt: DateTime.now().toUtc(),
        fileSizeBytes: size,
      ),
    );
    await saveRecords(updatedRecords);

    return candidateFile;
  }

  Future<void> recordVerifiedDownload({
    required String version,
    required String sha256,
    required File bundleFile,
  }) async {
    final records = await loadRecords();
    final fileName = p.basename(bundleFile.path);
    final fileSize = await bundleFile.length();
    final normalizedHash = sha256.toLowerCase();

    final filtered = records.where((r) => r.fileName != fileName).toList();
    filtered.add(
      UpdateRecord(
        version: version,
        sha256: normalizedHash,
        fileName: fileName,
        recordedAt: DateTime.now().toUtc(),
        fileSizeBytes: fileSize,
      ),
    );

    filtered.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    final retained = <UpdateRecord>[];
    final toPrune = <UpdateRecord>[];

    if (filtered.length <= maxRetainedArchives) {
      retained.addAll(filtered);
    } else {
      final retainStartIndex = filtered.length - maxRetainedArchives;
      toPrune.addAll(filtered.sublist(0, retainStartIndex));
      retained.addAll(filtered.sublist(retainStartIndex));
    }

    for (final oldRecord in toPrune) {
      final oldFile = File(p.join(directory.path, oldRecord.fileName));
      if (!p.isWithin(directory.path, oldFile.path)) continue;
      if (!await oldFile.exists()) continue;
      if (!FileSystemEntity.isFileSync(oldFile.path)) continue;

      final length = await oldFile.length();
      if (length != oldRecord.fileSizeBytes) continue;

      final hash = await computeSha256(oldFile);
      if (hash != oldRecord.sha256) continue;

      try {
        await oldFile.delete();
      } catch (_) {}
    }

    await saveRecords(retained);
  }

  static Future<String> computeSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }
}
