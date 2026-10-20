# Player interface refresh

The player gives video the full application area below the native OS title bar. All application actions sit at the bottom, and the queue opens on request. There is no application header. Empty space belongs to the video stage rather than a permanently empty sidebar.

Core colors follow AppTheme: background #0B1220, surface #111A2C, card #182238, border #2C3A55, text #F2F5FA, accent #60CDFF. Existing secondary, muted and status colors remain shared tokens. Cyan marks the primary action, progress and selection.

Segoe UI is the desktop typeface, with Noto Sans and DejaVu Sans fallbacks on Linux. The scale uses 40 for the home action heading, 22 for dialog titles, 16 for section titles, 13 for body and controls, and 11–12 for metadata. Content and settings labels align left. Playback transport aligns left with the elapsed/total time.

```text
                         Video stage

       Open a video                       Screen / play mark
       Open files     Open URL

       Continue watching
       File title                         Resume position / progress

During playback:
       ───────────────────── seek ─────────────────────────────
       previous play next  elapsed / total   volume speed queue more full
```

At narrower window widths the queue overlays the stage as a drawer. Home and settings content can scroll at the 720×480 minimum size. Keyboard focus, text input shortcuts, drag and drop and native window chrome remain part of the desktop interaction.

The initial design review removed the floating rounded control card, repeated bordered settings cards, visible full paths in the header, and the always-open queue. These elements made application chrome compete with the video. Borders now separate functional regions; the home screen's wide play mark is its one visual accent. No invented film artwork or metadata is needed.

The October 16 refinement removes the application header entirely. Secondary actions share the bottom More menu. A continuous 3px timeline uses cyan for elapsed video. A round thumb appears on hover, dragging or keyboard focus; a timestamp previews the target when hovering or seeking. Previewing a time does not seek; dragging commits on release. There is no invented buffered range.

The later [control-size setting](control-density.md) makes Compact the default, with a 60px strip and a 4px timeline. Normal retains the roomier 96px layout. Both modes use the same playback actions and interaction guards.

Queue cards use real media imagery as their anchor. A 112×63 thumbnail sits beside a 15px semibold title and an 11px muted path. Narrow panels use a 96×54 thumbnail, while the title can wrap onto two lines. Known duration sits over the thumbnail's lower-right corner. The selected image has a thin cyan outline; there are no visible order numbers or Current/Playing badges.

The drag grip overlays the image's left edge and appears on row hover or keyboard focus, so it reserves no extra column. Its hit area remains available for dragging, and search disables reordering. Remove, undo, clear, keyboard selection, and queue search retain their existing behavior. Thumbnail work belongs to a separate cached data service; a failed decode leaves a quiet movie placeholder and never prevents playback.
