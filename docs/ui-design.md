# Mpvson interface

Mpvson is a player for local collections. Keep the chrome quiet and give media artwork the visual emphasis. Video plays on a true-black stage.

## Color

The shared base colors are defined in `lib/ui/core/tokens/colors.dart`.

| Token | Value | Use |
| --- | --- | --- |
| Stage | `#000000` | Video stage |
| Ground | `#17181A` | Main background |
| Layer | `#222326` | Navigation and panels |
| Line | `#33353A` | Dividers |
| Ink | `#ECEBE8` | Primary text |
| Ink dim | `#9A9A9F` | Secondary information |
| Lamp | `#E9A23B` | Fallback accent |

`MediaAccentScope` derives a color from the current thumbnail, raises its contrast against the panel background, and falls back to lamp if artwork cannot be decoded. It transitions over 400 ms and respects reduced motion. Consume it through the theme's primary color or `MediaAccent`. Status colors are reserved for status and errors.

## Type, space and shape

Onest is bundled under `assets/fonts`, with its OFL license. Use the shared type scale of 32, 20, 15, 13 and 11 pixels and weights 400 or 600. Timecodes use `FontFeature.tabularFigures()`. Use sentence case for labels and actions.

`AppSpace` holds the 4, 8, 12, 16, 24 and 32 pixel spacing steps. Controls use 6 pixel corners, artwork and dialogs use 10, and rows and bars are square. Prefer surface contrast and spacing to decorative borders.

## Navigation and playback

The shell has Home, Videos, Music, Playlists, Folders and Settings. The shell stays mounted while the video stage is shown, preserving the selected library section. Opening audio leaves navigation in place; the artwork in the transport opens Now playing. The transport contains playback controls and the shared seek bar. The queue uses `QueuePanel` in the library and video player; on narrow windows the library queue opens as a sheet.

Home offers file and URL actions and recent media. Music separates Songs, Albums and Artists, with favorites and recency as song filters. A click selects a song; Enter, a double click, or the hover play control starts playback. Folder management lives under Folders. Search supports Ctrl+K and `/`.

## Components and motion

Shared widgets live in `lib/ui/core/components`. `MediaTile` handles artwork, title and supporting text in collection grids. `MediaRow` supplies keyboard selection and activation. `SeekBar` uses the player's progress listenables. `LibraryArtwork` resolves and displays cached art with a single fallback.

Use short fades for ordinary changes. Respect `MediaQuery.disableAnimations`. Avoid decorative gradients and glows. Never cover video with a colored stage. Errors should describe what failed and a practical next step.
