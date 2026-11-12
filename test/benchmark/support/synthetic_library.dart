import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:path/path.dart' as p;

/// Synthetic scanner paths for in-memory library benchmarks (no disk I/O).
String benchmarkTrackPath(int libraryIndex, int trackIndex) => p.join(
  r'C:\mpvson-benchmark',
  'lib-$libraryIndex',
  'Artist $libraryIndex - Track $trackIndex.mp3',
);

/// Upserts [rowCount] discovered audio paths spread across `libraryCount` folders.
Future<void> seedSyntheticLibrary(
  LibraryDatabase db, {
  required int rowCount,
  int libraryCount = 10,
}) async {
  if (rowCount <= 0) return;
  final filesPerLib = (rowCount / libraryCount).ceil();
  final paths = <String>[];
  for (var lib = 0; lib < libraryCount && paths.length < rowCount; lib++) {
    final remaining = rowCount - paths.length;
    final batch = remaining < filesPerLib ? remaining : filesPerLib;
    for (var track = 0; track < batch; track++) {
      paths.add(benchmarkTrackPath(lib, track));
    }
  }
  await db.batchUpsertDiscoveredFiles(paths);
}

List<String> syntheticPaths(int rowCount, {int libraryCount = 10}) {
  if (rowCount <= 0) return const [];
  final filesPerLib = (rowCount / libraryCount).ceil();
  final paths = <String>[];
  for (var lib = 0; lib < libraryCount && paths.length < rowCount; lib++) {
    final remaining = rowCount - paths.length;
    final batch = remaining < filesPerLib ? remaining : filesPerLib;
    for (var track = 0; track < batch; track++) {
      paths.add(benchmarkTrackPath(lib, track));
    }
  }
  return paths;
}
