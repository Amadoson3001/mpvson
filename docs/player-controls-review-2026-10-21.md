# Player controls review, 21 October 2026

The playback controls introduced on 20 October remain in the current application:

- Settings > Video & audio offers Performance, Balanced and Quality presets,
  hardware decoding, picture adjustments and audio/subtitle timing offsets.
- Changed mpv properties are serialized, checked by reading them back, and
  cached after confirmation. Superseded requests are coalesced. Reset can retry
  an earlier failed application of the same preferences.
- Shuffle is available directly in the queue. It tracks unique queue entries,
  exhausts a cycle before repeating, and preserves the current entry when
  toggled. Previous and Next follow confirmed playback history.
- Rapid shuffle/repeat actions retain the latest requested state while native
  writes run in order. Navigation history is bounded to 10,000 visits.
- More > Playback information, also available with I, reports the active
  decoder, frame-drop counters, synchronization difference and buffered media.
  It refreshes on demand.
- Engine updates default to stable releases. Development builds require an
  explicit channel selection. A missing stable libmpv package leaves the loaded
  engine unchanged. The bundled engine's actual development identity remains
  visible.

## Verification after the workspace cleanup

The newer workspace commit removed the previous test and native smoke-test
infrastructure. The controls review used an isolated Flutter package under the
ignored `build/quality-checks` directory, without restoring the removed files to
the application's source tree.

- Playback/controller/settings/statistics/sizing checks: 74 passed.
- Player UI checks: 46 passed. Their thumbnail fakes were adapted to the newer
  idle-cleanup API.
- A separate delayed-startup check confirmed that opening a file while session
  restoration is pending preserves the requested item and its playing state.
- In the running Windows release, a 1920 by 1080 AV1 file used
  `d3d11va-copy` at approximately 24 fps. The sampled output and decoder drop
  counters were both zero. Playback information and the queue rendered
  correctly. Volume was restored and the verification window was closed.

The live check used the existing release reporting
`mpv v0.41.0-dev-g6a262d11f`. It does not validate a later engine pin or a final
build containing the concurrent broader bug fixes.

A subsequent headless native check used the newly bundled
`mpv v0.41.0-dev-ge471496c5`. All three quality presets, hardware decoding off,
picture adjustments, audio/subtitle timing offsets and resetting defaults were
accepted and confirmed through native property readback. Playback information
also returned the engine identity. This validates setting application, without
exercising GPU presentation or measuring playback performance.

## Integration review

The concurrent bug audit recovered the earlier controls checks into the main
test suite. Its combined run reached 283 passing tests before the final review
changes. Independent review then reproduced an additional startup shuffle race:
a delayed restore write could overtake a newer user toggle. The integrated
serialized-write fix passes the isolated regression.

Review also identified a Linux creation-failure branch that returned an output
without a texture and then reached an assertion. That path now propagates a
creation error and releases the callback context. Linux compilation and graphics
verification remain assigned to CI. Final combined verification belongs to the
concurrent bug audit and is recorded in `docs/bug-audit.md`.

After these changes, the main suite reached 285 passing tests with two opt-in
native checks skipped by default. Formatting and static analysis were clean,
and the combined Windows release built successfully.
The two opt-in native source/retry checks subsequently passed, and bundled-engine
provenance verification confirmed the package, module and license digests.

A visible check of that release rendered 1920 by 1080 AV1 at 23.980 fps using
`d3d11va-copy`, with zero sampled output/decoder drops and a 0.1 ms A/V
difference. Module inspection confirmed that the profile's previously selected
`g6a262d11f` engine was loaded from its versioned engine directory. Consequently,
this visible check does not validate GPU presentation by the newly bundled
`ge471496c5` engine. The playback information dialog rendered correctly. The
verification window was paused and closed; the engine selection was unchanged.

Before overlay containment, Windows accessibility content remained stale after
playback began, even while the visible player and menus responded. No new crash
dump appeared during this check. The historical native crash remains unproven
as resolved.

An isolated widget test of the ready-to-video transition produced correct
Flutter semantics with the fake video surface: Ready to play disappeared and
Pause/Queue controls were exposed. This does not inspect serialized incremental
updates or the native bridge. A related upstream Slider/OverlayPortal defect is
documented in [Flutter issue 190357](https://github.com/flutter/flutter/issues/190357).
[Flutter PR 193372](https://github.com/flutter/flutter/pull/193372), merged into
master on 19 October, prevents orphan traversal-child serialization when an
animated traversal parent is absent. This is a candidate explanation for the
observed native failure; the concurrent audit is evaluating an application-level
overlay containment workaround rather than treating the upstream report as proof.

The incremental-update recorder then reproduced the SDK defect with a plain
pushed Slider and found six empty orphan nodes when the application opened
Settings > Video & audio. The same application flow passed after the integrated
`SliderOverlay` containment workaround, including mouse hover transitions between
the More and Queue tooltips. The minimal SDK reproduction also passed with local
overlay containment. This verifies mitigation of the reproduced serialization
failure while preserving Material sliders. The concurrent audit's subsequent
native retest exposed the playback controls and all six tuning sliders through
Windows accessibility, including after opening settings. Its expanded main
suite reached 286 passing tests with a clean analyzer and a successful Windows
release build. The separate historical crash assessment still needs broader
native stress coverage.

Tuning slider announcements now include the setting name and formatted value;
the regression also verifies distinct increase/decrease announcements. The
combined suite and Windows build passed again after this adjustment. The
reproduced accessibility serialization failure is covered in the retained suite
and is described in `docs/bug-audit.md`.

## Remaining native limitation

On 20 October, an isolated activation run crashed inside Flutter's Windows
`FlutterPlatformNodeDelegate::ChildAtIndex`. Local PDB symbols identified that
function from the fault address. Accessibility-tree update errors also appeared
in the earlier native logs. The limited live check on 21 October produced no new
crash dump, but this does not prove that the native crash has been eliminated.

The earlier synthetic 10,000-entry queue run completed with zero dropped frames,
2.81 ms UI p95, 2.086 ms raster p95 and 34.372 ms restore-to-texture p95. Those
measurements describe the earlier build and fixture. They are not fresh timings
for the current engine pin or evidence that every reported source of lag is
fixed. Linux runtime verification remains outstanding on this Windows machine.
