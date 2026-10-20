# Verification

## Parallel audit repairs on 20 October 2026

Three disjoint repair streams covered playback/persistence, queue thumbnails, and engine updates, followed by sequential verification on this machine. No concurrent Flutter commands were run.

Confirmed defects repaired:

- Restored stopped-session progress no longer resets to zero during startup. The controller publishes the restored queue before applying volume, rate and shuffle, because those engine writes can emit synchronous snapshots that previously saw no current row and overwrote the saved position and duration.
- A failed resume seek keeps the saved resume floor instead of clearing it, and resume completion/error callbacks are generation-guarded so a slower seek cannot overwrite a newer user seek.
- Shutdown now writes the final checkpoint before draining persistence, retries release for a discard close even when an earlier release failed, and completes a joined discard close only after the engine is torn down. A failed save still surfaces as `SessionSaveException`, leaves the controller open, and remains recoverable through retry or discard.
- Session parsing rejects non-finite version numbers and does not turn non-finite position/duration values into unbounded integers.
- Malformed HTTP(S) sources are rejected with redacted diagnostics instead of falling through as local paths. Malformed percent-encoded stream titles fall back to the raw segment instead of failing the queue row.
- Marker-only staging attempts left by a crash between marker and lease creation are swept, while live, foreign, linked or unowned staging paths remain untouched.
- Thumbnail polling retries transient output-stat and directory-listing failures rather than reporting a missing thumbnail.
- Queue artwork uses `ResizeImagePolicy.fit` and fills the thumbnail content area, preserving non-16:9 aspect ratios before `BoxFit.cover` crops.

Four new regression/probe setups also needed test-harness corrections, not product changes: the buffering test now opens both items it transitions between; the failing-save fake intercepts `saveScrubbed` as well as `save`; the thumbnail-layout assertion measures the bordered content area rather than the outer frame; and the opt-in playback-service probe releases `media_kit_video`'s initialization gate, which a plain `test()` never completes without a Flutter frame or texture channel, so its native commands no longer wait forever.

Verification evidence:

- `dart format --output=none --set-exit-if-changed lib test tool`: 78 files, no changes.
- `flutter analyze --no-pub`: no issues; log `test-output/analyze-20261020-final.log`.
- `flutter test --no-pub`: 343 passed, 9 opt-in/native tests skipped; log `test-output/full-suite-20261020-final.log`.
- `flutter test --no-pub --dart-define=MPVSON_TEST_THUMBNAILS=true test/thumbnail_native_test.dart`: 4 passed; log `test-output/thumbnail-native-20261020.log`.
- `flutter test --no-pub --dart-define=MPVSON_PROBE_PLAYBACK_SERVICE=true test/native_playback_service_probe_test.dart`: passed; `prepare()` completed in 41 ms and the first opened source was attributed to boundary 1 with its native path, loaded flag and 8000 ms duration; log `test-output/native-playback-service-probe.log`, run log `test-output/native-playback-service-probe-20261020d.log`.
- `flutter test --no-pub --dart-define=MPVSON_LIVE_MPV_TEST=true test/mpv_upstream_native_test.dart`: passed in 1m20s; downloaded the official `0.41.0-dev.39135297726+g6a262d11f` build (64,944,186 bytes), activated it in an isolated engine store, rendered and paused through the native runner executable, then rolled back to the bundled engine; log `test-output/mpv-upstream-native-20261020.log`, evidence `test-output/mpv-upstream-native/run-86e172a7/`.
- `flutter build windows --release --no-pub`: passed; log `test-output/build-windows-20261020-final.log`.
- `flutter test --no-pub --dart-define=MPVSON_NATIVE_ENGINE_SMOKE=true test/engine_native_smoke_test.dart`: passed in 1m36s; log `test-output/engine-native-20261020.log`.
- `dart run tool/engine_provenance.dart verify` and `inventory`: pinned engine `v0.41.0-dev-gfffe7a23a`, cache, bundle and inventory verified.
- Historical native verification (`test-output/native-smoke-20261020/`): native rendering, screenshot, seek to 1041 ms, pause, native fullscreen, controls at rendered opacity 0 and hidden cursor all passed.
- Focused playback regressions: `test/playback_controller_test.dart` passed 57 tests after the startup-order repair; the full-suite count above includes them.

Local Linux build and runtime verification remain unavailable on this machine. The Ubuntu CI job is still the evidence path for Linux compilation and packaging; do not describe Linux as locally tested.

## Follow-up performance repairs on 19 October 2026

This pass repairs the follow-up review findings. The earlier section below records the preceding implementation and its older package.

- Large imports stage and validate privately, then commit atomically. Queue interaction during staging prevents a stale import from replacing the user's action.
- Queue snapshots keep captured metadata immutable through shared chunks. Search caches refresh LRU recency and enforce query and retained-match limits.
- Queue rows share the service's 8 MiB compressed cache and show cached artwork provisionally while asynchronous source and sidecar validation runs. Disk write queues coalesce and have byte/task limits; disk accounting avoids a full scan per write.
- Thumbnail interruption generations retry active jobs across rapid suspend/resume. Request deadlines pause during queue waits and suspension.
- Native extraction opens metadata under `vo=null`, then reopens with the selected track, timestamp and image output configured. This keeps decoder reuse working after duration probes and prevents an automatic video frame from replacing embedded cover art. Each open resets mpv's frame limit to `all` before capture limits it to one frame.
- Windows renderer lifecycle commands preserve order on an owned worker. Teardown drains every texture retirement callback, and surface resize uses the same lock as raster reads. Linux rendering and teardown share a recursive lock; idle work holds references and EGL failures restore or unbind context state.
- The revised benchmark exercises the queue UI, scrolling and filtering, and uses a long fixture with silent audio. Raw process samples distinguish warm-up from measured cycles. Restore timing waits for a fresh native texture to reach Flutter raster. It includes polling latency and does not measure compositor scan-out.

