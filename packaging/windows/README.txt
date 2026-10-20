Mpvson 0.1.0

Start mpvson.exe. Keep all DLLs and the data folder beside it.
The Windows bundle includes its tested fallback playback engine.

Open files, drop videos into the window, or press Ctrl+L to open a URL.
Space pauses or plays; hold Space for 2x speed. Arrow keys seek or change
volume. P opens the queue. F11 toggles fullscreen.

Queue state, recent files, playback positions, preferences and independent
engine packages use the Windows application-support directory. Removing an
item from the queue does not delete its media file.

Settings > About > Updates & about has separate Application and Playback
engine tracks. Application packages are downloaded for manual installation
after closing Mpvson; that app-package manifest is configured independently.
By default, the Windows engine track checks mpv's first-party rolling
development build over HTTPS and verifies the asset's published GitHub size
and SHA-256 digest. No Mpvson engine host or signing key is required. These
upstream builds are not Ed25519-signed or certified by Mpvson. An optional
custom signed engine feed can be configured at build time.

Engine packages stage separately and activate after restarting. Roll back
engine selects the previous compatible engine or the bundled fallback for the
next restart. If an engine fails after native player initialization, Mpvson
persists the fallback choice and restarts in a clean process because MediaKit
caches native bindings. A queued engine change can be discarded before
restarting. The app-package manifest may remain unconfigured even while the
default engine source is available. Setup and release instructions are in
docs/updates.md.

Bundled playback engine: libmpv mpv v0.41.0-dev-gfffe7a23a, pinned in
engine-provenance.json and verified by SHA-256 before it is bundled.
