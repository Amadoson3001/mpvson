# Library performance benchmarks (Phase 1 baseline)

Measures in-memory `LibraryDatabase` behavior at **1,000**, **10,000**, and **50,000** synthetic rows:

| Scenario | What it approximates |
|----------|---------------------|
| `discover_insert` | Initial folder scan upsert latency |
| `discover_rescan` | Re-scan with unchanged paths (redundant FTS / path writes) |
| `query_all_rows` | Unpaged library browse (`queryMedia` without limit) + RSS delta |
| `query_paged_250` | First UI page (`limit: 250`) |
| `query_audio_kind` | Filtered unpaged query |
| `distinct_artists` / `distinct_albums` | Music subtab aggregate refreshes |

Tests are tagged `benchmark` and skipped by default (via `dart_test.yaml`) on plain `flutter test` runs, so they are **not** part of the default CI `flutter test` run. Pass `--run-skipped` to execute them explicitly.

## Run

From the repo root:

```bash
flutter test --no-pub --run-skipped test/benchmark/
```

One tier only:

```bash
flutter test --no-pub --run-skipped test/benchmark/ --plain-name "10000 rows"
```

Persist JSON under `build/benchmark/` (for diffing baselines over time):

```bash
flutter test --no-pub --run-skipped test/benchmark/ --dart-define=RECORD_BASELINE=true
```

## Fast regression vs slow suites

| Command | Scope |
|---------|--------|
| `flutter test --no-pub --exclude-tags=golden,benchmark` | CI default (see `.github/workflows/desktop.yml`) |
| `flutter test --no-pub --run-skipped --tags=golden test/audit/screen_audit_test.dart` | Full UI layout matrix |
| `flutter test --no-pub --run-skipped test/benchmark/` | Phase 1 database baselines |
