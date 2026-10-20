# Playback tuning and queue navigation

Settings > Video & audio controls the running libmpv engine. Preferences are
remembered between launches. Playback stays stopped when a saved queue is
restored.

| Preset | Scaling | Debanding |
| --- | --- | --- |
| Performance | Bilinear | Off |
| Balanced, the default | Lanczos, with Hermite downscaling | Off |
| Quality | EWA Lanczos sharp, with Mitchell downscaling | On |

Choose Performance when playback stutters or GPU use is too high. Quality can
cost more GPU time. These options tune mpv's embedded renderer; they do not
change the source file's resolution or bitrate.

Hardware decoding uses mpv's automatic selection when enabled. It is a
preference, and codecs or drivers may still require software decoding. Turning
it off requests software decoding. Changing decoding mode can briefly restart
the decoder. Picture controls cover brightness, contrast, saturation and gamma.
Audio and subtitle timing offsets range from -10 to +10 seconds.

Reset restores the video and audio tuning defaults. Speed, volume and track
selection remain in the Playback section. The controls use documented
[mpv runtime options](https://mpv.io/manual/stable/). The service reads each
changed option back before reporting success and displays unconfirmed settings
in the dialog. It caches confirmed values, serializes writes and coalesces
superseded requests. Slider changes commit when the interaction ends.

More > Playback information, or the I key, samples the active decoder, source
frame rate, dropped frames, audio/video difference and buffered media. Refresh
takes another sample. It does not start background polling. An unavailable
property is shown as unavailable, including video fields for audio-only media.
The decoder and drop counters follow mpv's
[property definitions](https://mpv.io/manual/stable/#property-list).

Shuffle is available in the queue and the playback strip. It visits each queue
entry once before stopping when repeat is off. Repeat queue starts another
cycle; the cycle boundary avoids immediately replaying the current item when
there are other entries. Previous follows actual playback history and restarts
the current item when it is more than three seconds into playback. Next can
retrace forward history after Previous. Repeat current item applies to automatic
completion; manually choosing Next still advances.

The bundled Windows DLL remains the development build pinned in
`packaging/windows/engine-provenance.json`. Selecting the stable update channel
does not replace an already loaded DLL. Upstream currently publishes no stable
Windows libmpv archive that this application can embed. The updater reports
that state and keeps the existing engine. A stable bundled DLL still requires
a reproducible build of the stable mpv tag or a compatible, reviewed package.

The local tuning test verifies that the bundled engine accepts every preset,
picture adjustment and timing offset, then restores defaults:

```powershell
flutter test --no-pub --dart-define=MPVSON_NATIVE_TUNING=true test/native_playback_tuning_test.dart
```

This uses real mpv with a headless video output. In historical benchmarks,
native rendering and minimize/restore verification recorded mpv statistics
before and after measured cycles. A synthetic fixture does not reproduce every
codec, driver or source of playback lag.
