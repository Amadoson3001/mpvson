# Control size

Wide settings opens on Appearance; compact settings opens the category list. Appearance offers Compact and Normal for the bottom control layout. Compact is the default, including when loading a session saved before this preference existed. The selection updates the player immediately and is saved through the session repository.

## Design

Keep the existing AppTheme colors: background #0B1220, surface #111A2C, card #182238, border #2C3A55, text #F2F5FA and accent #60CDFF. Segoe UI and the existing Linux font fallbacks remain. Timestamps use tabular figures and existing 11px metadata type. Settings labels align left and the two choices share one segmented selector.

```text
Compact, 60px high
 ─────────────────────── seek rail ─────────────────────────
 prev play next  shuffle repeat  time     volume rate queue more full

Normal, 96px high
           ───────────── seek rail ───────────────────

 prev  PLAY  next  shuffle  repeat  time  VOLUME  rate  queue more full
```

Compact uses 32px desktop buttons, 17–18px icons, a 4px seek rail and 8px edge margins. Normal uses 44px buttons, 20–22px icons, a 3px rail and 14–22px margins. The timeline spans the full available width in both modes. Its 24px compact interaction area retains hover previews, keyboard focus and drag-release seeking. The visible rail is slightly thicker and longer in Compact, while the whole strip is 37.5% shorter.

The design review rejected scaling the entire control tree, which would also shrink text and popup content. A shared inherited sizing widget changes only the bottom-strip controls. Menus, Settings and volume dialogs retain their normal size. The two shallow levels preserve a long timeline rather than squeezing seeking between buttons. Button focus rings, tooltips, hit testing and fullscreen hiding remain active.

Appearance scrolls at the minimum window height, and enlarged text moves the selector below its description. Queue footer actions wrap when enlarged text needs more space.

## State and compatibility

`ControlDensity` is a domain enum. `PlaybackSession` stores `controlDensity` as `compact` or `normal`; missing and malformed values fall back to Compact. `PlayerController` owns the current value, notifies views synchronously and schedules persistence. Selecting the active mode is a no-op. The preference does not open media or change playback state.

Tests cover live switching at 720×480 and 1240×780, enlarged text, actual control sizes, seeking, queue access, legacy data and restart persistence. Native Windows playback and fullscreen checks run against the release and portable bundle. Linux runtime verification requires a Linux runner.
