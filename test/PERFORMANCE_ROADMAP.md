# Performance optimization roadmap — completion checklist

All items from the original audit are implemented in this branch.

## Phase 1 — Baseline
- [x] `test/benchmark/` harness (1k / 10k / 50k)
- [x] `dart_test.yaml` tags (`golden`, `benchmark`)
- [x] CI excludes `golden,benchmark`; optional `benchmarks` job on `workflow_dispatch`

## Phase 2 — Hot paths
- [x] Conditional discover upsert (no-op rescan → no FTS)
- [x] Debounced scan notifications (`MediaLibraryRepositoryImpl`)
- [x] Per-folder scan enrich (no `allDiscoveredFiles` buffer)
- [x] Player queue id/index maps + recent index map
- [x] Bundled engine boot fallback (`main.dart`)
- [x] Thumbnail dispose disk-queue completer
- [x] Update download sink backpressure

## Phase 3 — Browse
- [x] `fetchMediaPage` + constants
- [x] Music view paged song subtabs + distinct album/artist grids
- [x] Videos view paged grid/list
- [x] MusicViewModel metadata-only refresh (no duplicate repo listener)
- [x] MusicView single repo listener → metadata + paged reload
- [x] Playlists “Add from library” dialog paged + server search
- [x] Global search via shell `searchQuery` on Music/Videos/Playlists views (paged queries)
- [x] Now Playing repo listener throttled

## Remaining by design
- Album/artist **drilldown** loads one album/artist query (bounded collection size).
- Benchmark `query_all_rows` retained as regression for unpaged DB cost (UI does not use it).
