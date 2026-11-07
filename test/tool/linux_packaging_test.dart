// Static assertions for the Linux packaging scripts (B-4 remediation).
//
// install.sh must install exactly one launcher entry
// (dev.mpvson.mpvson.desktop) and remove the legacy mpvson.desktop from
// earlier installers; uninstall.sh must still clean up both names so old
// installs are not left behind. The repository itself ships only the
// dev-prefixed desktop entry and icon.
//
// These tests read the scripts as text; they do not execute them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const String legacyDesktop = 'mpvson.desktop';
const String currentDesktop = 'dev.mpvson.mpvson.desktop';
const String legacyIcon = 'mpvson.svg';
const String currentIcon = 'dev.mpvson.mpvson.svg';

void main() {
  final String install = File('packaging/linux/install.sh').readAsStringSync();
  final String uninstall = File(
    'packaging/linux/uninstall.sh',
  ).readAsStringSync();

  group('packaging/linux/install.sh', () {
    test('installs the current desktop entry', () {
      expect(
        install,
        contains(r'cp "${SCRIPT_DIR}/dev.mpvson.mpvson.desktop"'),
      );
      expect(install, contains('dev.mpvson.mpvson.desktop'));
    });

    test('never copies the legacy desktop entry', () {
      // The dev-prefixed path must not satisfy a legacy copy check: require
      // that no cp copies the legacy file into ~/.local/share/applications.
      expect(
        RegExp(
          r'cp\s+"?\$\{SCRIPT_DIR\}/' + legacyDesktop + r'"',
        ).hasMatch(install),
        isFalse,
        reason: 'install.sh must not install the legacy mpvson.desktop.',
      );
    });

    test('removes the legacy desktop entry with rm -f', () {
      expect(
        install,
        contains(RegExp(r'rm\s+-f\s+"\$\{APP_DIR\}/mpvson\.desktop"')),
      );
    });

    test('installs the current icon and removes the legacy icon', () {
      expect(install, contains(r'cp "${SCRIPT_DIR}/dev.mpvson.mpvson.svg"'));
      expect(
        RegExp(
          r'cp\s+"?\$\{SCRIPT_DIR\}/' + legacyIcon + r'"',
        ).hasMatch(install),
        isFalse,
      );
      expect(
        install,
        contains(RegExp(r'rm\s+-f\s+"\$\{ICON_DIR\}/mpvson\.svg"')),
      );
    });

    test('after a run, exactly one launcher entry can remain', () {
      // Every write into APP_DIR must target the current entry; the only
      // legacy operation allowed is the removal.
      final RegExp appDirWrites = RegExp(
        r'(cp|chmod)\s+"?\S+"?\s+"?\$\{APP_DIR\}/([A-Za-z.]+)"',
      );
      final List<String> writtenEntries = appDirWrites
          .allMatches(install)
          .map((RegExpMatch match) => match.group(2)!)
          .toSet()
          .toList();
      expect(writtenEntries, <String>[currentDesktop]);
    });
  });

  group('packaging/linux/uninstall.sh', () {
    test('removes both the current and the legacy desktop entry', () {
      expect(uninstall, contains('"\${APP_DIR}/$legacyDesktop"'));
      expect(uninstall, contains('"\${APP_DIR}/$currentDesktop"'));
    });

    test('removes both the current and the legacy icon', () {
      expect(uninstall, contains('"\${ICON_DIR}/$legacyIcon"'));
      expect(uninstall, contains('"\${ICON_DIR}/$currentIcon"'));
    });
  });

  group('packaging/linux repository contents', () {
    test('ships exactly one desktop entry and one icon', () {
      final List<FileSystemEntity> entries = Directory(
        'packaging/linux',
      ).listSync();
      final List<String> desktops =
          entries
              .whereType<File>()
              .map((File file) => p.basename(file.path))
              .where((String name) => name.endsWith('.desktop'))
              .toList()
            ..sort();
      final List<String> icons =
          entries
              .whereType<File>()
              .map((File file) => p.basename(file.path))
              .where((String name) => name.endsWith('.svg'))
              .toList()
            ..sort();
      expect(desktops, <String>[
        currentDesktop,
      ], reason: 'the legacy mpvson.desktop must not ship anymore.');
      expect(icons, <String>[currentIcon]);
    });
  });
}
