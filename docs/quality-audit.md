# Lifecycle and resource guards

The library watcher keeps at most 2,048 distinct pending paths per folder. A
larger burst becomes one full rescan. When no batch for that folder is
currently draining, the debounce wait is capped at two seconds from the first
event; pending events coalesce until an active drain finishes. Scan requests run
one at a time, and watcher work checks that its folder remains registered
before starting a rescan or writing file metadata.

Media parsing caps tag blocks at 16 MiB, individual tag frames at 8 MiB, and
embedded or nearby artwork at 12 MiB before image normalization. The probe
service retains concurrency slots until cancelled native work drains. One
shared native media player serializes inspection requests.

Library scan progress has its own listenable. Progress banners and settings
receive live counts without making browsing views repeat their queries. Actual
scanner and watcher writes coalesce into library notifications at most once per
500 milliseconds, with a final flush when a scan ends. Folder status and file
counts are refreshed with those notifications.

Normal scans compare stored file size and modification time in bounded batches
before metadata probing. Unchanged files keep their existing metadata. Failed
probes leave the previous fingerprint intact, so a later scan retries them;
callers can explicitly force metadata enrichment when necessary.

Music and video browsing load 80 records per page. Album and artist grids use
database aggregates, and detail headers retain complete counts and durations.
Scrolling requests more records; explicit collection playback still queues the
complete matching collection. Query generations reject stale results and keep
only one active page request plus the latest pending request. Library search
waits for a 300-millisecond typing pause, while clearing search applies at once.

The native metadata probe player is released after 15 seconds without queued
inspection work. Subsequent inspection waits for disposal before creating a
replacement. The timeout is configurable through the probe service constructor.
Resource regression coverage includes `test/scanner_efficiency_test.dart`,
`test/media_probe_idle_test.dart`, `test/library_resource_updates_test.dart`,
`test/library_paging_test.dart`, and
`test/library_database_efficiency_test.dart`.

The Windows single-instance pipe accepts at most 1 MiB per message, 2,048 paths,
and 128 KiB of UTF-8 per path. Pending activation payloads are reclaimed when
the window shuts down.

Lifecycle coverage lives in `test/lifecycle_regression_test.dart`. It checks
database close/reopen, repository disposal during initialization, stale search
results, probe cancellation slots, overlapping scans, and unregistering during
a watcher overflow scan. Run it with `flutter test --no-pub --concurrency=1`.
The desktop workflow also runs that test command, formatting, and static
analysis before release builds. A local Windows release build passed with the
existing Flutter and Visual Studio caches using `--no-pub` and one build worker.
The named-pipe activation runtime edge cases and Linux build were not exercised
in this validation.
