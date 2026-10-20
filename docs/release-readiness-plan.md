# Mpvson release-readiness repair plan

This plan records the release-readiness repair list so it stays auditable alongside the implementation.
See `docs/implementation-contract.md` for the shared contracts that implement these items.

## 1. Summary and current baseline

Prioritize lost progress, playback failures, security exposure and recovery first, followed by performance and desktop usability. Preserve Flutter, media_kit/libmpv, MVVM, the native title bar and the existing dark bluish theme.

The audit established this baseline:

| Check | Result |
|---|---|
| Flutter analysis | Passed without issues |
| Default tests | 142 passed; five opt-in tests skipped |
| Windows release build | Passed |
| Native Windows playback and fullscreen | Passed |
| Native engine activation, failure recovery and rollback | Passed |
| Native thumbnail tests | First run had one failure; isolated and complete reruns passed |
| Linux build and runtime | Unverified locally |

Passing checks do not cover several timing, recovery and large-queue problems found in the code. The repairs below distinguish confirmed code defects from risks requiring further reproduction. No specific exploitable CVE was verified against the shipped binaries.

## 2. Priority repairs

### A. Playback, progress and shutdown

1. **P1. Prevent queue edits from stranding playback in a loading state.**
   Appending, reordering or removing another item can invalidate an unfinished open without starting a replacement. The original operation then returns without clearing loading. Separate playback-operation identity from queue revisions, and track the opening item by its stable ID. Queue-only edits must preserve its pending open. Cover undo and cancelled shutdown too. Evidence starts in [player_controller.dart](../lib/ui/player/player_controller.dart).

2. **P1. Make source transitions reject stale playback events.**
   The production adapter stamps callbacks with the current source counter, so an old callback can appear to belong to the new file. Add a narrow, repository-owned media_kit extension that exposes native start, loaded and end events with source identity. Assign identity when native events enter Dart, gate progress until the source is loaded, and use native entry identity for completion. Duplicate URLs must remain distinct queue items.

3. **P1. Preserve resume progress until seeking succeeds.**
   The pending resume target is cleared before its asynchronous seek finishes. Initial engine position zero can then overwrite saved progress. Keep the target authoritative until seek confirmation, and preserve it if saving or closing occurs first. Seeking a restored, stopped item must update its saved position directly.

4. **P1. Recover structurally invalid sessions from backup.**
   Valid JSON with an invalid structure can currently become an empty session and bypass a good backup. Validate the session version and required collection types before accepting the primary. Preserve recoverable rows, normalize invalid numeric fields, and try the backup when the root structure is unusable.

5. **P1. Make closing a bounded, consistent operation.**
   Some queue commands remain available after the closing snapshot is taken. Session locking can also wait indefinitely, and repeated window-close requests can open overlapping save-error prompts. Introduce explicit running, saving, awaiting-decision and releasing states. Reject mutations during saving, allow one prompt, and restore a usable controller after Cancel. Replace blocking session-lock acquisition with nonblocking retries and a five-second deadline.

6. **P2. Remove engine-version lookup from file-opening latency.**
   Opening each source currently awaits a version lookup that can take three seconds. Read and cache the version once during bootstrap. Playback readiness must not depend on optional metadata.

7. **P2. Validate source input consistently.**
   Unsupported URI schemes arriving through command-line arguments can become misleading local paths. Centralize validation for command line, drag and drop, dialogs and restored sessions. Continue supporting local files, file URIs and HTTP(S); report unsupported schemes explicitly.

### B. Updates, native dependencies and stored data

