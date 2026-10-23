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
