import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mpvson/data/repositories/app_preferences_repository.dart';

/// A File wrapper that parks the repository's read and rename steps on
/// completers so a test can interleave preference updates deterministically.
class _GatedFile extends Fake implements File {
  _GatedFile(this._real, this.readGate, this.readDone, this.renameGate);

  final File _real;
  final Completer<void> readGate;
  final Completer<void> readDone;
  final Completer<void> renameGate;

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  Future<bool> exists() => _real.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    await readGate.future;
    final contents = await _real.readAsString(encoding: encoding);
    readDone.complete();
    return contents;
  }

  @override
  Future<File> rename(String newPath) async {
    await renameGate.future;
    return _real.rename(newPath);
  }
}

void main() {
  test('animation preferences survive a JSON round trip', () {
    const prefs = DesktopPreferences(
      reduceMotion: true,
      animationSpeed: AnimationSpeed.slow,
    );
    final restored = DesktopPreferences.fromJson(
      jsonDecode(jsonEncode(prefs.toJson())) as Map<String, Object?>,
    );
    expect(restored.reduceMotion, true);
    expect(restored.animationSpeed, AnimationSpeed.slow);

    final legacy = DesktopPreferences.fromJson(<String, Object?>{});
    expect(legacy.reduceMotion, false);
    expect(legacy.animationSpeed, AnimationSpeed.normal);

    final unknown = DesktopPreferences.fromJson(<String, Object?>{
      'animationSpeed': 'warp',
    });
    expect(unknown.animationSpeed, AnimationSpeed.normal);
  });

  test(
    'flush() drains revisions queued while the previous save was completing',
    () async {
      final dir = await Directory.systemTemp.createTemp('mpvson-prefs-flush-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {
          // Best-effort cleanup; temp dir may already be gone.
        }
      });
      final file = File(p.join(dir.path, 'prefs.json'));
      final repo = AppPreferencesRepository(preferenceFile: file);

      // First save goes through normally.
      await repo.updatePreferences(
        const DesktopPreferences(seekStepSeconds: 10),
      );
      final first =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(first['seekStepSeconds'], 10);

      // Queue one more revision from inside the save-finished notification —
      // exactly the window where the old flush() already considered itself
      // done even though the newest revision was only just queued.
      var queued = false;
      repo.addListener(() {
        if (queued) return;
        queued = true;
        repo.updatePreferences(repo.preferences.copyWith(seekStepSeconds: 15));
      });

      await repo.flush();

      final saved =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(saved['seekStepSeconds'], 15);
      expect(repo.saveError, isNull);
    },
  );

  test(
    'load() keeps in-memory updates that raced with the file read',
    () async {
      final dir = await Directory.systemTemp.createTemp('mpvson-prefs-load-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {
          // Best-effort cleanup; temp dir may already be gone.
        }
      });
      final real = File(p.join(dir.path, 'prefs.json'));
      real.writeAsStringSync(
        jsonEncode(const DesktopPreferences(seekStepSeconds: 5).toJson()),
      );

      final readGate = Completer<void>();
      final readDone = Completer<void>();
      final renameGate = Completer<void>();
      final gated = _GatedFile(real, readGate, readDone, renameGate);
      final repo = AppPreferencesRepository(preferenceFile: gated);

      final loading = repo.load();

      // Update while load is parked on the gated read. The save itself parks on
      // the gated rename, so the on-disk primary still holds the old value when
      // the read completes.
      final updating = repo.updatePreferences(
        repo.preferences.copyWith(seekStepSeconds: 10),
      );
      readGate.complete();
      await readDone.future;
      renameGate.complete();

      await loading;
      // The in-memory update made during the read must win over the stale
      // on-disk snapshot.
      expect(repo.preferences.seekStepSeconds, 10);

      await updating;
      final saved =
          jsonDecode(await real.readAsString()) as Map<String, Object?>;
      expect(saved['seekStepSeconds'], 10);
      expect(repo.saveError, isNull);
    },
  );
}