Historical validation logs are under `test-output/performance-fixed-20261019/`:

- Formatting passed for all 78 application, test and tool Dart files. Flutter analysis reported no issues.
- The full default suite passed 328 tests, with nine opt-in native tests skipped.
- All four native thumbnail tests passed, including one reused decoder processing regular video, sidecar probing, embedded cover art and another regular video. The thumbnail worker now uses a 2 MiB demux buffer.
- The Windows release build passed. Engine provenance and generated inventory verification passed.
- Native engine activation, invalid-engine recovery and rollback passed in 1m17s.
- The extracted portable package passed native playback, seek, pause, fullscreen, hidden controls, hidden cursor and screenshot checks. The extracted application, renderer plugin and libmpv hashes match the release build.
- The extracted package completed 50 minimize/restore cycles with 1,000 queued paths after a ten-second warm-up. Restore-to-fresh-texture p95 was 32.593 ms, UI frame p95 2.827 ms and raster frame p95 1.962 ms. The initial eight-thumbnail workload took 1,929.779 ms cold and 2.111 ms warm. Private bytes went from 356,782,080 after warm-up to 295,084,032 at the last measured sample, with a 360,243,200 peak. Handles went from 1,369 to 1,376. Raw cycle/frame and process samples are in `portable-benchmark/` beneath the validation directory.

These historical benchmark measurements use distinct hard-linked paths to one synthetic 640x360 video with silent audio on an i5-12450H laptop with RTX 3050 and Intel UHD graphics. They verify the exercised workload and do not establish a speedup against the earlier framework-only benchmark or guarantee timings for other codecs and hardware. The generated portable ZIP and SHA-256 files are in `dist/`.

Local Linux build/runtime verification is unavailable because WSL is not installed. The Linux CI job remains responsible for compilation and native playback checks. Linux EGL cleanup when the Flutter context is unavailable still relies on eventual context destruction.

## Earlier responsiveness implementation on 19 October 2026

Implementation of minimize/restore responsiveness, thumbnail pipelining, and bounded memory budgets:

- **Window and video rendering**:
  - Explicit minimize/restore handling in `PlayerScreen` (`didChangeAppLifecycleState` and `windowManager` listener). While minimized, thumbnail extraction, hidden animations (via `TickerMode(enabled: !_animationsSuspended, ...)`), and video presentation are suspended. Blur/focus events preserve active rendering.
  - Video presentation and texture pipelines: pinned repository-owned patch in `packages/media_kit_video`. Added `SetVisibility` on Windows and Linux video outputs. When hidden, the render loop acknowledges frames using mpv's documented skip-rendering mechanism (`MPV_RENDER_PARAM_SKIP_RENDERING = 1`) without publishing Flutter texture frames.
  - Bounded render tasks: `std::atomic<bool> render_task_pending_` caps pending thread pool tasks to at most 1, preventing queue starvation or thread accumulation during rapid render events.
  - Viewport-sized texture & sizing policy: `VideoOutputPolicy` carrying physical video viewport dimensions and visibility. Physical viewport sizing preserves source aspect ratio without upscaling, debounces size notifications by 100 ms, deduplicates size changes, and preserves policy across source transitions.
  - Background audio: set `pauseUponEnteringBackgroundMode = false` on `Video` widget to preserve audio playback while minimized.
  - Restoring avoids engine recreation or texture destruction by preserving the player, render context, and last viewport-sized texture.

- **Thumbnails and caches**:
  - Single headless decoder reuse: `_MediaKitThumbnailExtractor` lazily instantiates a single headless `Player` decoder reused for extraction and duration probes. Cancellation interrupts the current job (`stop()`) without disposing the decoder. Source state is reset between jobs; the decoder is only disposed on service disposal.
  - Single active native extraction and single active image normalization job enforce strict serialization.
  - Priority and scroll settling: `ThumbnailPriority` (`normal`, `high`). Visible rows request thumbnails with `ThumbnailPriority.high`. Memory-cached thumbnails are returned immediately (`QueueThumbnailCache`). When scrolling, new extraction is deferred until scroll settles for 100 ms (`_QueueScrollScope`).
  - Suspension & resumption: `ThumbnailService.suspend()` and `resume()`. Outstanding requests remain resumable across minimize/restore cycles.
  - Cache budgets & memory bounding: compressed thumbnail memory cache capped at 8 MiB (down from 32 MiB); Flutter decoded image cache capped at 16 MiB. Display images decode at physical display size clamped to 320 px (`ResizeImage`).
  - Serialized background disk writes and pruning: extracted thumbnails return immediately to UI; disk cache writes and pruning run asynchronously in a serialized queue with strict cache accounting and active temporary file protection.

