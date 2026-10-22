# Seek preview behavior

Timeline previews use a separate muted decoder. Moving the pointer updates the
timestamp immediately and requests a nearby keyframe; remaining still for 250 ms
requests an exact frame. Completed images are cached in memory, with a maximum
of 256 images or 8 MiB. Main playback keeps its own position and quality settings.

Nearby cached images can be shown immediately while the pointer is moving;
exact refinement still uses the requested timestamp. A completed screenshot
that already satisfies the request is reused without another seek or capture.
Images are generated on demand and stay in memory for the current source.

For HTTP(S) `.m3u8` master playlists, the preview selects the lowest advertised
video rendition before opening the decoder. The manifest read is bounded;
unsupported playlists fall back to the original source and mpv's minimum
bitrate selection. Audio, subtitles, and disk caching are disabled, and forward
caching is limited to one second. HLS servers can still transfer a complete
segment when only one frame is needed.
Consequently, uncached internet preview latency depends on the server and
connection; cached frames avoid another network seek.

Selecting the child playlist matters because mpv's
[minimum bitrate setting](https://mpv.io/manual/stable/#options-hls-bitrate)
selects streams after opening, while FFmpeg's
[HLS demuxer](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/hls.c)
can probe other renditions during startup. Selecting the child playlist avoids
loading those extra renditions for previews.

Source changes invalidate old images. Minimize and playback buffering suspend
extraction without forgetting the latest hovered time. Remote preview media is
unloaded while suspended, and resumes only while interaction remains active.
Timeouts end the visible request without freeing a decoder that native work is
still using. Such a worker remains owned until its operation and cleanup finish.

Leaving the timeline pauses the worker immediately and keeps remote media loaded
for 400 ms, allowing quick re-entry without reopening the stream. A longer exit
unloads remote media; the idle worker is released after 15 seconds. Minimize and
playback buffering unload remote media without that grace period.

Cold remote requests allow eight seconds for manifest resolution, connection
setup, decoding, and capture. Local cold requests allow five seconds; warm
requests allow three. These are failure limits, not expected response times.

## Running the application

Build the normal desktop application explicitly from its main entrypoint:

```powershell
flutter build windows --release --no-pub --target=lib/main.dart
```

Run `build/windows/x64/runner/Release/mpvson.exe`.
