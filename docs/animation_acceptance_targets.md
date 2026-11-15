# Animation acceptance targets

Proposed gates from the Mpvson animation optimization plan (section 1 and 7). Calibrate against a captured baseline before treating failures as regressions.

## Display cadence

| Target | Typical conditions | Nominal frame interval |
| --- | --- | --- |
| Smooth 60 FPS | Supported minimum hardware, 1080p @ 60 Hz, local 1080p H.264 playing | 16.67 ms |
| Smooth 60 FPS (capable) | Capable PC on 60 Hz with the same UI transitions | 16.67 ms |
| Smooth 120 FPS | Capable PC where the desktop and Flutter engine actually deliver 120 Hz to the app | 8.33 ms |

Interactive animation should track vsync: at the same animation-speed preference, a panel should take the same wall-clock time at 60 Hz and 120 Hz. Video playback stays on the source cadence (e.g. 24 FPS video can present at 24 FPS while chrome animates at display rate). When the UI is idle, the app should not schedule animation frames on its own.

## Frame pacing gates (UI motion)

Repeat each primary transition at least **20 times** on the agreed fixtures (old-hardware 60 Hz and capable 120 Hz).

| Metric | Gate |
| --- | --- |
| Missed display intervals during active motion | &lt; 1% of frames |
| Back-to-back missed intervals | No recurring pattern |
| p95 `buildDuration` | &lt; ~75% of frame interval (~12.5 ms @ 60 Hz, ~6.25 ms @ 120 Hz) |
| p95 `rasterDuration` | Same 75% budget, measured independently from build |
| `totalSpan` / first-use stalls | Inspect separately from build and raster; do not mask with averaged FPS |

Use Flutter DevTools Performance, `SchedulerBinding.addTimingsCallback` (see `lib/dev/animation_timings_recorder.dart`), and on Windows PresentMon for actual presentation intervals.

## Playback gates (independent of UI pacing)

During equal-duration runs with UI idle vs. repeated transitions:

- No repeatable increase in decoder or output frame drops (`PlaybackStatistics` / mpv properties).
- No audio glitches, black frames during docking, or wrong final texture size.
- Stress cases to record (where each backend tops out): 4K, software decode, high DPI, thumbnail extraction under load.

## Inputs held constant across runs

Hardware profile, reduced motion, and animation speed are independent knobs. Baseline captures should note all three plus window size, display scaling, graphics settings, Flutter version, and build mode (profile vs. release).