- **Queue and persistence**:
  - Search projections with lazy views: replaced duplicated search filter projections with lazy views (`_LazyFilteredEntriesView`, `_LazyFilteredIndexedView`) over one index cache (`_matchingIndices`), capped at 8 queries and 20,000 retained matches with LRU eviction.
  - Progress & metadata decoupling: seeking, duration updates, and playback ticks update metadata without copying the queue or incrementing structural `queueRevision`.
  - Batched import: `PlayerController.openPaths` processes large imports in batches of 100 entries, yielding to the event loop and cancelling on stale operations.
  - Single-entry undo: stored one removed `MediaEntry` rather than cloning the entire queue list.
  - Offloaded session parsing: JSON parsing and session model deserialization executed in a worker isolate (`Isolate.run`), preserving `SessionFormatException` for recovery from backup.

- **Verification results**:
  - `flutter analyze`: clean (0 issues).
  - `flutter test`: all 313 unit and widget tests passing (0 failures).
  - `test/thumbnail_native_test.dart`: 3/3 native thumbnail extraction tests passing.
  - `flutter build windows --release`: successfully built Windows release binary.
  - `test/engine_native_smoke_test.dart`: native engine activation, recovery, and rollback verified.
  - Historical extracted portable package verification: native video playback, seeking to 1041 ms, pause, and fullscreen auto-hide (rendered opacity 0.0, hidden cursor) verified successfully.
  - Release package: `dist/mpvson-windows-x64.zip` (SHA-256: `c90a35f8626c841bdc280d4c1f2d53d14d720a8a1c41e672b43482dd58af9206`).

## Review repairs on 18 October 2026

