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

    flutter analyze --no-pub
    flutter test --no-pub test/audit/screen_audit_test.dart --plain-name "min720x480"
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
