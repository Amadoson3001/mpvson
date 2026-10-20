# Code quality review and repair record

Reviewed and repaired on 18 October 2026, starting from `bfe9ea6`, with a parallel audit follow-up on 20 October 2026.

My assessment of the reviewed implementation is **8.5/10**. The application has a sound Flutter desktop foundation and meaningful regression coverage. This pass fixes the remaining confirmed review defects. Linux runtime checks, frame-time profiling, long-running native resource measurements and further decomposition of the large controller/repository still separate it from a defensible top rating.

## Repairs implemented

| Area | Result | Regression evidence |
|---|---|---|
| URL privacy | Startup migration awaits cleanup of primary, backup and checkpoint files. URL-shaped checkpoint IDs are removed even beside a clean session. Opt-out drains older writes before scrubbing, retains local resume progress and restarts periodic checkpoints. Rapid consent changes preserve the latest choice. | Controller and session tests, including active/queued write and rapid consent races |
| Diagnostic privacy | Embedded HTTP(S) URLs lose credentials, query and fragment before truncation, including punctuation-adjacent and malformed URLs. Thumbnail diagnostics apply the same redaction. | Media-source and diagnostic-log tests |
| Queue correctness | Search caches store matching indices, materialize current entry values and retain at most 32 queries. | Stale-duration/progress and 10,000-entry cache tests |
| Queue performance | Position-only ticks notify timeline listeners without rebuilding the whole player. The queue widget stays stable, with separate current-row transport updates. | Real PlayerScreen regression counts filtering across ticks, pause/play and metadata changes |
| Native fullscreen | Overlapping state reads are coalesced and a trailing read reconciles resize notifications that precede the OS fullscreen flag. | Delayed-platform widget regression for hidden controls and cursor; extracted-package smoke runs |
| Shutdown persistence | Close waits for active and coalesced controller/repository writes, including the newest checkpoint. | Gated-save and checkpoint-drain tests |
| Engine commit safety | Failed cleanup reacquires the store lock, checks the unique attempt and refuses to delete current/backup referenced installs. Pending rollback state survives rejection. | Same-version retry race and rollback tests |
| Engine cancellation | Cooperative cancellation checks preflight, output and hashing, closes file streams and awaits worker exit before deleting staging. | Cancellation with immediate directory cleanup on Windows |
| Stale staging | Owned attempts use OS leases and a same-process active set. Sweeping skips live, foreign and linked paths. ZIPs cannot overwrite updater controls. | Interrupted/live/unowned stage and reserved-path tests |
| Runtime integrity | Inventory validation rejects malformed/mismatched entries while accepting existing Windows path separators. Startup hashes the main library once per validation and checks its inventory digest against the selection record. | Nested-dependency, tampering, rewritten-marker and malformed-inventory tests |
| Thumbnail lifecycle | An old cancelled load cannot remove its replacement. Disposal drains output cleanup, and active cancellation waits for decoder teardown before deleting output. | Same-key replacement and delayed-teardown tests |
| Thumbnail limits | Legacy disk cache hits are normalized to the same limits as new artwork. Native capture uses the production poll helper tested for partial writes, cancellation, timeout and size bounds. | Cache normalization and production-poller tests; native runs |
| Native observation | Playback retains and disposes its internally created event adapter. Empty/malformed track lists and non-finite duration cannot confirm a load. | Property interpretation tests and native release smoke |
| Maintainer downloads | HTTPS GitHub redirects, exact size, incremental hash, backpressure and timeouts are enforced before a private candidate replaces the cache. | Overflow, short body, hash, redirect, timeout and prior-cache preservation tests |
| CI | Both desktop jobs generate native-thumbnail fixtures and run those tests. Windows verifies fullscreen behavior. Packages include checksum files; Windows also includes the generated engine inventory. | Workflow changes; local Windows verification below |

## Verification

The complete local results and artifact paths are recorded at the top of [verification.md](verification.md). The default suite passes 300 tests, with eight opt-in native tests skipped in that command and exercised separately where noted. Twenty separate cold thumbnail test processes passed.

The final Windows release build passed. Five native fullscreen checks passed from the extracted portable ZIP, including rendering, seek/pause and actual control opacity. Native engine activation, invalid-engine recovery and bundled rollback also passed. The portable build and its SHA-256 file are in `dist/`; no package was published.

## Parallel audit repairs on 20 October 2026

A second pass split playback/persistence, queue-thumbnail and engine-update work across three parallel repair streams, then verified every change sequentially on Windows.

