# In-process standard audio decoder

Build the pinned FFmpeg 9.0.2 source and small C decoding API:

```sh
uv run --project tools/oracles --locked python tools/build_ffmpeg.py
```

Output: `.local/native/libspotify_ffmpeg.dylib` (macOS arm64, about 1.4 MiB).
It depends only on libSystem. The existing Xcode native embed phase copies
and signs it with its license/build provenance; rebuild the runner after the
first native build.

`spotify_ffmpeg_decode_file(input, output, error, capacity)` decodes an already
decrypted, finite caller-owned container to PCM16 WAV. FFmpeg file demuxers and
Vorbis/AAC/MP3/FLAC/PCM decoders are enabled; network/programs are disabled.
`spotify_ffmpeg_version()` reports the linked standard library version.

`spotify_ffmpeg_decode_file_cancellable` also accepts an opaque cancellation
control allocated by `spotify_ffmpeg_cancellation_create`. The request function
sets a C11 atomic flag; the decode loop, PCM writes and FFmpeg's standard
`AVIOInterruptCB` observe it. Dart connects the caller's `CancellationToken` to
that function, waits for the decode isolate to return, then destroys the
control. It never kills a worker that still owns native handles or files.
The four-argument decoding entry point remains available for existing callers.

`FfmpegAudioDecoder.prepare` runs the operation in a Dart isolate inside the
Flutter process and returns a transient PCM `PreparedAudioFile`. It releases
the compressed source once decoding finishes. `NativeDesktopRuntime` uses it
for Ogg before the prepared-source cache and standard `just_audio` file output.
Queue, source selection, player controls, account policy and lifecycle remain
Dart. No ffmpeg process or Rust player is invoked.

The macOS26.4 native Ogg path grew Apple's caulk realtime allocator to13.7GiB
of empty dirty/swapped regions (14.3GiB process footprint) while Dart's live
heap was318MiB. The player now receives PCM rather than compressed Ogg. With
two real Spotify tracks prepared and reused, that allocator remained13KiB
across two regions; observed process footprint was642MiB, peak799MiB. These
are live debug-process observations, not a cross-version OS guarantee.

This primitive targets fixed-rate audio, downmixes more than
two channels to stereo, and rejects PCM WAV outputs exceeding the RIFF size
limit. It stages a finite PCM file, matching the existing finite source stager.
