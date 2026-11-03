# Standard progressive audio primitives

Build a separate first-loadable library; this leaves the old full-file decoder
library untouched:

```sh
uv run --project tools/oracles --locked python tools/build_streaming_audio.py
```

Output: `.local/native/libspotify_streaming.dylib`. It links the same pinned
FFmpeg 9.0.2 static archives/configuration as `tools/build_ffmpeg.py`, plus macOS
AudioToolbox/CoreFoundation. Network support remains disabled. The builder
checks the cached SDK's build provenance against `upstream.json`, records each
linked archive, C/header/builder hashes and exported symbols in
`.local/native/streaming-build.json`, and signs the new library ad hoc. It does
not download sources. The full-file decoder build verifies the original archive
SHA-256 and installs the static libraries and public headers into
`.local/native/ffmpeg-static/`. Moon caches this SDK with the decoder, so a
streaming rebuild also works after restoring the cache without the vendor
source or Make build tree.

`streaming.h` is the complete C ABI. Opaque handle lifetimes and all source,
track, queue, buffering and playback decisions remain in Dart. The C callback
contains no track IDs, playlist context, Spotify messages or boundary handling.

Decoder output is raw interleaved 48 kHz stereo signed 16-bit little-endian PCM,
four bytes per frame, with no container header. `decoder_create` opens a new
output path exclusively; it must not already exist. Dart owns/deletes the path.
`decoder_run` is called once on a worker; it blocks until input EOF, cancellation
or a standard FFmpeg error. The other decoder methods can feed/cancel/poll from
another thread. `decoder_feed` copies as many bytes as fit a fixed 1 MiB ring;
it returns immediately on full capacity or short mutex contention. Dart must
retain/retry the remainder, and call `decoder_end_input` only after all bytes
have been accepted. Empty ring input waits on a condition variable in the
worker, not in Dart. Cancellation wakes that condition and the format interrupt
callback. There is no FIFO, pipe, SIGPIPE path, external process or native player.

Pushed input selects the standard Ogg demuxer explicitly, custom AVIO has no
seek callback and `seekable=0`, and its read callback returns positive data,
`AVERROR_EOF` after drained end-input, or `AVERROR_EXIT` on cancel. It never
returns zero as transient EOF. Ogg's public `ogg_read_header` already parses
codec headers/extradata and `ogg_get_length` skips its end scan when unseekable,
so this branch does not run whole-stream `avformat_find_stream_info`. Optional
input-file mode uses normal FFmpeg file seeking and stream discovery.

The send/receive API drains packets and EOF normally. `AV_CODEC_FLAG2_SKIP_MANUAL`
is left unset, so FFmpeg applies its standard skip/discard side-data before
returning frames. `libswresample` handles conversion/downmixing and is drained
at EOF and before an input-format change. No Vorbis, AES, framing trim or
resampler is implemented by hand. Each PCM write is `fflush`ed before an atomic
available-byte count is published. Terminal status follows `fclose`; status 2
therefore guarantees the final count and a closed output. Partial output remains
caller-owned on error/cancel. Cancel, join `decoder_run`, then destroy the handle.

AudioQueue uses the same fixed PCM layout and 24 preallocated 2048-frame buffers
(196608 bytes, 49152 frames total). A frame-aligned `sink_write` only copies into
available buffers and enqueues them; it never waits for audio consumption or
free buffers. Short contention also returns partial/zero acceptance for retry.
Only native callbacks mark consumed buffers free and add their completed frame
counts. Control methods return the original OSStatus; `sink_error` retains the
last native write/control result. An unaligned write returns zero and
`kAudio_ParamError` (-50).
Writable capacity is in whole free buffers; a short write still occupies one
buffer until consumed. `sink_enqueued_frames` is cumulative since reset, not
just the pending frame count. Position uses `AudioQueueGetCurrentTime` sample
time with completed-frame fallback, bounded by cumulative enqueued frames.
No wall-clock playback timer is invented.

Pause retains queued samples. Reset synchronously disposes/recreates the bounded
standard queue, retaining volume, to guarantee a fresh sample clock and no stale
callbacks before buffer reuse. It discards pending frames and zeros counters;
it does not start the replacement. Disposal occurs outside the callback with
`AudioQueueDispose(..., true)` and no state lock held, which Apple's SDK contract
says quiesces callbacks before returning. Buffers are freed by AudioQueue, then
the callback userdata/mutexes are freed. Callers must serialize final disposal
with all their operations and must never dispose from a callback. If the OS
unexpectedly rejects synchronous disposal, native userdata is retained rather
than freeing storage that a callback could still access; reset returns that
OSStatus. This exceptional disposal-failure path can retain native resources.

Public source/SDK decisions, without decompiling standard code:

- pinned FFmpeg `libavformat/avio.h` / `doc/examples/avio_read_callback.c`: custom
  AVIO read contract, current-buffer ownership and `avio_context_free` cleanup;
- `libavformat/oggdec.c`: `ogg_read_header`, unseekable `ogg_get_length` branch;
- `libavcodec/decode.c`: `discard_samples`, standard skip/discard handling;
- `libswresample/swresample.h` and `doc/examples/resample_audio.c`: standard
  conversion and delayed-sample draining;
- macOS SDK `AudioToolbox.framework/Headers/AudioQueue.h`: buffer callbacks,
  allocation/enqueue/pause, synchronous disposal and actual sample-time query.

Only native compilation and exported-ABI/dependency inspection are performed by
this task. No native playback harness, general suite or Spotify traffic runs.