| Area | Result | Regression evidence |
|---|---|---|
| Restored progress | Startup publishes the restored queue before engine settings writes. Synchronous volume/rate/shuffle snapshots can no longer reset a stopped item's saved position and duration to zero. | Restored stopped-session position/duration test |
| Resume races | A failed resume seek retains the saved resume floor; callbacks are generation-guarded against superseding user seeks. | Failed-resume and newer-seek controller tests |
| Shutdown and discard | Close checkpoints then drains saves; a failed save keeps the controller open and throws `SessionSaveException`; discard retries release; joined discard callers wait for engine teardown. | Failed-save, flush-failure and joined-discard tests |
| Transport timers | Buffering and progress-timer state are refreshed from the published transport, including pending transitions and queue resets. | Buffering/listenable and checkpoint-cadence tests |
| Malformed persistence | Non-finite version, position and duration values are rejected or clamped instead of causing overflow or invalid sessions. | Session-repository non-finite tests |
| Malformed input | Unparseable HTTP(S) sources are rejected with redacted diagnostics; invalid percent-encoded titles retain a usable raw segment. | Media-source and media-entry tests |
| Engine staging | Marker-only crash residue is swept without touching live, foreign, linked or unowned staging directories. | Marker-only sweep regression in the engine suite |
| Thumbnail polling | Transient output-stat and directory-listing failures are retried within the polling deadline. | Poller transient-filesystem tests |
| Thumbnail layout | Fit-preserving decode plus a filled content area keeps non-16:9 artwork from stretching. | Real `PlayerScreen` thumbnail layout widget test |

The opt-in playback-service probe also needed a harness correction rather than a product change: a plain `test()` never pumps the Flutter frame that initializes an attached `VideoController`, and `flutter test` has no texture channel, so its native commands waited forever. The probe now releases that gate and, with `vo=null`, completes `prepare()`/`open()` and records native source attribution.

Current local results: formatting passed across 78 Dart files, `flutter analyze --no-pub` reported no issues, the default suite passed 343 tests with 9 opt-in tests skipped, all nine opt-in tests were then exercised and passed, the playback-service probe attributed the first opened source to boundary 1, the Windows release build passed, native engine activation/recovery/rollback passed in 1m36s, the live upstream test downloaded and activated `0.41.0-dev.39135297726+g6a262d11f` and rolled back to the bundled engine, and engine provenance/verification passed for `v0.41.0-dev-gfffe7a23a`. The release executable also passed native rendering, seek to 1041 ms, pause, native fullscreen and hidden-controls/cursor checks. Logs are under `test-output/*20261020*`; fullscreen evidence is in `test-output/native-smoke-20261020/`. Linux remains an unexecuted local gate.

## Remaining work and acceptance criteria

| Priority | Work | Required evidence |
|---|---|---|
| P1 release gate | Run the Linux CI build and extracted-package playback/thumbnail checks. No Linux host is available locally and this repository has no configured remote. | A successful Ubuntu job with native playback reports and package artifacts |
| P2 performance | Profile a 10,000-item queue in a release/profile build while scrolling, searching and playing media. Unit operation counts do not establish FPS. | Recorded hardware and p95 UI/raster times below 16.7 ms at 60 Hz |
| P2 native lifecycle | Repeated open/seek/next/close, thumbnail cancellation and update cycles over a long run. The adapter still infers load identity through properties rather than raw native event IDs. | Stable player/handle counts, no sustained RSS growth and rapid duplicate-source transition coverage |
| P2 shutdown bound | A native `Player.dispose()` that never settles can keep thumbnail disposal pending. Waiting protects output cleanup; a hard bound requires owning the decoder in a separate native process. | Fault-injected stuck native worker terminated without leaving files or live players |
| P2 memory | Extend the measured file-backed archive case to compressed/pathological fixtures and real upstream packages. One sampled run is not a bound for every accepted 512 MiB package. | Repeated measurements below the 128 MiB additional-working-memory target on recorded reference machines |
| P1 public release gate | Review licenses, corresponding source/build instructions, native advisories and signing before publishing or enabling a public application feed. | Reviewed dependency/source inventory and independently validated signed release artifacts |
| P3 maintainability | Extract archive-worker and stage-attempt coordination from the large engine repository, and queue projection logic from the controller when those areas next change. | Smaller cohesive modules with current regression behavior preserved |

No exploitability assessment of every native dependency, production signing review or Linux certification is implied by passing the local tests. The legacy archive was left untouched.
