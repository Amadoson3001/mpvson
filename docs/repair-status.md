# Repair status and acceptance handoff

This record describes the current working-tree changes, not the historical audit results.

## Confirmed issues

1. Opening from the file picker, URL dialog, and drop target bypassed the shared opening preference coordinator. Reproduce by selecting a preference and opening media through those actions while another item is loaded. These actions now use the coordinator; explicit queue and recent-play actions have explicit intent. Manual acceptance is pending.
2. Source validation used synchronous existence checks and did not convert file URIs. Reproduce with a file URI or a slow filesystem. Validation now converts file URIs and checks asynchronously, and errors do not include the submitted URL. Manual acceptance is pending.
3. Concurrent desktop preference saves used the same temporary file and ignored failures. Reproduce by rapidly changing settings, or making the preference directory unwritable. Writes are now serialized and coalesced, with a recovery backup, visible retry, and a shutdown flush. Disposable-profile failure and restart checks remain pending.
4. Linux MPRIS sent rate, volume, shuffle, and repeat commands that Dart did not implement. The handlers now use explicit setters. Metadata now carries a per-entry MPRIS object path for seek validation. Linux runtime acceptance is pending.
5. Native Stop paused instead of stopping. Stop now checkpoints progress, retains the queue, and stops the playback engine. Manual acceptance is pending.
6. Sleep inhibition included audio and inferred video from filename extensions. It now depends on the controller's detected video kind and visible video output. Platform acceptance is pending.

## Remaining priority work

- P0: Complete native activation readiness handshake and request identity on Windows and Linux. Requests may still arrive before the Dart channel handler is registered. Secondary `--enqueue` forwarding has been changed but requires runtime verification.
- P1: Finish the playback-first interface and shared queue state across dock and drawer. Audit library navigation state and stale asynchronous results.
- P1: Complete session, URL-consent, update, native rendering, resource, and packaging audits. Exercise shutdown failure, retry, and cancellation with disposable data.
- P1: Run Windows installation and packaged smoke checks, manual playback and source scenarios, all requested sizes and accessibility scenarios, the 10,000-item queue, and the 30-minute performance session. Capture screenshots, frame times, and memory results.
- P1: Run Ubuntu CI when GitHub authentication is restored and obtain Linux runtime evidence using the checklist below.

## Linux desktop handoff checklist

Record distribution, desktop environment, package and engine versions, commands, results, and screenshots or logs. Use disposable profile data and media copies.

- Install the package and launch normally. Play local audio and video, HTTP(S), file URIs, Unicode paths, missing files, and subtitles.
- Open files from the desktop and a second invocation, including `--enqueue`, before and after startup finishes. Verify each request arrives once and opening preferences are respected.
- Check MPRIS play, pause, stop, next, previous, rate, volume, shuffle, repeat, and seek. Verify stale track IDs cannot seek the new item and stop retains the queue and progress.
- Check screen sleep inhibition for visible video, audio, pause, stop, minimize, and shutdown.
- Restart and verify settings, queue, playlists, favorites, and resume positions. Remove the package and verify the intended installation files and associations are removed without deleting user data.

## Follow-up repairs

- Stop invalidates the pending load and cancels its timer before waiting for disk or the engine. File validation now checks whether the load was superseded after the asynchronous existence check.
- Opening readiness no longer fails permanently after a 20-second startup timeout; requests wait for session initialization to finish, and a failed initialization can be retried.
- Windows forwards `--enqueue` in its existing activation list. Linux registers the option with GApplication and forwards the intent for secondary command-line requests. The separate native readiness handshake remains unfinished.
- Malformed primary desktop preferences fall back to the backup. A subsequent save preserves that backup while replacing the invalid primary.
- Redundant shuffle requests leave the transport command revision unchanged.

These changes require manual race, failure-injection, and cross-platform activation checks. Linux runtime verification remains pending.

Follow-up verification: Dart formatting and analysis passed. The Windows release build reached linking but failed with LNK1104 because the existing release executable could not be opened. The updated native and Dart changes therefore still need a successful release build and runtime checks.
