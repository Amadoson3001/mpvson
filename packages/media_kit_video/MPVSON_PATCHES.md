# Mpvson native rendering changes

This repository owns its `media_kit_video` copy. Playback and rendering use the same selected libmpv module on Windows.

- Video controllers retain viewport size overrides across source changes and expose render visibility.
- Hidden output acknowledges frames without publishing Flutter textures. OpenGL acknowledgement binds the output's context.
- Windows render work coalesces, lifecycle commands preserve order, and texture retirement completes before backing surfaces or outputs are destroyed. Surface resize and raster reads share a lock.
- Windows resizes the DXGI surface in place so Flutter keeps the same texture ID. A complete frame is drawn into the new surface before that handle is published, and the previous public textures stay alive until the next resize.
- Windows ping-pongs two public DXGI textures. The render worker copies into the inactive one and publishes the HANDLE atomically, so Flutter never samples a texture that is being copied and the raster thread never waits on `glFinish`.
- When ANGLE can wrap the existing D3D11 device, the copy uses `glFlush` instead of a CPU stall.
- libmpv render calls set `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0` so the worker does not sleep on vsync while Flutter's raster thread waits on the same lock.
- Linux idle work retains output references. Rendering, size changes and disposal share a recursive lock. EGL operations validate context/image creation and restore context state on failure.
