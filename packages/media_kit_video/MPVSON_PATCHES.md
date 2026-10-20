# Mpvson native rendering changes

This repository owns its `media_kit_video` copy. Playback and rendering use the same selected libmpv module on Windows.

- Video controllers retain viewport size overrides across source changes and expose render visibility.
- Hidden output acknowledges frames without publishing Flutter textures. OpenGL acknowledgement binds the output's context.
- Windows render work coalesces, lifecycle commands preserve order, and texture retirement completes before backing surfaces or outputs are destroyed. Surface resize and raster reads share a lock.
- Linux idle work retains output references. Rendering, size changes and disposal share a recursive lock. EGL operations validate context/image creation and restore context state on failure.

See `docs/verification.md` in the application for measured results and platform coverage.
