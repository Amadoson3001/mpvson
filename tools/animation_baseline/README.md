# Animation baseline capture

Repeatable steps for recording UI frame pacing **before** motion changes ship. Aligns with plan section 2 and acceptance gates in [`docs/animation_acceptance_targets.md`](../../docs/animation_acceptance_targets.md).

## Fixed run configuration

Record these values in every log header so runs compare cleanly:

| Field | Suggested fixed value |
| --- | --- |
| Flutter | Same as CI (`3.50.0` stable unless pinned locally) |
| Build mode | Profile for tracing; release for presentation truth |
| Window size | 1240×780 (app default) unless testing another layout |
| Display | Fixed monitor, fixed scaling (100% or your QA default) |
| Graphics / quality | Default or documented preset |
| Reduced motion | Off for primary baseline; repeat key flows with On |
| Animation speed | Normal (repeat Fast/Slow only when auditing preferences) |
| Media fixture | Local **1080p H.264** file, fixed duration (e.g. 2–5 min) |
| Library fixture | Fixed folder: small library + one **large** library run with thumbnails |

Warm-up: run each transition once, then capture **cold first use** and **warmed repeat** separately.

## Results

Fill one row per run and keep the artifacts listed at the bottom with it.

| Date | Git SHA | Machine tier | Display | Build | Scenario | p95 build | p95 raster | Missed intervals | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| _unfilled_ | | | | | | | | | |

**Status.** The 60 FPS and 120 FPS acceptance gates are **not yet established by a captured run**. What is established so far is the device-free frame-cost guard in this README's next section: the dock and the inline queue transition no longer recompose the stage, the controls or the top bar on any animation tick. Raster time and the real presentation interval still need the hardware runs above, on both an older 60 Hz machine and a capable 120 Hz one, before either gate can be called met.

## Builds

From the repo root (`E:\mpvson`):

```powershell
flutter pub get --enforce-lockfile

# Profile — DevTools, timeline, in-app frame timings
flutter run -d windows --profile lib/main.dart

# Release — actual present cadence (no debug timings unless dart-defined)
flutter run -d windows --release lib/main.dart
```

Linux profile/release: same commands with `-d linux`.

Release packaging (matches CI): `flutter build windows --release --target=lib/main.dart`.

## Interactions to record

For each row, capture **playback paused** and **playback active** where it applies. Script keyboard/mouse so the action is identical every run.

| Scenario | Notes |
| --- | --- |
| Video **dock / undock** (library open, in-app mini slot) | Primary optimization path |
| **Queue** open/close (wide inline panel) | Player and library hosts |
| **Queue drawer** (narrow) | If distinct from inline |
| **Now Playing** sheet open/close | Library |
| **Sidebar** collapse/expand | Navigation chrome |
| **Controls** show/hide (auto-hide) | Fullscreen and windowed |
| **Seek preview** scrub | Pointer + keyboard scrub |
| **Large library** | Scroll/grid with thumbnails loading |

Add at least one **120 Hz** run with **video paused** so presentation cadence is not masked by video frames.

## Flutter DevTools — Performance

1. `flutter run --profile` and open the DevTools Performance view.
2. Start recording before the scripted interaction; stop after motion settles.
3. Note frame chart misses, shader compilation spikes on first use, and GPU/UI thread balance.
4. Export or screenshot the trace; link to the git revision and fixture list.

Docs: [Flutter performance view](https://docs.flutter.dev/tools/devtools/performance)

## In-app frame timings (`addTimingsCallback`)

Opt-in recorder logs rolling p50/p95/max for `buildDuration`, `rasterDuration`, and `totalSpan` to the Dart log (`mpvson.anim`). It attaches from `main()` in every build mode and decides for itself from the flags below, so `--profile` runs are covered.

**Windows (PowerShell):**

```powershell
$env:MPVSON_RECORD_ANIM_TIMINGS = '1'
flutter run -d windows --profile lib/main.dart
```

**Alternate:** `--dart-define=MPVSON_RECORD_ANIM_TIMINGS=true` (also enables it in release, which is why it is off by default there).

Tag every run so excerpts stay comparable — the label is echoed on each summary line:

```powershell
$env:MPVSON_RECORD_ANIM_TIMINGS = '1'
$env:MPVSON_ANIM_RUN_LABEL = 'sha=<git sha>;machine=old-60hz;display=60'
flutter run -d windows --profile lib/main.dart
```

View logs in the IDE debug console or:

```powershell
flutter logs
```

Each summary line looks like:

```text
[window] run="sha=1a2b3c4;machine=old-60hz;display=60" mode=profile frames=120 build_us p50=... p95=... max=... raster_us ... totalSpan_us ...
```

Compare the `p95` values against the gates in [`docs/animation_acceptance_targets.md`](../../docs/animation_acceptance_targets.md): p95 build and p95 raster each stay under ~75% of the frame interval (~12.5 ms at 60 Hz, ~6.25 ms at 120 Hz).

Implementation: [`lib/dev/animation_timings_recorder.dart`](../../lib/dev/animation_timings_recorder.dart). Disabled in release unless explicitly dart-defined.

API reference: [addTimingsCallback](https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addTimingsCallback.html)

## Device-free frame-cost guard (run this first)

Before spending a hardware run, `flutter test` already measures the two moving-geometry paths that dominate build work — the inline queue slot resizing the player area, and the docked video changing its `Positioned` size:

```powershell
flutter test test/ui/player/player_stage_motion_cost_test.dart
flutter test test/ui/player/player_content_dock_test.dart
```

These drive the real widgets through a scripted dock and queue transition and assert, by widget identity, that the stage, the controls and the top bar are not recomposed on any animation tick. A failure here is a per-frame build regression you can fix without a device; a pass is the precondition for spending a capture run on it.

What this cannot tell you is raster cost, GPU time, or the actual presentation interval. Those still need the runs below, on both an older 60 Hz machine and a capable 120 Hz one, with the same fixtures and window size.

## PresentMon (Windows presentation)

Use PresentMon to verify **actual** display intervals (60 vs 120 Hz), especially when build/raster are under budget but motion feels sticky.

1. Install [PresentMon](https://github.com/GameTechDev/PresentMon) (CaptureApplication or CLI).
2. Run Mpvson (profile or release) and note the process name (e.g. `mpvson.exe`).
3. Capture during the same scripted interactions; record msBetweenPresents, dropped frames, and sync with UI action timestamps.

Docs: [PresentMon capture metrics](https://github.com/GameTechDev/PresentMon/blob/main/README-CaptureApplication.md)

## Playback vs UI

Compare mpv decoder/output drop counters for equal-length segments with UI idle vs. transitions active. Use in-app playback statistics (`lib/data/services/playback_statistics.dart`) and native renderer diagnostics on Windows where available.

## Artifacts to store per run

- Git SHA, build mode, machine tier (min vs capable), display Hz
- DevTools trace or summary screenshot
- PresentMon CSV or summary (Windows)
- `mpvson.anim` log excerpt with p95 build/raster/totalSpan
- Notes: first-use vs warmed, reduced motion on/off, any missed-frame pattern

Compare results against [`docs/animation_acceptance_targets.md`](../../docs/animation_acceptance_targets.md).