8. **P1 release blocker. Replace the obsolete bundled fallback engine.**
   The verified bundle still contains the September 2023 mpv build. Move the fallback to a complete, tested package based on the supported stable release, currently v0.41.0, with pinned artifact hashes and dependency provenance. mpv states that older releases do not receive upstream security patches. [mpv security policy](https://github.com/mpv-player/mpv/blob/master/SECURITY.md)

   Inventory the included FFmpeg, libass, ANGLE and other native components. Check applicable advisories against their actual versions and build options. Treat age as a maintenance risk; establish affected versions before assigning CVEs. [FFmpeg security notices](https://ffmpeg.org/security.html)

9. **P1. Bound engine-update memory and keep extraction off the UI isolate.**
   Downloads are materialized in memory, then read again for extraction. Extracted entries remain cached, allowing accepted packages to approach 2 GiB of expanded memory plus ZIP buffers. Stream downloads to a private file while hashing, preflight from disk, and extract entries incrementally in a worker isolate. Retain existing signature, digest, size, path and archive-type checks.

10. **P2. Protect live engine boot attempts across processes.**
    A second launch can interpret another process's active boot marker as a crashed attempt. Hold a separate OS-backed boot lease from selection through confirmation or rejection. Persist a random attempt token and require it when committing a result. A waiting process must never clear another live attempt. Crashes release the OS lease and retain existing fallback behavior.

11. **P2. Stop deleting unowned engine directories.**
    Staging can delete an existing unreferenced version directory before validating the replacement archive. Fail safely when the target already exists unless durable updater ownership metadata authorizes cleanup. Stage into a unique directory and commit only after verification. Evidence is in [engine_installation_repository.dart](../lib/data/repositories/engine_installation_repository.dart).

12. **P2. Repair engine-selection backup recovery.**
    A parseable selection whose files fail validation can skip a usable backup. Validate candidates before choosing the recovered state. Preserve explicit bundled selections and rejected-boot information so backup recovery cannot resurrect an engine already rejected during startup.

13. **P2. Handle incomplete custom-feed configuration explicitly.**
    Configuring only the custom manifest or its key currently disables the official default. Select the custom source only when both are present. A one-sided configuration should retain the official Windows source and expose a configuration warning. A complete but invalid custom configuration should report its validation error.

14. **P2. Make stream-URL persistence opt-in, as requested.**
    Add "Save network URLs between sessions," disabled by default. Without consent, keep stream URLs in memory and omit them from saved queue/history. Explain that enabling the setting stores complete URLs, including possible tokens, in local session files. Migration and disabling the setting must scrub application-owned primary, backup and checkpoint files while retaining local-file history.

15. **P2 hardening. Verify complete staged runtime contents.**
    The package digest covers all files during download, but later boot checks hash only the main DLL. Persist a relative-path inventory with sizes and SHA-256 hashes for executable dependencies. Verify required files before native loading, reject links or changed dependencies, and preserve the single-module player/renderer binding.

16. **P2 release hardening. Strengthen release provenance.**
    Pin CI actions to reviewed commits, enforce the dependency lockfile, and use SHA-256 verification for native build inputs. Produce dependency inventories, checksums, licenses and corresponding source/build information with each package. Preserve the documented distinction between GitHub metadata verification, custom engine signatures and the unsigned application feed. Require a separately reviewed signing configuration before enabling a public application feed.

### C. Performance, thumbnails and desktop UI

17. **P2. Remove full-queue work from playback ticks.**
    Queue getters copy the list, and the queue panel rebuilds its complete filtered projection during playback notifications. Publish an immutable queue snapshot with a structural revision. Cache filtering by revision and query, and give position, transport state and queue changes separate listenable updates.

18. **P2. Reduce persistence work without losing progress durability.**
    Playback currently triggers full-session encoding and flushed writes approximately every two seconds. Keep a small atomic progress checkpoint at that interval. Write the complete queue after structural/settings changes and orderly close. Coalesce saves to one active operation and one latest pending snapshot; perform large JSON encoding outside the UI isolate.

19. **P2. Cancel obsolete thumbnail requests.**
    Rows start work when built, but scrolling away or closing the queue does not cancel it. Return reference-counted request handles, release them on row disposal, and remove requests with no remaining consumers. Prioritize visible rows, retain shared requests still in use, and interrupt an active decoder when nobody needs its result.

20. **P2. Resolve intermittent native thumbnail capture.**
    Ordinary frame extraction failed once and passed both reruns. Its cause remains unresolved. The extractor can read the first nonempty output file before writing finishes. Add stage-specific failure diagnostics and wait for a complete, decodable image within the existing deadline. Test deliberately partial image writes and cold decoder startup. The capture path is in [thumbnail_service.dart](../lib/data/services/thumbnail_service.dart).

21. **P2. Bound thumbnail decoding before allocation.**
    Apply a 12 MiB extracted-file limit before reading, inspect dimensions before decoding, and reject artwork above 32 megapixels. Scale native output before writing where supported. Normalize all returned artwork, including sidecars, to fit within 320x320 pixels while preserving aspect ratio. Set display decode dimensions so compressed-cache limits also produce bounded image memory.

22. **P2. Preserve queue state across resizing.**
    Separate compact and wide open flags make the queue disappear across the 1100-pixel breakpoint. Use one logical open state and preserve search, focused entry and scroll position while changing presentation. Mount one interactive queue panel at a time. Explicit close must remain closed after resizing.

23. **P2. Remove ineffective accessibility actions.**
    Filtered results hide drag handles but still expose reorder semantics backed by a no-op callback. Render filtered results with a regular lazy list. Restore working drag and semantic reordering when the filter is cleared, with explicit upward and downward movement tests.

24. **P1. Keep the engine's duration and survive a re-entrant publish.**
    The Windows smoke run played a file to 7958 ms of 8000 ms while the player
    reported no duration and then failed with
    `Playback engine unavailable: Bad state: Cannot fire new event. Controller is
    already firing an event`. Two causes, both found by reading the run's
    `diagnostics.log`: the engine announces one load with `path` twice, and the
    second announcement cleared the snapshot's duration, which the engine never
    re-notifies because the value did not change; and reaching the end of the queue
    stopped the engine from inside the snapshot that reported completion, publishing
    into the same synchronous broadcast controller. A started event must keep the
    engine's duration, and snapshots must be delivered through a re-entrancy-safe
    emitter. Evidence is recorded in
    [native-source-probe.md](native-source-probe.md#sequence-in-the-running-application-18-oct-2026).

25. **P2. Stop the sandbox cleanup from failing passing tests.**
    `test/playback_controller_test.dart` failed intermittently in its `tearDown`
    with `FileSystemException: Deletion failed ... OS Error: The directory is not
    empty, errno = 145` (reproduced once in six runs, error preserved in
    `test-output/controller-test-failure.log`): a coalesced session or progress
    checkpoint write recreated a file while Windows walked the tree for the
    recursive delete. The cleanup now retries that race briefly; eight consecutive
    runs pass.

## 3. Interface and migration decisions

- Keep widgets free of filesystem, update and playback operations.
- Extend playback snapshots with native source identity and loaded state. Keep queue revision independent of source identity.
- Add a controller closing-state notification so controls can reflect shutdown state.
- Introduce a cancellable thumbnail request handle containing its result future and release method.
- Extend boot selection with an attempt token and owned lease. Confirmation and rejection require that token.
- Introduce session schema version 2 for URL consent and revisioned progress checkpoints. Read and migrate version 1; reject unsupported future versions safely.
- Give staged engines a versioned ownership and file-inventory record. Revalidate existing installs before creating that record.
- Keep application installation manual, Windows engine activation restart-only, and Linux engines managed by the distribution.
- Use bounded local diagnostic records with source IDs and failure stages. Redact credentials, URL query strings and fragments; add no external telemetry.

## 4. Verification and release acceptance

Each repair starts with a regression that demonstrates its failure condition.

| Area | Required scenarios |
|---|---|
| Playback races | Delayed open combined with append, reorder, removal, undo, replacement, close failure and Cancel |
| Source identity | Old progress/completion after a new start, duplicate URLs, rapid next/previous, failed loading |
| Progress recovery | Delayed resume seek followed by save/close, stopped-item seek, interrupted checkpoint replacement |
| Session recovery | Wrong-type primary fields, unsupported versions, malformed rows, overflowing numbers, valid backup |
| Shutdown | Held lock, failed save, repeated close, Retry, Cancel and close without saving |
| Updates | Concurrent launches, crashed lease owner, mismatched attempt token, corrupt dependency, safe fallback |
| Archive safety | Traversal, links, case collisions, excessive entries, high expansion, cancellation and insufficient disk space |
| URL privacy | Default omission, explicit opt-in, migration and removal from owned backups/checkpoints |
| Thumbnails | Partial writes, cold startup, oversized artwork, cancellation, duplicate consumers and playback isolation |
| Desktop UI | Resize through 1100 pixels, both densities, 720x480 and 1240x780, text scaling, keyboard and screen-reader actions |

Performance acceptance:

- Profile 100, 1,000 and 10,000-item queues.
- Position updates perform no full queue copy, filtering or full-session serialization.
- Queue scrolling targets 60 Hz, with 95th-percentile UI and raster frame times below 16.7 ms on the recorded reference machine.
- Engine staging uses less than 128 MiB of additional working memory for a large streamed fixture.
- Twenty cold-process thumbnail runs complete without unexplained failures.
- Repeated open, close, seek, queue and update-cancellation cycles show no retained-player or steadily growing memory trend.

Release gates:

- Pass analysis, all unit/widget tests and the relevant opt-in native tests.
- Build Windows release and test a freshly extracted package.
- Build and exercise Linux in CI against its system runtime.
- Add generated thumbnail fixtures and native thumbnail checks to CI.
- Exercise native dialogs, drag and drop, Unicode paths, subtitles, audio-only media, damaged files, network interruption, DPI changes and multiple monitors.
- Record codec/GPU/HDR results only for configurations actually tested.

## 5. Delivery order and ownership

1. Create a recoverable source baseline before implementation. This checkout currently has no Git metadata.
2. Land playback, session recovery and shutdown repairs first.
3. Land update resource limits, boot coordination, URL privacy and native-package hardening.
4. Land queue performance, thumbnail and accessibility repairs.
5. Refresh the bundled runtime, validate extracted packages and complete Windows/Linux release evidence.

Use disjoint playback/persistence, updates/security and UI/thumbnail ownership for delegated implementation. The primary agent owns shared interfaces, dependency changes, native integration, CI and review. Run Flutter commands sequentially.

Do not publish packages or enable production feeds during these repairs. Linux readiness remains an open release gate until its build and runtime checks have actually passed.

## 6. Repair status

| # | Item | Status |
|---|---|---|
| 1 | Queue edits must not strand a loading state | Landed in `5dfba9e` |
| 2 | Source transitions reject stale playback events | Landed in `5dfba9e` |
| 3 | Resume progress held until seek succeeds | Landed in `5dfba9e` |
| 4 | Structurally invalid sessions recover from backup | Landed in `5dfba9e` |
| 5 | Bounded, consistent close | Landed in `5dfba9e` |
| 6 | No engine-version lookup on the open path | Landed in `5dfba9e` |
| 7 | Consistent source validation | Landed in `5dfba9e` |
| 8 | Replace the 2023 fallback engine | Landed: pinned upstream libmpv (binary `v0.41.0-dev-gfffe7a23a`) with digests, provenance record and GPL text; upstream publishes no stable Windows libmpv, so the rolling build is pinned and the residual risk is documented in [updates.md](updates.md#bundled-playback-engine) |
| 9 | Bounded update memory, extraction off the UI isolate | Streaming and worker extraction implemented with input limits and regression coverage. The less-than-128-MiB additional-memory target still requires a process-memory measurement. |
| 10 | Cross-process boot lease and attempt token | Landed: OS file lease (`.engine-boot.lease`), persisted boot attempt token, waiting process non-destructive fallback, crash detection and recovery |
| 11 | Stop deleting unowned engine directories | Landed: `.mpvson-engine.json` ownership marker authorizes cleanup, stage-then-commit order, regressions in `test/engine_update_service_test.dart` |
| 12 | Engine-selection backup recovery | Landed: candidates validated before choosing, bundled and interrupted-boot decisions win, no pending install recovered; regressions in `test/engine_update_service_test.dart` |
| 13 | Incomplete custom-feed configuration | Landed: one-sided configuration keeps the official source and warns, a complete invalid configuration reports its validation error; update-view surface plus regressions |
| 14 | Opt-in stream-URL persistence | Landed: Settings → Playback toggle (off by default) with the storage explanation, persisted through the session file; widget test covers default, persistence, and the remembered state |
| 15 | Verify complete staged runtime contents | Landed: relative-path inventory with sizes and SHA-256 for all executable dependencies in `.mpvson-engine.json`, pre-boot verification before native loading |
| 16 | Release provenance hardening | CI action pins, enforced lockfile and CMake input verification implemented. Public-release signing, complete corresponding-source/license review and Linux package evidence remain release gates. |
| 17 | No full-queue work on playback ticks | Landed: immutable `QueueSnapshot` with structural revision, cached query filtering, granular listenables (`positionListenable`, `durationListenable`, `bufferingListenable`) |
| 18 | Cheaper persistence, encodes off the UI isolate | Landed: full-session JSON encoding via `Isolate.run`, save coalescing (1 active + 1 pending), atomic progress checkpoints at ~2s without touching `session.json` |
| 19 | Cancel obsolete thumbnail requests | Landed: reference-counted `ThumbnailRequestHandle`, automatic cancellation and queue removal when consumers release |
| 20 | Intermittent native thumbnail capture | Complete-image polling and stage diagnostics implemented. Production-helper regressions, three native tests and twenty separate cold frame-extraction processes passed in the follow-up review. |
| 21 | Bound thumbnail decoding before allocation | Landed: 12 MiB file limit, 32 MP pre-decode inspection rejection, 320x320 aspect ratio normalization, bounded decode dimensions |
| 22 | Queue state survives resizing | Landed: one `_queueOpen`/`_queueMounted` state for both presentations, a stable panel key keeps search/focus/scroll across the breakpoint; widget test covers resizing and explicit close |
| 23 | Remove ineffective accessibility actions | Landed: filtered search results render with `ListView.builder` without dummy reorder semantics/drag handles; full drag and semantic reordering restored when cleared |
| 24 | Engine duration kept, re-entrant publish survives | Landed with regressions `test/native_event_state_test.dart`, `test/snapshot_emitter_test.dart` |
| 25 | Sandbox cleanup cannot fail passing tests | Close now drains active/pending controller and repository writes before releasing services, with gated-save/checkpoint regressions. The historical sandbox retry helper remains in older tests. |
