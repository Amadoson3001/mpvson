# Native source-identity probe (18 Oct 2026)

Evidence collected with `flutter test --dart-define=MPVSON_PROBE_NATIVE_EVENTS=true
test/native_source_probe_test.dart` against the bundled libmpv (`build/windows/x64/runner/Release/libmpv-2.dll`).
Full log: `test-output/native-source-probe.log`.

## What the engine actually reports

| Signal | Observed behaviour | Usable as |
|---|---|---|
| `path` property | Notified on **every** load, including opening the same file again and opening after `stop()` | Source start **with identity** |
| `file-format` property | Never notified in any load | Not usable |
| `track-list` / `duration` | Notified right after the load, once the demuxer is open | Loaded confirmation |
| `eof-reached` property | Never notified, even at the end of the file | Not reliable |
| `idle-active` property | `yes` after the file ended, and after an explicit `stop()` | End of source (correlated by identity) |
| `playlist-pos` property | `-1` when the player goes idle | Secondary end signal |
| `path` value on Windows | `\\?\C:\Users\...\probe-a.mp4` (long-path prefix) | Must be stripped before comparing with our own canonical paths |

Consequences for the adapter:

1. `path` is exactly the "native start with source identity" signal the repair plan asks
   for, and it also fires for a same-source reload, so a reload is never left unattributed.
2. Loaded confirmation cannot use `file-format`; it uses the first `track-list` or
   `duration` notification for the attached source.
3. Completion cannot rely on media_kit's `completed` stream alone: media_kit derives
   `completed` from `eof-reached`, which was never notified in this environment. MPV's
   `idle-active` notification is the reliable end signal, correlated with the attached
   source identity so an explicit `stop()` is not mistaken for the end of a file.
4. `path` needs `\\?\` long-path normalisation before it can be compared with the
   user-facing source string.

## Sequence in the running application (18 Oct 2026)

The application launches through media_kit and adds a video output, which the probe
above does not. Reading the smoke run's `diagnostics.log` (records `native.observe`,
`native.event`, `playback.open`, `playback.attached`) shows a different sequence than a
bare `Player.open`. Offsets are relative to the first record:

```
+0.000 s  native.observe supported, engine.version
+0.000 s  native.event loaded      <- registration reports the idle player's values
+0.000 s  native.event ended
+0.008 s  playback.open boundary 1
+0.018 s  native.event started <source>
+0.018 s  playback.attached boundary 1
+0.018 s  native.event loaded      <- track-list
+0.028 s  native.event loaded      <- track-list (video)
+0.032 s  native.event loaded      <- duration
+0.246 s  native.event started <same source>   <- the engine reports `path` again
+0.246 s  native.event loaded
```

Two consequences are part of the contract now:

- A load can be announced with `path` **twice**, and `playback.open` shows the
  application asked for it once. The second announcement is treated as a reload of the
  same source: the load is unconfirmed again until `track-list`/`duration` confirm it,
  and progress restarts at zero. The engine's duration, however, is a property of the
  stream rather than of one load, and the engine does not re-notify an unchanged value;
  clearing it on the second announcement left the source at zero indefinitely (the
  application played the file to its end while the player still reported no duration),
  so `started` keeps the last known duration.
- Reaching the end of the queue stops the engine from inside the snapshot that reported
  completion, which publishes again. Snapshots are therefore delivered through a
  re-entrancy-safe emitter (`lib/data/services/snapshot_emitter.dart`) instead of
  adding to the synchronous broadcast controller directly; a nested add used to throw
  `Bad state: Cannot fire new event. Controller is already firing an event`, which the
  controller recorded as `Playback engine unavailable: ...` and which left the queue
  stopped with an error instead of a clean end of playback.
