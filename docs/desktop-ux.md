# Desktop playback interactions

The video stays the main content. The bottom timeline and controls remain the only application chrome. A context menu provides less frequent actions, and short feedback messages confirm volume and playback changes without requiring the bar to stay open.

The design uses the existing AppTheme background #0B1220, surface #111A2C, card #182238, border #2C3A55, text #F2F5FA and cyan #60CDFF. Segoe UI and the existing Linux fallbacks remain. Context-menu rows align icons, labels and shortcuts; selected speed and track items use a cyan check. Submenus open to the available side of the window. The volume feedback is a small, noninteractive pill with a level rail.

```text
Video surface                         Right-click
                                      Play / pause
                                      Seek             >
          brief volume feedback       Playback speed   >
                                      Audio / subtitles>
                                      Volume           >
                                      Open             >
                                      Queue / fullscreen / settings

──────────────────── timeline ──────────────────────────
transport  shuffle repeat  time             volume speed actions
```

## Research and choices

- [mpv's interactive controls](https://github.com/mpv-player/mpv/blob/master/DOCS/man/mpv.rst) describe wheel volume, double-click fullscreen, a right-click context menu, mute and fullscreen keys. Mpvson adopts those interactions through Flutter widgets, with single-click playback toggle and the existing Space/arrow shortcuts.
- [mpv's on-screen-controller documentation](https://github.com/mpv-player/mpv/blob/master/DOCS/man/osc.rst) supports automatic hiding and a movement threshold. Mpvson uses a two-second fullscreen delay and ignores movement below three logical pixels. The normal window retains its longer delay and hover protection.
- [VLC's wheel-input fixes](https://mailman.videolan.org/pipermail/vlc-commits/2025-November/072138.html) cover touchpad accumulation and duplicate propagation. Mpvson handles wheel input only on the video surface and resolves each signal once. Small deltas accumulate, a wheel step changes volume by five points, and changes stay within 0–100. Queue and menu scrolling retain their own behavior.
- [mpv's cursor options](https://mpv.io/manual/stable/#options-cursor-autohide) describe hiding an idle cursor in fullscreen. Mpvson uses Flutter's hidden system cursor on the video when the fullscreen controls have faded.

These are adapted interaction patterns, not additional playback engines or foreign UI components. No new package, web view or ASS-rendered control is needed.

## Behavior

- Scroll up over video to raise volume; scroll down to lower it. Volume feedback fades after a short interval. Horizontal scrolling does not alter volume.
- Click video to pause or play. Double-click enters or leaves fullscreen without also toggling playback.
- Right-click or press Shift+F10 to open the context menu. Speed, audio and subtitle selections reflect controller state. External subtitle loading uses the native file picker.
- M toggles mute and restores the most recent audible volume across input methods. A saved nonzero volume supplies that level on launch. A session saved while muted starts with a default unmute level because the existing session schema stores only the current volume.
- F and F11 toggle fullscreen; Escape leaves it. Escape first dismisses a compact queue drawer. Text fields keep their normal key behavior.
- During fullscreen playback, idle controls and the cursor disappear even after clicking a control or leaving the pointer over the bar. Meaningful mouse movement reveals them again. Menus, dialogs, keyboard focus, paused/buffering playback and active slider dragging keep controls visible.
- Native fullscreen events synchronize the application state, including fullscreen entered outside the bottom button. Entering fullscreen closes the queue so it does not cover the video.

## Verification

Widget checks cover gesture routing, volume bounds and touchpad accumulation, menu placement and submenus at both supported window sizes, keyboard access, subtitle picker dispatch, idle hiding, cursor hit testing and drag/focus guards. Controller tests exercise delayed native volume writes, bursts, mute restoration and failure rollback.

In historical verification records, native fullscreen validation entered a real native fullscreen window, waited for the controls' rendered opacity to reach zero and the cursor configuration to become hidden, captured the video without the control bar, restored windowed mode, and verified pause, seeking and shutdown on portable-bundle extractions. This demonstrated native fullscreen/control behavior and cursor configuration; it is not a claim of accessibility-tool or every GPU/OS coverage. Linux runtime verification remains pending.
