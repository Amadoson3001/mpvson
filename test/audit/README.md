# UI audit tools

These tests render the real `MpvsonApp` headlessly with a fake playback engine,
an in-memory library and in-memory preferences. No libmpv, no network, no disk
state.

## Files

- `test/support/app_harness.dart` builds the app (`Harness.create`), the fake
  engine, awkward sample data (`stressItems`), real temp media files
  (`makeMediaFiles`), and the error collectors (`collectErrors`, `fontIssues`).
- `test/support/audit_helpers.dart` has `buildHarness`, `tapNav` (opens the nav
  drawer when the window is compact), `tapText`, `openMedia`, `hover`,
  `auditStep`, and the size list `auditSizes`.
- `test/support/screenshot.dart` loads the real Onest and Material Icons fonts
  and writes PNGs of the current frame.
- `test/audit/screen_audit_test.dart` is the full matrix: theme x text scale x
  window size x data state. It fails on any layout exception and on any text
  that does not use the app font family.
- `test/audit/shots_test.dart` writes screenshots for visual review. It is
  skipped unless `--dart-define=SHOTS=true`.
- `test/audit/contrast_audit_test.dart` prints WCAG contrast failures for every
  accent preset in both themes.

## Commands

Run from the repo root (`E:\mpvson`).

CI runs `flutter test --exclude-tags=golden,benchmark`. The full layout matrix
in `screen_audit_test.dart` is tagged `golden` (skipped by default on plain
`flutter test`) and must be run explicitly with `--run-skipped`:

    flutter test --no-pub --run-skipped --tags=golden test/audit/screen_audit_test.dart

    flutter analyze --no-pub
    flutter test --no-pub --run-skipped test/audit/screen_audit_test.dart --plain-name "min720x480"
    flutter test --no-pub test/audit/shots_test.dart --dart-define=SHOTS=true --dart-define=SHOT_DIR=mine --dart-define=SHOT_ONLY=dark_1240

Screenshots land in `build/shots/<SHOT_DIR>/`. Open them with an image viewer
tool and judge them: spacing, alignment, hierarchy, truncation, contrast.

## Rules the audit enforces

- No `RenderFlex overflowed` or other framework exception at 720x480 up to
  1920x1080, at text scale 1.0 and 1.5, in dark and light themes.
- Every visible `Text` resolves to the `Onest` family. A bare
  `TextStyle(fontSize: ...)` passed to `ButtonStyle.textStyle` replaces the
  theme style and drops the family. Build such styles from
  `Theme.of(context).textTheme.labelLarge?.copyWith(...)` instead.

## Manual Windows smoke checklist

Run each scenario by hand against a release build on Windows; every line ends
with the expected result.

- Rapid next/prev: hammer next and prev through the queue faster than tracks
  can open; when the UI settles, the Now Playing title and progress match the
  engine's actual final track and no spinner stays visible for more than a
  moment.
- Mini-player double toggle: open and immediately close the mini player twice
  in a row; the main window restores to its correct pre-mini bounds both times
  with no blank, ghost, or duplicated window.
- Settings over Now Playing, then Esc: open Settings while Now Playing is up,
  then press Esc; Settings closes, Now Playing is untouched underneath, and
  playback state is unchanged.
- Folder drop not in the library: drop a folder that is not part of the
  library onto the window; the app points to Settings with import guidance
  instead of adding it silently, crashing, or hanging.
- Folder remove mid-scan: remove a folder while its scan is still running;
  the scan ends cleanly, the queue and library stay consistent, and no error
  dialog or stuck progress indicator remains.
- Update notes containing only a link: feed the update dialog release notes
  that are nothing but a URL; the dialog renders the link and does not crash.
- Quit while scanning: quit the app while a scan is in progress; the process
  exits promptly, no scan survives in the background, and the next launch
  opens a healthy database.
- Shipped DLL signatures: in the shipped bundle run
  `Get-AuthenticodeSignature` on `flutter_windows.dll`,
  `d3dcompiler_47.dll`, and `vulkan-1.dll`; all three report Status `Valid`
  because packaging never strips them.