The follow-up review at `bfe9ea6` found URL-shaped progress checkpoints surviving migration, stale filtered queue entries, punctuation-adjacent URL secrets in diagnostics, and a post-commit engine cleanup race. Those cases now have permanent regressions. This pass also repairs queue tick subscriptions, persistence draining, thumbnail cancellation/cache normalization, cooperative engine extraction cancellation, stale-stage ownership and bounded maintainer downloads. See [code-quality-review.md](code-quality-review.md) for the repair table and remaining release/performance gates.

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --reporter expanded`: 300 passed, eight opt-in native tests skipped; log `test-output/fix-validation-20261018/flutter-test.log`.
- `flutter build windows --release --no-pub`: passed; log `test-output/fix-validation-20261018/windows-build.log`.
- Native thumbnail suite: all three tests passed. Twenty additional separate cold processes passed the real frame-extraction test; logs `test-output/fix-validation-20261018/thumbnail-cold-01.log` through `thumbnail-cold-20.log`.
- Final native engine activation, invalid-engine recovery and bundled rollback: passed in 2m04s; log `test-output/fix-validation-20261018/engine-native-final.log`, reports under `test-output/engine-native/run-cad3f8b2/`. The first run hit the former 35-second per-phase test budget while a recovery child subsequently produced a successful report. The test now allows 60 seconds for a phase that can launch two native processes. Startup also avoids hashing the main DLL twice per validation while retaining the selection-record integrity check.
- Isolated file-backed 256 MiB engine archive extraction: passed. The test sampled current process RSS every 5 ms, from 151,715,840 bytes initially to a sampled peak of 157,077,504 bytes, a 5,361,664-byte increase. `ProcessInfo.maxRss` moved from 159,264,768 to 160,071,680 bytes. This fixture uses a stored ZIP entry. It is a local measurement, not proof for every compressed package or machine; log `test-output/fix-validation-20261018/engine-memory-256m.log`.
- CI emits package checksum files and includes the generated Windows engine inventory. The revised Linux workflow has not run locally.
- The first extracted-package fullscreen check timed out while waiting for the controls/cursor to hide; playback itself had duration and progress. The built binary and extracted copy passed immediate rechecks. Review then found that an overlapping metrics event was dropped during a native fullscreen read and that an early resize could read the old OS flag. Reads now drain pending notifications and reconcile once more after 150 ms. A deterministic platform-channel widget regression covers both conditions without playback ticks. The initial failed report remains in `test-output/fix-validation-20261018/portable-smoke/`.
- Final rebuilt portable package: five independent native checks passed playback, rendering, seek, pause, native fullscreen, controls at rendered opacity zero, and hidden-cursor configuration. Reports/screenshots are in `test-output/fix-validation-20261018/portable-final-01/` through `portable-final-05/`. Player and renderer both loaded the DLL from the extracted package. Formatting passed with no changes. Portable ZIP `dist/mpvson-windows-x64-reviewed-20261018.zip` includes the generated engine inventory; SHA-256 `a9b2da2e74c7e6fd4cb3cab93f1d3082b6e859fd5e399e894b6f4adddabbd1cd`, also stored in its `.zip.sha256` file.

Linux runtime, queue frame timings, native stress/leak testing, full native advisory/license review and public-release signing remain open gates. A stuck native thumbnail `Player.dispose()` can keep teardown pending; output deletion waits for actual disposal to prevent file races.

> Historical sections below keep the engine identity each pass was verified with. Since
> 18 Oct 2026 the Windows bundle ships the pinned engine described in the first section
> (`libmpv mpv v0.41.0-dev-gfffe7a23a`). Statements naming
> `v0.36.0-403-g652a1dd907` describe earlier passes with the September 2023 module that
> this pin replaced.

## Parallel readiness repair completion on 2026-10-18 (Items 9, 10, 15, 16, 17, 18, 19, 20, 21, 23)

All remaining open priority items were partitioned into four strictly disjoint architectural streams, implemented concurrently, and verified sequentially:

- **Track 1: Updates & Security (Items 9, 10, 15)**:
  - Streamed update I/O: downloads write to a private file with incremental SHA-256; archive headers are preflighted from disk via `InputFileStream`, and extraction streams entries through `OutputFileStream` in a worker isolate. The 128 MiB additional-working-memory target has not been measured. Unit tests establish behavior and input limits, not a process RSS bound.
  - Cross-process boot coordination: OS-backed exclusive file lease (`.engine-boot.lease`), persisted `bootAttemptToken` in `EngineSelectionState`, non-destructive fallback for waiting processes, and crash detection/recovery via OS lock release.
  - Staged runtime inventory: relative path, file size, and SHA-256 for all executable dependencies persisted in `.mpvson-engine.json`; validated before native engine boot, rejecting symlinks or modified files.
  - Regression suite: 40 tests passing in `test/engine_update_service_test.dart`.
- **Track 2: Playback Snapshots & Persistence (Items 17, 18)**:
  - Full-queue decoupling: immutable `QueueSnapshot` with structural revision (`queueRevision`), cached query filtering keyed on `(queueRevision, query)`, and direct unmodifiable list access without copying on reads.
  - Granular transport listenables: added `durationListenable` and `bufferingListenable` alongside `positionListenable`, `queueListenable`, and `transportListenable`. Position ticks update `positionListenable` without incrementing queue revision or triggering queue rebuilds.
  - Offloaded persistence: full session JSON serialization moved outside the UI isolate (`Isolate.run`), save requests coalesced to 1 active + at most 1 pending snapshot, and fast periodic progress writes committed to `progress.json` without touching `session.json`.
  - Regression suites: 20 tests in `test/session_repository_test.dart` and 29 tests in `test/playback_controller_test.dart` passing.
- **Track 3: Thumbnail Subsystem (Items 19, 20, 21)**:
  - Cancellable requests: reference-counted `ThumbnailRequestHandle` with consumer tracking. Disposing or scrolling away releases the handle; dropping to zero consumers aborts queue jobs and interrupts active decoders via `ThumbnailCancellation`.
  - Capture race resolution: stage-specific failure diagnostics (`ThumbnailDiagnosticRecord` with stage markers `configure`, `tracks`, `seek`, `capture`, `decode`), header and decodability validation, and polling deadline handling Windows partial-write races.
  - Bounded decoding: 12 MiB maximum file limit before memory reads, 32 MP pre-decode inspection via `ImageDescriptor.encoded`, artwork normalization to 320x320 preserving aspect ratio, and constrained decode dimensions.
  - Regression suite: 23 tests passing in `test/thumbnail_service_test.dart`.
- **Track 4: UI & Accessibility (Item 23)**:
  - Filtered queue view: rendered with standard `ListView.builder` keyed by `'queue-list-filtered'`, omitting dummy reorder semantics (`Move up`, `Move down`) and drag handles while search filtering is active.
  - Unfiltered queue view: renders with `ReorderableListView.builder`, restoring drag handles with hover transitions and active accessibility reordering.
  - Regression suite: 4 tests passing in `test/queue_panel_accessibility_test.dart`.
- **Release Provenance Hardening (Item 16)**:
  - GitHub Actions pinned to reviewed commit hashes (`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`, `subosito/flutter-action@44ac965b96f18d999802d4b807e3256d5a3f9fa1`, `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02`).
  - Strict dependency lockfile enforcement via `flutter pub get --enforce-lockfile`.
- **Overall Suite Verification**:
  - `flutter analyze`: clean (0 issues).
  - `dart format`: clean across all files.
  - `flutter test`: 257 default unit/widget tests passing (8 opt-in native tests skipped), 0 failures.

## Bundled engine pin and playback-state repair on 2026-10-18

The Windows bundle now replaces the plugin's September 2023 libmpv module with a
pinned upstream engine, and the playback state path was repaired against what the
running engine actually reports.

- Bundled engine: `libmpv mpv v0.41.0-dev-gfffe7a23a` in the release bundle
  (`libmpv-2.dll`, SHA-256 `6602b9026b3b7391ce235feb7d7baa97abbe489d3faa4f859c0c8fc9261c4210`,
  157,906,432 bytes). The pin, its archive digest, the build components it reports and
  the upstream GPL text digest are recorded in `packaging/windows/engine-provenance.json`;
  the Windows configure step verifies them before replacing the plugin module and
  installs the record and `LICENSE.libmpv-GPL.txt` beside the executable.
  Version forms are kept separate: binary `v0.41.0-dev-gfffe7a23a`, release-notes
  `v0.41.0-1206-gfffe7a23a`, updater SemVer `0.41.0-dev.39086651352+gfffe7a23a`.
- `flutter analyze` passes with no issues; the full default suite passes 219 tests
  (8 opt-in native tests skipped). Each repair carries a regression:
  `test/native_event_state_test.dart` and `test/snapshot_emitter_test.dart` for item 24,
  `test/bundled_engine_test.dart` for the pin.
- Windows release smoke on the built bundle (`test-output/smoke-fixed/native-smoke.json`,
  `native-smoke.png`): success with `durationMs` 8000, seek to 1000 ms, pause, visual
  capture, and player and renderer both reporting
  `build\windows\x64\runner\Release\libmpv-2.dll`.
- Opt-in native suites passed with the pinned module: engine activation, invalid-module
  recovery and rollback to the bundle (`test-output/engine-native/run-a797dee6/`),
  three thumbnail tests, and the native source probe.
- Live upstream test (`MPVSON_LIVE_MPV_TEST`) downloaded the currently published
  package through the normal update path — still the exact pinned build — staged it,
  activated it, rendered with fullscreen auto-hide, and rolled back to the bundle
  (`test-output/mpv-upstream-native/run-dee1daf/`). This confirms the pin matches the
  feed that the default engine source serves today.
- The release smoke found a real defect the default suite could not: the run played
  7958 ms of an 8000 ms file while the player reported no duration, then reported
  `Playback engine unavailable: Bad state: Cannot fire new event. Controller is already
  firing an event`. Reading the run's `diagnostics.log` (records `native.observe`,
  `native.event`, `playback.open`, `playback.attached`) showed that the engine announces
  one load with `path` twice and that the second announcement cleared a duration the
  engine never re-notifies, and that the end-of-queue stop published from inside the
  snapshot that reported completion. The failing report is preserved in
  `test-output/smoke-diag/`, the diagnosis trace in `test-output/smoke-trace/`, and the
  sequence is documented in
  [native-source-probe.md](native-source-probe.md#sequence-in-the-running-application-18-oct-2026).
- The same failure reproduced with the previous 2023 module in an A/B run with identical
  binaries (`test-output/ab-old-engine/`), which ruled out the engine swap as its cause.
  The failure is not engine-specific; both engines report `path` twice per load through
  this media_kit version.
- The smoke report now names the state a failed wait observed
  (`duration`, `position`, `playing`, `loading`, `hasMedia`, completion, error, plus the
  engine's own numbers) instead of only the timeout, and the app writes bounded
  diagnostic records during smoke runs so a failure is diagnosable from its artifacts.

Linux is still unverified locally: no Linux host or runner is available in this
workspace, so Linux build and runtime remain CI's responsibility and are not claimed here.

## Queue panel state on 2026-10-18 (plan item 22)

- The queue panel no longer keeps separate compact and wide open flags. One
  `_queueOpen` state and one `_queueMounted` exit-animation tracker drive both
  presentations, so crossing the 1100 px breakpoint neither hides a queue the
  user opened nor resurrects one they closed. The panel keeps one stable key, so
  its search text, focused entry and scroll position survive the presentation
  change, and only one interactive panel is mounted at a time.
- Widget test "one queue open state survives resizing and stays closed"
  (`test/widget_test.dart`) fails before the change on the resize and re-grow
  assertions: it opens the inline panel at 1240 px, filters the queue, crosses to
  720 px and requires the same panel with the same search text and filtered
  result, closes with Escape, verifies the queue stays closed when the window
  grows again, and reopens exactly one panel.
- `flutter analyze` clean; 230 tests pass.

## Stream-URL consent surface on 2026-10-18 (plan item 14)

- Settings → Playback now has "Save network URLs between sessions", off by default,
  with text stating that enabling it stores complete stream URLs (including
  tokens) in the local session files and that switching it off removes stored
  URLs. The toggle drives `PlayerController.setSaveNetworkUrls`, which already
  owned the migration, scrub and persistence rules landed earlier.
- Widget test "stream URL persistence is opt-in and remembered" (in
  `test/widget_test.dart`) fails before the change because the toggle does not
  exist; it asserts the off default, the explanation, that enabling writes
  `saveNetworkUrls: true` through the session repository, that the setting is
  remembered when the dialog is reopened, and that disabling persists `false`.
  A URL stored without consent is not restored at launch.
- `flutter analyze` clean and 229 tests pass with that widget test included.

## Engine-store safety on 2026-10-18 (plan items 11-13)

- `flutter analyze` passes with no issues and the full default suite passes 228 tests
  (8 opt-in native tests skipped), including nine regressions added for these items.
- Item 11: an engine directory is only removed when it carries the updater's
  `.mpvson-engine.json` ownership marker (version and DLL digest). Staging extracts
  and verifies the package in a unique directory first and only then replaces an
  owned, unreferenced directory; an unowned directory now fails the stage attempt
  with an explicit message instead of being deleted before the archive is even
  validated. Regressions: "leaves an unowned engine directory untouched when
  staging" (it fails on the old order, which deleted the directory and then staged
  successfully) and "replaces an owned unreferenced engine directory when staging".
- Item 12: selection recovery validates the records of both the selection file and
  its backup before choosing between them. Regressions: "recovers a usable backup
  when the primary selection is unusable" (the old code accepted the parseable
  primary and returned an empty state, losing the engine),
  "backup recovery never proposes a rejected boot attempt" and "keeps an explicit
  bundled selection during recovery".
- Item 13: a one-sided custom feed (manifest without key, or key without manifest)
  keeps the official mpv source, exposes `configurationWarning` and shows it in the
  update view; a complete but invalid configuration reports its validation error
  through the existing error surface. Regressions: the four "keeps the official
  source…", "uses a complete custom feed…" and "reports an invalid custom feed…"
  tests in `test/engine_update_service_test.dart`.
- Opt-in native suites passed with the pinned engine after these changes: engine
  activation, invalid-module recovery and rollback to the bundle, three thumbnail
  tests and the native source probe
  (`test-output/native-suites-items11-13.log`), plus the release smoke with
  duration 8000 ms, seek, pause and visual capture
  (`test-output/smoke-items11-13/native-smoke.json`).
- Linux remains unverified locally.

## Default mpv source fix on 2026-10-18

Windows engine checks now work without a build-time manifest or signing key.
The default source is the official `mpv-player/mpv` GitHub rolling development
build. The optional custom signed channel remains separate, and application
updates remain unchanged. The engine track appears first in the dialog,
retaining the existing navy/cyan layout and typography. The loaded engine
version is read before opening media.

- `flutter analyze --no-pub` passes without issues, and the full default suite
  passes 129 tests. Two opt-in native checks are skipped in that default run.
- `flutter build windows --release --no-pub` succeeds.
- The live `MPVSON_LIVE_MPV_TEST=true` check used the production default source,
  downloaded the 64,944,819-byte upstream ZIP and verified its GitHub SHA-256,
  `2eae1e9124306eafaee580ffb524239180024eb2f48a502d19e72939429a73fa`.
  It activated `libmpv mpv v0.41.0-dev-g01e2533f3` in an isolated store. Both
  player and renderer used the same versioned DLL. The native version was
  available before opening a video. Playback, seek, pause, fullscreen capture
  and rollback to the bundled engine passed.
- Live metadata, native reports and captures are in
  `test-output/mpv-upstream-native/run-3816ce98/`. This was a real newer engine,
  not a relabeled bundled-engine fixture. It did not change the user's store.
- All 10 update-dialog widget tests pass with real-font captures. The engine
  track is first, identifies its source, and keeps its action reachable at
  720x480 with enlarged text. Captures are in `test-output/engine-updates/`.
- The refreshed portable runtime passed native playback, fullscreen, seek,
  pause and shutdown after extraction. Evidence is in
  `test-output/mpv-source-portable-evidence/`.

These upstream packages are development builds, verified using GitHub's HTTPS
metadata and digest, not signed or certified by Mpvson. The native bridge still
checks the client API and retains clean-process recovery. Linux runtime testing
remains unavailable locally.

## Initial independent engine updates on 2026-10-18

The application and Windows playback engine now have separate update tracks.
Engine manifests use pinned Ed25519 verification, compatibility bounds, ZIP
size/hash checks and extraction preflight. Versioned engine installs activate
after restart. The Update Center offers explicit rollback and discard actions.
Linux keeps its system-managed libmpv.

Validation in this Windows workspace:

- Formatting and `flutter analyze --no-pub` pass without issues.
- `flutter test --no-pub` passes 118 tests. The separate native test is skipped
  by default and was run explicitly with `MPVSON_NATIVE_ENGINE_SMOKE=true`.
- `flutter build windows --release --no-pub` succeeds.
- The native engine test signs the existing tested runtime with a temporary
  test key, downloads it through an injected HTTPS response, stages it in an
  isolated directory and launches the release executable. The player and
  renderer both report that versioned DLL path. An invalid DLL triggers clean
  process recovery to the working engine; explicit rollback then selects the
  bundled DLL. Each launch renders video, seeks to 1,000 ms, pauses and exits.
- Native reports and screenshots for that flow are in
  `test-output/engine-native/run-cf94308a/`. Fixture release labels exercise
  selection and do not claim a newer upstream mpv build. The actual runtime
  remains `libmpv mpv v0.36.0-403-g652a1dd907`.
- Update-dialog screenshots in `test-output/engine-updates/` were inspected.
  Tests cover independent actions, Linux guidance, rollback, scroll access at
  720×480 with 1.5× text, and the application hash/action at 2× text.
- The refreshed portable ZIP was extracted into a new directory and passed
  native playback, matching player/renderer DLL selection, seeking, pause,
  fullscreen controls/cursor hiding and shutdown. Evidence is in
  `test-output/engine-updates-portable-evidence/`.

Windows staging now tolerates temporary sharing/access locks during the final
directory rename with bounded retries. Store mutations use both a process
queue and an OS file lock. Disposal cannot commit a staged selection after
cancellation. No production feed or signing key has been configured, and no
new upstream runtime was downloaded. Local Linux runtime verification remains
unavailable; the Linux CI job is configured but was not run here.

## Release verification and repair pass on 2026-10-16 / 2026-10-17

A comprehensive repair pass by GPT-6 Luna unified playback persistence, interface ergonomics, update lifecycle safeguards, and CI bundle verification:

- **Playback & persistence**:
  - Immediate queue edits with synchronized native and session state.
  - Transition coalescing and state suppression across the source-start boundary to eliminate duplicate or jittery position/status broadcasts.
  - Absolute local path canonicalization and resolution.
  - Comprehensive error handling reset upon each new playback attempt.
  - Typed persistence failures via `SessionSaveException` with graceful shutdown and discard fallback options.
  - Recent history recording gated on verified playback start only (preventing unplayable or failed media from polluting recents).
- **Interface & usability**:
  - Context menu dismissal & hit-testing repairs: Decoupled `MenuAnchor` from the video stage so that only the menu popup belongs to the `TapRegion`. Left-clicking on the video dismisses the menu without toggling playback. Clicking "Resume video" / "Continue at..." or anywhere in `MediaReady` dismisses the menu. Clicking anywhere outside the menu popup dismisses the menu. Pressing Escape dismisses the menu without closing fullscreen or the compact drawer. Mouse wheel scrolling over the video dismisses the menu. Window blur, resize, queue toggling, and action triggers cleanly dismiss the menu. Right-clicking another point on the video repositions the menu.
  - Settings Appearance preview remains fully responsive and scaled at compact 720×480 with an accessible, non-overflowing footer.
  - Queue header flexible sizing adapts cleanly to 150% text scaling without layout overflow.
  - Escape key dismisses the compact queue drawer even when the search text field has focus before exiting fullscreen.
  - Stable identity tracking (`MediaEntry.id`) for accurate queue deletions, reorders, and undo restoration.
  - Accessibility semantics for queue items, active speed, audio track, and subtitle track selection states.
  - Timeline and volume sliders consume arrow keys to avoid conflicting global playback shortcuts during active scrubbing.
- **Updates & packaging**:
  - Abortable HTTP requests with active cancellation triggers; `.part` partial downloads are cleaned up immediately on error, cancellation, timeout, or service disposal.
  - Verified bundle reuse and tracking via updater ownership records (`updates.json`) storing version, digest, filename, file size, and timestamp.
  - Two-archive retention policy (current + previous) with safe pruning restricted strictly to verified, tracked, and unchanged archives.
  - Manifest generation CLI (`tool/create_release_manifest.dart`) enforces collision prevention (resolving symbolic links, junction points, and aliases) and atomic file writes via temporary swap files.
  - CI workflow (`.github/workflows/desktop.yml`) packages release bundles (`dist/mpvson-windows-x64.zip` and `dist/mpvson-linux-x64.tar.gz`) with engine provenance and inventory verification prior to publishing artifacts.
  - Documented optional Linux launcher and scalable SVG icon installation in `packaging/linux/README.md` and `README.md`.
- **Test suite & engine verification**:
  - All 72 unit, widget, and update tests in the test suite pass deterministically.
  - Flutter analysis passed with zero issues (`flutter analyze`).
  - Native playback engine verified on target `windows-x64` using `libmpv mpv v0.36.0-403-g652a1dd907`.
  - Both native release build runner and freshly extracted portable ZIP verified with native playback, seek to 1000ms, pause, fullscreen controls auto-hide (rendered opacity 0, cursor hidden), and clean shutdown.
  - SHA-256 digest of `dist/mpvson-windows-x64.zip`: `589800be5fb18901df9561753380c6da61bce4d0e9a9334263815c75017a551b`.
- **Unresolved platform coverage**:
  - Linux runtime verification remains pending runner execution because no Linux host, WSL distribution, Docker container, or hosted Linux runner is currently available. Do not claim Linux runtime playback has been verified.

## Compact and Normal controls on 2026-10-16

Settings now opens on Appearance with a Compact/Normal selector and a layout preview. Compact is the default for new and legacy sessions. It uses a 60px bottom strip, 32px buttons, a 4px seek rail and 8px edge margins. Normal retains the 96px strip and 44px buttons. Switching applies immediately without changing playback, and the session repository remembers the choice.

- All 47 tests passed. New checks cover both modes at 720×480 and 1240×780, live switching during playback, real button/strip measurements, seeking, queue removal/undo, 150% text sizing, legacy/malformed saved data and restart persistence.
- Settings previews were reviewed in both modes and window sizes. The minimum-height preview fits above the footer; enlarged text stacks the selector and permits scrolling. The docked queue footer now wraps its actions instead of overflowing.
- Flutter analysis passed with no issues. Formatting and the Windows release build passed.
- The release and freshly extracted portable bundle passed native rendering, seek, pause, fullscreen auto-hide and shutdown checks. Evidence is in `test-output/control-density-native` and `test-output/control-density-portable-evidence`. UI previews are the `density-*` images in `test-output/desktop-ux`.

The root shortcut uses this build, and the ZIP, checksum and build-info file are refreshed. Design and state details are in [control-density.md](control-density.md). Linux runtime testing remains pending.

## Desktop interactions on 2026-10-16

The player retains one bottom control area and a continuous seek rail, with no application header. Video wheel input now adjusts volume in five-point steps and shows brief feedback. Right-click opens playback, speed, audio, subtitle, volume and file actions. Fullscreen playback hides the controls and cursor configuration after two seconds of inactivity, including when the pointer stays over the bar. Mouse movement restores controls; keyboard focus, menus, dialogs and active dragging keep them available.

- All 41 tests passed. Coverage includes wheel routing and touchpad accumulation, volume bounds, delayed native writes, mute restoration, menu placement at 720×480 and 1240×780, subtitle picker dispatch, click/double-click behavior, text input, fullscreen hiding, cursor hit testing, focus and drag guards.
- Flutter analysis passed with no issues, all source/test/tool formatting passed unchanged, and the Windows release build succeeded.
- The built player passed native video rendering, seeking, pause, fullscreen entry/exit, shutdown, and visual capture checks. The fullscreen check waits for the rendered opacity to reach zero before capture. The resulting image was inspected and contains no control bar.
- The refreshed portable ZIP was extracted into a fresh directory and passed the same native fullscreen/playback check.
- UI captures are in `test-output/desktop-ux`. Final native evidence is in `test-output/desktop-ux-native-rendered` and `test-output/desktop-ux-portable-evidence`. Earlier native captures taken before the fade settled are superseded.

The root shortcut targets the rebuilt player. The ZIP, SHA-256 sidecar and build-info file contain this release. Interaction choices and primary research sources are recorded in [desktop-ux.md](desktop-ux.md). Native checks verify cursor configuration and widget tests verify cursor hit testing; they do not establish every OS/accessibility interaction. Linux runtime validation remains pending.

## Minimal player controls on 2026-10-16

Removed the application header. Playback now fills the area below the native title bar, with a continuous 3px seek rail and one bottom control row. Open, recent-file, queue, settings and fullscreen actions are available from the bottom. Hovering previews the target timestamp; dragging updates the elapsed readout and seeks on release.

- All 31 tests passed, including full-height playback at 720×480 and 1240×780, hover preview without seeking, preview clamping at both timeline ends, drag-release seeking, menu actions, and existing keyboard/queue/update checks.
- Flutter analysis passed with no issues, formatting passed unchanged, and the Windows release build succeeded.
- The rebuilt executable and refreshed portable ZIP each passed native rendering, seek, pause and shutdown checks using isolated sessions.
- UI captures are in `test-output/minimal-player`. Native playback evidence is in `test-output/minimal-player-native` and `test-output/minimal-player-portable-evidence`.

The rebuilt executable and the portable ZIP were used for verification. The SHA-256 sidecar and build-info file were rebuilt with the package. Linux verification remains pending.

## Interface refresh on 2026-10-15

This refresh introduced redesigned home and restored-media screens, a slim header, edge-aligned playback controls, a queue that starts closed, and tabbed settings. The October 16 refinement above removes that header. The existing navy/cyan palette and native desktop playback remain in use. Design decisions are recorded in [ui-design.md](ui-design.md).

- `flutter analyze --no-pub` passed with no issues.
- `flutter test --no-pub --dart-define=MPVSON_CAPTURE_UI=true` passed all 31 tests. New UI checks cover both window sizes, URL validation and opening, seeking, pending volume changes followed by mute, speed-menu visibility during playback, control auto-hide, and queue removal/undo/search.
- `dart format --output=none --set-exit-if-changed lib test tool` passed without changes.
- `flutter build windows --release --no-pub` succeeded.
- The rebuilt executable and a fresh extraction of the updated portable ZIP both rendered a real local video, sought to 1000 ms, paused, captured the native video/UI, and shut down successfully using isolated sessions.
- Home, restored state, playback, queue, URL and settings screenshots were inspected at 720×480 and 1240×780. This review corrected button font fallback, tab dividers, and toast placement that covered the queue's Undo action.

Current evidence is in `test-output/ui-refresh`, `test-output/ui-refresh-native`, and `test-output/ui-refresh-portable-evidence` (not committed). The portable ZIP, its SHA-256 sidecar and `build-info.json` were rebuilt from the verified executable. The Linux and broader device/OS verification limits below still apply.

## Completed

- The earlier mpv customization sources were archived outside this repository before the rewrite. Retained media and the old Settings release bundle remain in that archive.
- Flutter Windows release compilation succeeded with the C++ desktop runner and bundled native playback libraries.
- `flutter analyze --no-pub` passed with no issues.
- `flutter test --no-pub` passed all 27 tests. These cover queue identity/reorder/remove/undo, repeat, synchronous stream state, stopped restore and resume, interrupted session recovery, concurrent repository writes, version/manifest parsing, download integrity/redirect checks, responsive UI/search/recents/settings flows, and restoring playback speed when a held shortcut loses window or text focus.
- The real Windows executable loaded and rendered a local video, reported the mpv engine version, sought to 1000 ms, paused, saved its isolated session, captured its video/UI, and released playback services.
- The packaged Windows ZIP was extracted into a fresh directory and passed the same real native playback check without relying on the build directory.

Engine tested: `libmpv mpv v0.36.0-403-g652a1dd907`, supplied by the locked media_kit Windows runtime dependency. Native rendering logged hardware-accelerated video output. This is not a claim that HDR or hardware decoding has been tested on every GPU.

Evidence:

- `test-output/verified-windows/native-smoke.json` and `native-smoke.png`.
- `test-output/verified-portable/native-smoke.json` and `native-smoke.png`.
- `dist/build-info.json`, `dist/mpvson-windows-x64.zip`, and its SHA-256 sidecar, now refreshed by the interface verification above.

## Still pending

- Linux compilation and runtime validation. The Linux runner, desktop integration assets and CI job exist, but no Linux host, WSL distribution, Docker runtime or hosted CI repository was available during this verification. Do not describe Linux as tested.
- A hosted application update manifest and publicly published application releases. Application packages still use a separately configured feed and manual installation. The Windows mpv engine uses the default official upstream GitHub build source described above; it does not depend on an application feed.
- Full codec/GPU/HDR, accessibility-tool, multi-monitor, native file-dialog and drag/drop end-to-end coverage. Existing source, native plugins and widget checks support these controls, but do not prove every OS/device interaction.

The application currently has a working Windows release. The cross-platform release goal remains open until Linux has been built and exercised on a Linux runner.
