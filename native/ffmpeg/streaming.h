#ifndef SPOTIFY_STANDARD_STREAMING_H
#define SPOTIFY_STANDARD_STREAMING_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define SPOTIFY_STREAM_API __attribute__((visibility("default")))
typedef struct SpotifyStreamDecoder SpotifyStreamDecoder;
typedef struct SpotifyStreamSink SpotifyStreamSink;

/* Fixed PCM ABI: RAW 48000 Hz, stereo, interleaved signed 16-bit little-endian;
 * four bytes/frame. No container header. All paths/lifetimes belong to Dart.
 * create returns 0 or a negative FFmpeg/AVERROR code; output must be a new path.
 * input_path=NULL selects a bounded 1MiB pushed-byte ring and unseekable Ogg;
 * otherwise the standard file demuxer can seek normally. No network support. */
SPOTIFY_STREAM_API int spotify_stream_decoder_create(const char *output_path,
    const char *input_path, SpotifyStreamDecoder **out_decoder);
/* Call once on a worker; blocking until end, cancellation or error. Return 0 or
 * a negative FFmpeg error. Join this call before destroy. */
SPOTIFY_STREAM_API int spotify_stream_decoder_run(SpotifyStreamDecoder *decoder);
/* Never waits for input capacity: returns accepted bytes (0 when full/ended).
 * Caller retains/retries unaccepted input; input is copied before return. */
SPOTIFY_STREAM_API size_t spotify_stream_decoder_feed(SpotifyStreamDecoder *decoder,
    const uint8_t *bytes, size_t length);
SPOTIFY_STREAM_API int spotify_stream_decoder_end_input(SpotifyStreamDecoder *decoder);
SPOTIFY_STREAM_API void spotify_stream_decoder_cancel(SpotifyStreamDecoder *decoder);
/* Only publishes bytes after fflush; output can be read concurrently. */
SPOTIFY_STREAM_API uint64_t spotify_stream_decoder_available_bytes(SpotifyStreamDecoder *decoder);
/* 0=waiting/not started, 1=running, 2=complete (output closed, byte count final),
 * negative=FFmpeg error/cancel. A terminal status is set after output closes. */
SPOTIFY_STREAM_API int spotify_stream_decoder_status(SpotifyStreamDecoder *decoder);
/* Writes a NUL-terminated description and returns current negative error or 0.
 * No shared/global error-string state. */
SPOTIFY_STREAM_API int spotify_stream_decoder_error(SpotifyStreamDecoder *decoder,
    char *buffer, size_t capacity);
SPOTIFY_STREAM_API void spotify_stream_decoder_destroy(SpotifyStreamDecoder *decoder);

/* AudioQueue owns only PCM output, 24 preallocated buffers x 2048 frames.
 * Control methods return the original OSStatus (0=success). Not callbacks.
 * Serialize disposal with all caller operations; callbacks quiesce before free. */
SPOTIFY_STREAM_API int32_t spotify_stream_sink_create(SpotifyStreamSink **out_sink);
/* Caller supplies a multiple of four bytes. Copies into available buffers and
 * returns accepted bytes without waiting for a buffer/playback. On native error
 * it returns bytes already accepted; inspect sink_error for original OSStatus. */
SPOTIFY_STREAM_API size_t spotify_stream_sink_write(SpotifyStreamSink *sink,
    const uint8_t *pcm, size_t length);
SPOTIFY_STREAM_API size_t spotify_stream_sink_writable_bytes(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API int32_t spotify_stream_sink_start(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API int32_t spotify_stream_sink_pause(SpotifyStreamSink *sink);
/* Stops/resets queue; clears buffers and position/enqueued counters. */
SPOTIFY_STREAM_API int32_t spotify_stream_sink_reset(SpotifyStreamSink *sink);
/* Actual AudioQueue sample time, with completed-buffer fallback, clamped to
 * cumulative frames enqueued since last reset; no wall-clock player timer. */
SPOTIFY_STREAM_API uint64_t spotify_stream_sink_position_frames(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API uint64_t spotify_stream_sink_enqueued_frames(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API int32_t spotify_stream_sink_set_volume(SpotifyStreamSink *sink, float volume);
SPOTIFY_STREAM_API int32_t spotify_stream_sink_error(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API void spotify_stream_sink_dispose(SpotifyStreamSink *sink);
SPOTIFY_STREAM_API const char *spotify_streaming_version(void);

#if defined(__cplusplus)
}
#endif
#endif
