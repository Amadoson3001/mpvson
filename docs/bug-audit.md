# Bug audit, 21 October 2026

This audit covered playback attribution, controller state and shutdown,
queue interactions, thumbnails, application and engine updates, and the
Windows/Linux video output implementations. Existing workspace changes were
preserved.

## Fixes

| Area | Corrected behavior |
| --- | --- |
| Startup restore | Opening media or changing preferences while saved state loads keeps the user's current choices. Delayed restore stops after controller shutdown. |
| Playback identity | Idle property notifications cannot confirm a new source. Reopening a source waits for a new native attachment. Stop keeps its source generation across native callbacks. |
| Seeking | A seek completing after a source switch cannot overwrite the new source's saved position. |
| Playback speed | Concurrent changes are serialized and coalesced so the latest requested speed wins. |
| Startup queue settings | Restored shuffle/repeat values share the ordered write queue with user actions, so a slow startup write cannot override newer choices. |
| Subtitle controls | A closed controller ignores further subtitle commands. |
| URL entry | URLs without a host stay in the dialog with a validation error. |
| Windows accessibility | Sliders keep their overlay nodes within the same animated subtree, preventing malformed accessibility updates during playback and settings transitions. Tuning sliders announce their setting name and actual value, including increase/decrease values. |
| Update transport | Decoded gzip responses use their decoded byte count for limits and integrity checks. Disposal cancels checks waiting for response headers and releases late response bodies. |
| Update operations | Rollback, discard, checks, downloads, and opening a package block conflicting operations. Controls reflect the busy state. |
| Update cache | A backward clock change cannot prune the current download. A package remains cached if disposal races its successful record commit. Unreadable old archives cannot prevent recording a fresh package. |
| Thumbnails | Decoder construction failures release the request lock. Sidecar, cache-image, and metadata reads are bounded even when files change during a read. |
| Diagnostics | A zero-capacity memory log is valid. Stage and source text are redacted and bounded. |
| Native video | Software rendering preserves portrait aspect ratios within both dimension limits. Failed mpv property reads cannot inspect uninitialized nodes. |
| Native video startup | Failed texture creation removes its listener and cached controller, allowing a later attempt to retry. |
| Linux video | The fixed-height override checks height. Failed hardware setup cleans textures and switches away from its EGL context before software fallback. Resize callback data, channel references, and argument values are released. |

## Verification

Final local results: 286 main-suite tests passed, both opt-in native checks
passed, static analysis reported no issues, formatting and patch checks passed,
the Windows release built successfully, and engine provenance verification
passed. Logs are in `test-output/final-regression.log` and
`test-output/final-native.log`.

The regression suite includes controller races, player keyboard controls,
queue removal and undo, settings dialogs at 720×480 and 1280×800, URL correction,
update transport/operation/cache failures, thumbnail failures, and diagnostics.
The accessibility regression records incremental serialized semantics updates,
maintains their child graph, and rejects nodes unreachable from the root. The
settings transition fails with six orphan nodes when the slider workaround is
bypassed and passes with it enabled. The test also checks the tuning slider's
spoken current, increased, and decreased values.

A live Windows check verified visible video playback, pause, the player menu,
Settings, all six tuning sliders, and return to the player. UI Automation
continued exposing the transport and dialog controls after these transitions.
The check used the existing profile's staged engine; the newer bundled engine
was separately tested by the native probe. Volume was restored and the player
was closed afterward.

Run the normal checks with:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib tool test
flutter analyze
flutter test
```

Windows release and native playback verification:

```powershell
flutter build windows --release
flutter test --dart-define=MPVSON_PROBE_NATIVE_EVENTS=true test/native_source_probe_test.dart
dart run tool/engine_provenance.dart verify
```

The native probe uses the actual bundled libmpv, a generated WAV fixture, and
null audio/video output. It verifies idle state, source attachment, Stop,
same-source reopening, and completion without requiring an audio device.
The probe also checks tuning presets, picture/timing options and their reset,
playback information, runtime identity against the engine pin, and a platform
creation failure followed by a successful retry. CI runs the normal suite on
Windows and Linux, and the native probe after the Windows build.

## Limits

Windows compilation, visible playback, accessibility transitions, bundled-engine
integrity, and headless native playback were checked locally. Linux native
compilation and GPU presentation require a Linux runner and actual graphics
contexts; this Windows host has no Linux
runtime. The headless probe does not validate visible GPU textures.

Earlier Windows crash dumps from 20 October identify Flutter's accessibility
child enumeration. This audit reproduced malformed slider updates matching
[Flutter issue 190357](https://github.com/flutter/flutter/issues/190357), and
the local overlay workaround prevents that reproduced failure. The upstream
[framework fix](https://github.com/flutter/flutter/pull/193372) is not in the
installed Flutter SDK. These findings do not establish that every historical
crash has the same cause. A native UI Automation stress run combining a
10,000-entry queue, queue edits, and window resizing remains unverified. The
[Flutter child-enumeration implementation](https://api.flutter.dev/windows-embedder/classflutter_1_1_flutter_platform_node_delegate.html)
dereferences the requested child without a bounds check. That is a possible
failure mechanism, not proof of this application's cause.

The bundled engine reports the source path before its load confirmation. The
adapter rejects source-free load notifications before that path because they
can describe an idle or previous source. Different engine builds should pass
the native probe before distribution.

This records the bugs found and corrected in this audit. Passing these checks
does not prove the absence of every possible bug.
