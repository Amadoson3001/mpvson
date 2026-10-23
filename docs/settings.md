# Settings

Mpvson settings use a searchable desktop dialog. Wide windows show categories
beside the selected page. Smaller windows show a category list with a Back
action; enlarged text also selects this layout when needed. Content scrolls
independently of the dialog header and search field.

| Category | Controls |
| --- | --- |
| General | Opening files, keeping the computer awake, OS default apps, settings backup |
| Appearance | Compact and Normal player controls with a preview |
| Playback | Speed, shuffle, repeat, and resume behavior |
| Video | Quality preset, hardware decoding, and picture adjustments |
| Audio & subtitles | Tracks, language priorities, subtitle appearance and preview, timing |
| History & privacy | History recording, clearing history, and saved stream URLs |
| Media library | Folders, availability, scans, and scan status |
| Shortcuts | Editable keyboard bindings, conflict checks, defaults, and mouse gestures |
| Updates & about | Application and engine updates, versions, and source |
| Changed settings | Differences from defaults and selective resets |

Use Ctrl+F inside settings to focus search. Results match names, category
descriptions, and common terms such as GPU, captions, and resume. Selecting a
result opens its category and reveals the matching control. Search never
indexes media paths or saved stream URLs.

Arrow keys move through search results and keep the active result visible;
Enter opens it. Settings remembers the last category you selected. An explicit
category request takes priority over that remembered location.

Changes apply immediately. Picture and timing sliders commit when adjustment
ends; numeric fields validate their supported range before applying. Resets
affect the relevant section only. Selecting a subtitle file keeps settings
open. App and engine update operations use their existing services; opening
settings does not automatically check or download an update.

Each group explains its scope. Track choices affect the current item, while
ordered audio and subtitle language preferences apply when opening future
media. Enter comma-separated language tags such as `eng,ar,pt-BR`. Resume can
continue automatically, ask before continuing, or always start from the
beginning. Asking opens media paused until you choose; cancelling leaves it
paused at the beginning.

Subtitle appearance has a live sample for font, relative text size, color,
outline, background opacity, and vertical position. Its reset preserves
language and timing choices. Styled subtitle files can supply their own
appearance; their embedded styling remains respected.

Shortcuts can be changed individually. Conflicting bindings and navigation
keys are rejected with an explanation. F11 and the context-menu key remain
available. Restore one binding or all defaults from the same page. Text fields,
focused sliders, and queue navigation keep their normal keyboard behavior.

Changed settings lists preferences that differ from defaults. Select individual
values to reset; confirmation shows the resulting defaults. Unselected values
remain unchanged. Resetting a binding that would conflict with another custom
binding requires selecting both bindings or restoring all shortcut defaults.

General offers JSON export and import. Backups contain player preferences,
subtitle styling, language priorities, opening behavior, and shortcuts. They
exclude media paths, queue contents, library folders, history, saved URLs,
recording choices, and settings navigation. Imports validate the complete
document and show a confirmation before applying changes. Cancelling or
rejecting an invalid document leaves preferences unchanged.

The dialog reports pending preference saves and failures on every page. If persistence fails,
the selected value still applies during the session and Retry attempts to save
it again. Preference writes are serialized so rapid selections cannot leave an
older value on disk. Existing preference and session keys are unchanged.

History recording and URL persistence remain separate preferences. Disabling
history stops new recording while retaining existing history. Clearing history
requires confirmation and removes recent files, resume positions, and library
play counts while playback continues. Saving network URLs is off by default;
enabling it can store access tokens carried by complete URLs. Disabling it
scrubs stored network URLs, including session recovery data, and reports a
failure if that cannot be completed.

The visual language uses the existing navy surfaces, cyan selection, Segoe UI
and Linux font fallbacks. Settings controls retain normal sizing independently
of the player's Compact control mode. Keyboard focus, enlarged text, and
reduced-motion preferences apply throughout.

## Verification

Run `flutter analyze --no-pub` and `flutter test --no-pub --concurrency=1`.
The settings layout test covers all ten categories at 1240×780 and 720×480,
with 100%, 150%, and 200% text scaling. Interaction tests cover live control
density, exact playback speed, scoped resets, numeric validation and Escape,
slider commits, subtitle-picker cancellation, nested confirmations, and
recoverable failures. Repository tests cover rapid saves and retry behavior.

To capture review images without maintaining platform-dependent golden files:

```powershell
flutter test --no-pub test/settings_layout_test.dart --dart-define=MPVSON_CAPTURE_SETTINGS=true
```

The optional capture loads available desktop fonts and writes PNGs under
`build/settings-review/`. It does not change the application's fonts or assets.
