# Player controller state ownership map

Where each piece of player state lives, who may write it, and which listeners
wake when it changes. Written from the checkout at the time of the paging,
menu, and update consolidations; treat it as a map of the current code, not a
target design.

The controller is one `ChangeNotifier` split across seven files
(`player_controller.dart` plus six `part` files). The parts share the
private fields declared in `player_controller.dart`, so "which file owns this"
is a documentation question, not an enforced one. The `ValueNotifier`s at the
bottom of `player_controller.dart` are the real boundaries: they are the only
way a widget can subscribe to one kind of change without taking all of them.

## Update paths

| Path | Notifier | Written by | Consumers |
| --- | --- | --- | --- |
| Structure | `structureListenable` (`_StructureNotifier`) | `_publishStructureIfChanged`, key-guarded on entry id/path/title, media kind, error, recent length, density | `MediaAccentScope`, `LibraryPlaybackTracker`, settings appearance |
| Queue | `queueListenable` | `_publishQueue` → `_updateQueueSnapshotEntries`, on `_queueRevision` change | `QueuePanel` |
| Transport | `transportListenable` | `_publishTransport`, on `_publishTransport()` calls | `LibraryPlaybackTracker`, `PlaybackPulse`, music/video row state |
| Display position | `displayPositionListenable` (the position smoother) | `_positionSmoother.update` from `_publishPosition` | `SeekBar`, `PlayerControls`, `PlayerStageMedia` |
| Duration | `durationListenable` | `_handleSnapshot`, only when the value changes | `SeekBar`, `PlayerControls`, `PlayerStageMedia` |
| Buffering | `bufferingListenable` | `_handleSnapshot` and `_publishTransport`, only on change | `PlayerStageMedia` |
| Volume | `volumeListenable` | `_publishVolume` | `AudioVolumeControl`, `VolumeSection` |
| Mode | `playbackModeListenable` | `_publishPlaybackMode` | `TransportButtons`, `PlayerControls`, `QueuePanel` |
| Chapters | `chaptersListenable` | `_applySnapshot`, only when the list changes | `SeekBarSection` |
| Everything else | `notifyListeners()` via `_notifyIfOpen` | Any structural or settings change | Settings sections, `PlayerLibraryNavigation` |

## What a position tick touches

`PlaybackService.states` emits a snapshot roughly 15 times a second while
audio plays. `_handleSnapshot` is the whole tick:

1. `_applySnapshot(snapshot, notify: false)` — replaces `_playbackState`; wakes
   `chaptersListenable` only if the chapter list actually changed.
2. `_publishPosition(position)` — re-anchors `_positionSmoother`. This is the
   only unconditional write on the tick.
3. `durationListenable` / `bufferingListenable` / `_seekPreview.setSeekable` —
   each guarded by an inequality against the previous snapshot.
4. `_syncCurrentProgress()` — only when the duration changed and the engine has
   media.
5. `_publishTransport()` + `_notifyIfOpen()` — only when `changed` is true,
   and `changed` covers playing, buffering, seekable, duration, volume, rate,
   shuffle, tracks, subtitles, and error. **Position is not in `changed`**, so
   a pure position tick wakes neither the transport nor the structure
   listeners.

So the position tick is already scoped to the widgets that read position. Two
notifiers that used to be written on this path had no consumers at all —
`positionListenable` (the raw engine value, superseded by the smoother's
`displayPositionListenable`) and `seekableListenable` (`isSeekable` is read
from `_playbackState`) — and were removed.

## State groups and their owners today

| Group | Fields | Written by | Notes |
| --- | --- | --- | --- |
| Queue contents | `_queue`, `_queueIdToIndex`, `_queueIdCounter`, `_currentIndex` | queue helpers, playback and session parts | Structural edits use queue helpers that update the ID index; selection and progress are still updated by playback and session paths. |
| Queue undo | `_undo` | `removeAt`, `reorder`, `undoRemove`, `clearQueue`, import | Single-slot undo; a reorder discards it. |
| Selection / navigation history | `_navigationHistory`, `_navigationCursor`, `_pendingNavigationCursor`, `_pendingNavigationEntryId` | `player_controller_queue.dart` (clear) and the navigation methods | Cursor and pending-cursor are two views of one position; they must be cleared together. |
| Shuffle | `_shuffleEnabled`, `_shuffleRemaining`, `_shuffleVisited` | transport/queue parts | `_shuffleRemaining` is derived from `_queue`; `clearQueue` must clear both the pool and the visited set. |
| Repeat | `_repeatMode`, `_confirmedRepeatMode` | transport part | The `_confirmed*` mirror tracks what the engine acknowledged. |
| Open requests | `_pendingOpen`, `_pendingDecision`, `_activeSourceStart`, `_displacedSourceStart`, `_loadTimer` | `player_controller_playback.dart` | `_activeSourceStart` is the identity of the attempt in flight; `_displacedSourceStart` is the highest attempt known to describe a dead source. |
| Engine attachment | `_engineHasMedia`, `_engineEntryId`, `_isStopped`, `_completionHandled` | playback and engine parts | The single answer to "what does the engine have loaded". |
| Resume / progress floor | `_resumeFloor`, `_resumeEntryId`, `_resumeSeekStarted`, `_resumeGeneration`, `_resumeFloorTimer` | playback and session parts | `_resumeGeneration` guards late resume work. |
| Session save | `_saveTimer`, `_saveInFlight`, `_saveRequested`, `_saveDrain`, `_scrubBackupOnSave` | session part | Coalescing: a request during a save sets `_saveRequested` and the drain re-runs. |
| Progress checkpoint | `_progressTimer`, `_checkpointInFlight`, `_checkpointRequested`, `_checkpointDrain` | session and engine parts | Same coalescing shape as the save. |
| Closing | `_closingState`, `_closeFuture`, `_releaseFuture`, `_discardOnClose` | session part | `_closingState` gates every mutator through `_acceptsCommands`. |
| Preference echoes | the `_confirmed*` / `_applied*Revision` / `*Drain` triples for volume, rate, shuffle, repeat, density, settings, network URLs, auto-play | preferences, session and transport parts | Volume and rate writes live in the preferences part; queue and session preferences retain their own ordering and persistence paths. |

## Ownership questions this map leaves open

1. **Queue selection remains shared.** Structural edits use queue helpers that
   update the ID index, while playback and navigation paths still change the
   selected index. Progress updates replace entries without changing their IDs.
2. **Source reset publication remains path-specific.** Queue removal and undo
   share the active-source metadata reset. Cancellation, playback state,
   notifications and engine stops remain in their original order at each call
   site.
3. **The preference echo machines are eight copies of one shape.** They differ
   only in what they write and whether a write should trigger a save. A single
   owner parameterized by "apply this value" and "does applying it dirty the
   session" would collapse them.
4. **Startup owns its own subscriptions.** `main.dart` creates the controller
   and the repositories; the controller subscribes to `PlaybackService.states`
   in its constructor and to the repositories' preference streams in
   `_restore*`. The plan for a full ownership pass is one owner per
   subscription, timer, and resource, with `SessionRepository`'s coalescing
   and close retry covered by focused tests.

## How to verify a change against this map

- `flutter test test/ui/player/player_stage_motion_cost_test.dart` — the
  inline queue transition must not recompose the stage.
- `flutter test test/ui/player/player_content_dock_test.dart` — a queue tick
  must not recompose the stage.
- `flutter test test/queue_slide_transition_test.dart` — queue motion.
- Hardware: PresentMon or the `mpvson.anim` recorder for actual presentation
  intervals; see `tools/animation_baseline/README.md`.
