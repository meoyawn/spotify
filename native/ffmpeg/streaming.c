/* Standard FFmpeg and AudioQueue primitives only. No networking/player policy. */
#include "streaming.h"
#include <AudioToolbox/AudioToolbox.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This fixed S16LE PCM primitive targets little-endian macOS.
#endif

enum { INPUT_CAPACITY = 1024 * 1024, AVIO_CAPACITY = 32768,
  PCM_RATE = 48000, PCM_CHANNELS = 2, PCM_FRAME_BYTES = 4,
  SINK_BUFFERS = 24, SINK_BUFFER_FRAMES = 2048,
  SINK_BUFFER_BYTES = SINK_BUFFER_FRAMES * PCM_FRAME_BYTES };

struct SpotifyStreamDecoder {
  pthread_mutex_t mutex;
  pthread_cond_t readable;
  uint8_t *ring;
  size_t ring_read, ring_count;
  bool input_ended, run_started, run_finished;
  atomic_bool cancelled;
  atomic_int status;
  atomic_uint_fast64_t available;
  char *input_path;
  FILE *output;
};

typedef struct {
  SpotifyStreamDecoder *owner;
  SwrContext *resampler;
  AVChannelLayout input_channels;
  int input_rate, input_format;
  uint8_t *samples;
  unsigned int samples_capacity;
  uint64_t bytes;
} PcmOutput;

int spotify_stream_decoder_create(const char *output_path, const char *input_path,
    SpotifyStreamDecoder **out_decoder) {
  if (!out_decoder) return AVERROR(EINVAL);
  *out_decoder = NULL;
  if (!output_path || !*output_path || (input_path && (!*input_path || !strcmp(output_path, input_path))))
    return AVERROR(EINVAL);
  SpotifyStreamDecoder *decoder = calloc(1, sizeof(*decoder));
  if (!decoder) return AVERROR(ENOMEM);
  int result = pthread_mutex_init(&decoder->mutex, NULL);
  if (result) { free(decoder); return AVERROR(result); }
  result = pthread_cond_init(&decoder->readable, NULL);
  if (result) { pthread_mutex_destroy(&decoder->mutex); free(decoder); return AVERROR(result); }
  atomic_init(&decoder->cancelled, false);
  atomic_init(&decoder->status, 0);
  atomic_init(&decoder->available, 0);
  if (input_path) {
    decoder->input_path = strdup(input_path);
    if (!decoder->input_path) { result = AVERROR(ENOMEM); goto fail; }
  } else {
    decoder->ring = malloc(INPUT_CAPACITY);
    if (!decoder->ring) { result = AVERROR(ENOMEM); goto fail; }
  }
  decoder->output = fopen(output_path, "wbx");
  if (!decoder->output) { result = AVERROR(errno ? errno : EIO); goto fail; }
  *out_decoder = decoder;
  return 0;
fail:
  free(decoder->input_path); free(decoder->ring);
  pthread_cond_destroy(&decoder->readable); pthread_mutex_destroy(&decoder->mutex);
  free(decoder);
  return result;
}

size_t spotify_stream_decoder_feed(SpotifyStreamDecoder *decoder, const uint8_t *bytes, size_t length) {
  if (!decoder || !decoder->ring || (!bytes && length)) return 0;
  /* Capacity is never waited on. Contention with the short reader copy is also
   * retriable by the caller rather than blocking its Dart isolate. */
  if (pthread_mutex_trylock(&decoder->mutex)) return 0;
  size_t accepted = 0;
  if (!decoder->input_ended && !decoder->run_finished && !atomic_load(&decoder->cancelled)) {
    accepted = INPUT_CAPACITY - decoder->ring_count;
    if (accepted > length) accepted = length;
    size_t write = (decoder->ring_read + decoder->ring_count) % INPUT_CAPACITY;
    size_t first = INPUT_CAPACITY - write;
    if (first > accepted) first = accepted;
    if (first) memcpy(decoder->ring + write, bytes, first);
    if (accepted > first) memcpy(decoder->ring, bytes + first, accepted - first);
    decoder->ring_count += accepted;
    if (accepted) pthread_cond_signal(&decoder->readable);
  }
  pthread_mutex_unlock(&decoder->mutex);
  return accepted;
}

int spotify_stream_decoder_end_input(SpotifyStreamDecoder *decoder) {
  if (!decoder || !decoder->ring) return AVERROR(EINVAL);
  pthread_mutex_lock(&decoder->mutex);
  decoder->input_ended = true;
  pthread_cond_broadcast(&decoder->readable);
  pthread_mutex_unlock(&decoder->mutex);
  return 0;
}

void spotify_stream_decoder_cancel(SpotifyStreamDecoder *decoder) {
  if (!decoder) return;
  atomic_store(&decoder->cancelled, true);
  pthread_mutex_lock(&decoder->mutex);
  pthread_cond_broadcast(&decoder->readable);
  pthread_mutex_unlock(&decoder->mutex);
}

static int interrupted(void *opaque) {
  SpotifyStreamDecoder *decoder = opaque;
  return atomic_load(&decoder->cancelled);
}

static int read_pushed(void *opaque, uint8_t *buffer, int capacity) {
  SpotifyStreamDecoder *decoder = opaque;
  if (capacity <= 0) return AVERROR(EINVAL);
  pthread_mutex_lock(&decoder->mutex);
  while (!decoder->ring_count && !decoder->input_ended && !atomic_load(&decoder->cancelled)) {
    atomic_store(&decoder->status, 0);
    pthread_cond_wait(&decoder->readable, &decoder->mutex);
  }
  int result;
  if (atomic_load(&decoder->cancelled)) result = AVERROR_EXIT;
  else if (!decoder->ring_count) result = AVERROR_EOF;
  else {
    size_t count = decoder->ring_count < (size_t)capacity ? decoder->ring_count : (size_t)capacity;
    size_t first = INPUT_CAPACITY - decoder->ring_read;
    if (first > count) first = count;
    memcpy(buffer, decoder->ring + decoder->ring_read, first);
    if (count > first) memcpy(buffer + first, decoder->ring, count - first);
    decoder->ring_read = (decoder->ring_read + count) % INPUT_CAPACITY;
    decoder->ring_count -= count;
    result = (int)count;
  }
  atomic_store(&decoder->status, 1);
  pthread_mutex_unlock(&decoder->mutex);
  return result;
}

static int publish_pcm(PcmOutput *output, int frames) {
  if (atomic_load(&output->owner->cancelled)) return AVERROR_EXIT;
  size_t bytes = (size_t)frames * PCM_FRAME_BYTES;
  if (!bytes) return 0;
  if (UINT64_MAX - output->bytes < bytes) return AVERROR(EFBIG);
  if (fwrite(output->samples, 1, bytes, output->owner->output) != bytes || fflush(output->owner->output))
    return AVERROR(errno ? errno : EIO);
  output->bytes += bytes;
  atomic_store_explicit(&output->owner->available, output->bytes, memory_order_release);
  return 0;
}

static int sample_buffer(PcmOutput *output, int frames) {
  if (frames < 0 || frames > INT32_MAX / PCM_FRAME_BYTES) return AVERROR(ENOMEM);
  if (!frames) return 0;
  av_fast_malloc(&output->samples, &output->samples_capacity, (size_t)frames * PCM_FRAME_BYTES);
  return output->samples ? 0 : AVERROR(ENOMEM);
}

static int flush_resampler(PcmOutput *output) {
  if (!output->resampler) return 0;
  for (;;) {
    int capacity = swr_get_out_samples(output->resampler, 0);
    if (capacity < 0) return capacity;
    if (!capacity) return 0;
    int result = sample_buffer(output, capacity);
    if (result < 0) return result;
    int frames = swr_convert(output->resampler, &output->samples, capacity, NULL, 0);
    if (frames < 0) return frames;
    if (!frames) return 0;
    if ((result = publish_pcm(output, frames)) < 0) return result;
  }
}

static int convert_frame(PcmOutput *output, AVFrame *frame) {
  if (frame->sample_rate <= 0 || frame->ch_layout.nb_channels <= 0) return AVERROR_INVALIDDATA;
  int result;
  if (output->resampler && (frame->sample_rate != output->input_rate ||
      frame->format != output->input_format || av_channel_layout_compare(&output->input_channels, &frame->ch_layout))) {
    if ((result = flush_resampler(output)) < 0) return result;
    swr_free(&output->resampler);
    av_channel_layout_uninit(&output->input_channels);
  }
  if (!output->resampler) {
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    result = swr_alloc_set_opts2(&output->resampler, &stereo, AV_SAMPLE_FMT_S16, PCM_RATE,
      &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
    if (result < 0 || (result = swr_init(output->resampler)) < 0) return result;
    if ((result = av_channel_layout_copy(&output->input_channels, &frame->ch_layout)) < 0) return result;
    output->input_rate = frame->sample_rate;
    output->input_format = frame->format;
  }
  int capacity = swr_get_out_samples(output->resampler, frame->nb_samples);
  if (capacity < 0) return capacity;
  if ((result = sample_buffer(output, capacity)) < 0) return result;
  int frames = swr_convert(output->resampler, &output->samples, capacity,
    (const uint8_t **)frame->extended_data, frame->nb_samples);
  return frames < 0 ? frames : publish_pcm(output, frames);
}

static int receive_frames(AVCodecContext *codec, AVFrame *frame, PcmOutput *output) {
  int result;
  while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
    result = convert_frame(output, frame);
    av_frame_unref(frame);
    if (result < 0) return result;
  }
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

int spotify_stream_decoder_run(SpotifyStreamDecoder *decoder) {
  if (!decoder) return AVERROR(EINVAL);
  pthread_mutex_lock(&decoder->mutex);
  if (decoder->run_started) { pthread_mutex_unlock(&decoder->mutex); return AVERROR(EALREADY); }
  decoder->run_started = true;
  atomic_store(&decoder->status, 1);
  pthread_mutex_unlock(&decoder->mutex);
  AVFormatContext *format = NULL;
  AVIOContext *io = NULL;
  AVCodecContext *codec = NULL;
  AVPacket *packet = NULL;
  AVFrame *frame = NULL;
  const AVCodec *implementation = NULL;
  PcmOutput output = {.owner = decoder};
  int result = 0, stream;
  if (atomic_load(&decoder->cancelled)) { result = AVERROR_EXIT; goto done; }
  format = avformat_alloc_context();
  if (!format) { result = AVERROR(ENOMEM); goto done; }
  format->interrupt_callback = (AVIOInterruptCB){interrupted, decoder};
  if (decoder->input_path) {
    if ((result = avformat_open_input(&format, decoder->input_path, NULL, NULL)) < 0) goto done;
    if ((result = avformat_find_stream_info(format, NULL)) < 0) goto done;
  } else {
    uint8_t *buffer = av_malloc(AVIO_CAPACITY);
    if (!buffer) { result = AVERROR(ENOMEM); goto done; }
    io = avio_alloc_context(buffer, AVIO_CAPACITY, 0, decoder, read_pushed, NULL, NULL);
    if (!io) { av_free(buffer); result = AVERROR(ENOMEM); goto done; }
    io->seekable = 0;
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *ogg = av_find_input_format("ogg");
    if (!ogg) { result = AVERROR_DEMUXER_NOT_FOUND; goto done; }
    if ((result = avformat_open_input(&format, NULL, ogg, NULL)) < 0) goto done;
    /* Ogg read_header has already parsed codec headers/extradata. Its public
     * source skips the end scan when AVIO is unseekable. No full-stream probe. */
  }
  stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &implementation, 0);
  if (stream < 0) { result = stream; goto done; }
  codec = avcodec_alloc_context3(implementation);
  if (!codec) { result = AVERROR(ENOMEM); goto done; }
  if ((result = avcodec_parameters_to_context(codec, format->streams[stream]->codecpar)) < 0) goto done;
  codec->pkt_timebase = format->streams[stream]->time_base;
  /* Leave SKIP_MANUAL unset: FFmpeg's standard decoder applies packet skip and
   * discard padding before returning frames. Never duplicate Vorbis trimming. */
  if ((result = avcodec_open2(codec, implementation, NULL)) < 0) goto done;
  packet = av_packet_alloc(); frame = av_frame_alloc();
  if (!packet || !frame) { result = AVERROR(ENOMEM); goto done; }
  for (;;) {
    if (atomic_load(&decoder->cancelled)) { result = AVERROR_EXIT; goto done; }
    result = av_read_frame(format, packet);
    if (result < 0) break;
    if (packet->stream_index == stream) {
      result = avcodec_send_packet(codec, packet);
      if (result == AVERROR(EAGAIN)) {
        if ((result = receive_frames(codec, frame, &output)) < 0) goto done;
        result = avcodec_send_packet(codec, packet);
      }
      if (result >= 0) result = receive_frames(codec, frame, &output);
    }
    av_packet_unref(packet);
    if (result < 0) goto done;
  }
  if (result != AVERROR_EOF) goto done;
  result = avcodec_send_packet(codec, NULL);
  if (result == AVERROR(EAGAIN)) {
    if ((result = receive_frames(codec, frame, &output)) < 0) goto done;
    result = avcodec_send_packet(codec, NULL);
  }
  if (result < 0 && result != AVERROR_EOF) goto done;
  if ((result = receive_frames(codec, frame, &output)) < 0) goto done;
  if ((result = flush_resampler(&output)) < 0) goto done;
  result = 0;
done:
  swr_free(&output.resampler); av_channel_layout_uninit(&output.input_channels); av_free(output.samples);
  av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&codec);
  avformat_close_input(&format);
  if (io) av_freep(&io->buffer);
  avio_context_free(&io);
  if (decoder->output) {
    if (fclose(decoder->output) && result >= 0) result = AVERROR(errno ? errno : EIO);
    decoder->output = NULL;
  }
  if (atomic_load(&decoder->cancelled)) result = AVERROR_EXIT;
  /* Terminal status follows all output/resource cleanup; caller still joins
   * the worker before destroy rather than freeing a live native stack frame. */
  pthread_mutex_lock(&decoder->mutex);
  decoder->run_finished = true;
  atomic_store_explicit(&decoder->status, result < 0 ? result : 2, memory_order_release);
  pthread_cond_broadcast(&decoder->readable);
  pthread_mutex_unlock(&decoder->mutex);
  return result;
}

uint64_t spotify_stream_decoder_available_bytes(SpotifyStreamDecoder *decoder) {
  return decoder ? atomic_load_explicit(&decoder->available, memory_order_acquire) : 0;
}
int spotify_stream_decoder_status(SpotifyStreamDecoder *decoder) {
  return decoder ? atomic_load_explicit(&decoder->status, memory_order_acquire) : AVERROR(EINVAL);
}
int spotify_stream_decoder_error(SpotifyStreamDecoder *decoder, char *buffer, size_t capacity) {
  int status = spotify_stream_decoder_status(decoder);
  if (buffer && capacity) {
    if (status < 0) av_strerror(status, buffer, capacity);
    else buffer[0] = 0;
  }
  return status < 0 ? status : 0;
}
void spotify_stream_decoder_destroy(SpotifyStreamDecoder *decoder) {
  if (!decoder) return;
  /* Contract: decoder_run is joined and no other caller uses this handle. */
  if (decoder->output) fclose(decoder->output);
  free(decoder->input_path); free(decoder->ring);
  pthread_cond_destroy(&decoder->readable); pthread_mutex_destroy(&decoder->mutex);
  free(decoder);
}

struct SpotifyStreamSink {
  pthread_mutex_t api_mutex, state_mutex;
  AudioQueueRef queue;
  AudioQueueBufferRef buffers[SINK_BUFFERS];
  bool busy[SINK_BUFFERS], discarding;
  uint32_t frames[SINK_BUFFERS];
  uint64_t enqueued, completed, position;
  float volume;
  atomic_int last_error;
};

static void buffer_consumed(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer) {
  (void)queue;
  SpotifyStreamSink *sink = opaque;
  pthread_mutex_lock(&sink->state_mutex);
  for (int index = 0; index < SINK_BUFFERS; index++) {
    if (sink->buffers[index] == buffer && sink->busy[index]) {
      if (!sink->discarding) sink->completed += sink->frames[index];
      sink->busy[index] = false;
      sink->frames[index] = 0;
      break;
    }
  }
  pthread_mutex_unlock(&sink->state_mutex);
}

static OSStatus create_queue(SpotifyStreamSink *sink) {
  AudioStreamBasicDescription format = {.mSampleRate = PCM_RATE,
    .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    .mBytesPerPacket = PCM_FRAME_BYTES, .mFramesPerPacket = 1,
    .mBytesPerFrame = PCM_FRAME_BYTES, .mChannelsPerFrame = PCM_CHANNELS, .mBitsPerChannel = 16};
  OSStatus result = AudioQueueNewOutput(&format, buffer_consumed, sink, NULL, NULL, 0, &sink->queue);
  if (result) return result;
  for (int index = 0; index < SINK_BUFFERS; index++) {
    result = AudioQueueAllocateBuffer(sink->queue, SINK_BUFFER_BYTES, &sink->buffers[index]);
    if (result) break;
  }
  if (!result) result = AudioQueueSetParameter(sink->queue, kAudioQueueParam_Volume, sink->volume);
  if (result) { AudioQueueDispose(sink->queue, true); sink->queue = NULL; }
  return result;
}

int32_t spotify_stream_sink_create(SpotifyStreamSink **out_sink) {
  if (!out_sink) return kAudio_ParamError;
  *out_sink = NULL;
  SpotifyStreamSink *sink = calloc(1, sizeof(*sink));
  if (!sink) return kAudio_MemFullError;
  int error = pthread_mutex_init(&sink->api_mutex, NULL);
  if (error) { free(sink); return -error; }
  error = pthread_mutex_init(&sink->state_mutex, NULL);
  if (error) { pthread_mutex_destroy(&sink->api_mutex); free(sink); return -error; }
  sink->volume = 1;
  atomic_init(&sink->last_error, 0);
  OSStatus result = create_queue(sink);
  if (result) {
    pthread_mutex_destroy(&sink->state_mutex); pthread_mutex_destroy(&sink->api_mutex); free(sink);
    return result;
  }
  *out_sink = sink;
  return 0;
}

size_t spotify_stream_sink_write(SpotifyStreamSink *sink, const uint8_t *pcm, size_t length) {
  if (!sink) return 0;
  if ((!pcm && length) || length % PCM_FRAME_BYTES) { atomic_store(&sink->last_error, kAudio_ParamError); return 0; }
  if (pthread_mutex_trylock(&sink->api_mutex)) return 0;
  OSStatus error = 0;
  size_t accepted = 0;
  if (!sink->queue) { error = kAudioQueueErr_QueueInvalidated; goto done; }
  while (accepted < length) {
    if (pthread_mutex_trylock(&sink->state_mutex)) break;
    int index;
    for (index = 0; index < SINK_BUFFERS && sink->busy[index]; index++) {}
    if (index == SINK_BUFFERS) { pthread_mutex_unlock(&sink->state_mutex); break; }
    size_t count = length - accepted;
    if (count > SINK_BUFFER_BYTES) count = SINK_BUFFER_BYTES;
    uint32_t frames = (uint32_t)(count / PCM_FRAME_BYTES);
    sink->busy[index] = true;
    sink->frames[index] = frames;
    sink->enqueued += frames;
    pthread_mutex_unlock(&sink->state_mutex);
    AudioQueueBufferRef buffer = sink->buffers[index];
    memcpy(buffer->mAudioData, pcm + accepted, count);
    buffer->mAudioDataByteSize = (UInt32)count;
    error = AudioQueueEnqueueBuffer(sink->queue, buffer, 0, NULL);
    if (error) {
      pthread_mutex_lock(&sink->state_mutex);
      sink->busy[index] = false; sink->frames[index] = 0; sink->enqueued -= frames;
      pthread_mutex_unlock(&sink->state_mutex);
      break;
    }
    accepted += count;
  }
done:
  atomic_store(&sink->last_error, error);
  pthread_mutex_unlock(&sink->api_mutex);
  return accepted;
}

size_t spotify_stream_sink_writable_bytes(SpotifyStreamSink *sink) {
  if (!sink) return 0;
  pthread_mutex_lock(&sink->state_mutex);
  size_t count = 0;
  for (int index = 0; index < SINK_BUFFERS; index++) if (!sink->busy[index]) count += SINK_BUFFER_BYTES;
  pthread_mutex_unlock(&sink->state_mutex);
  return count;
}

int32_t spotify_stream_sink_start(SpotifyStreamSink *sink) {
  if (!sink) return kAudio_ParamError;
  pthread_mutex_lock(&sink->api_mutex);
  OSStatus result = sink->queue ? AudioQueueStart(sink->queue, NULL) : kAudioQueueErr_QueueInvalidated;
  atomic_store(&sink->last_error, result);
  pthread_mutex_unlock(&sink->api_mutex);
  return result;
}
int32_t spotify_stream_sink_pause(SpotifyStreamSink *sink) {
  if (!sink) return kAudio_ParamError;
  pthread_mutex_lock(&sink->api_mutex);
  OSStatus result = sink->queue ? AudioQueuePause(sink->queue) : kAudioQueueErr_QueueInvalidated;
  atomic_store(&sink->last_error, result);
  pthread_mutex_unlock(&sink->api_mutex);
  return result;
}
int32_t spotify_stream_sink_reset(SpotifyStreamSink *sink) {
  if (!sink) return kAudio_ParamError;
  pthread_mutex_lock(&sink->api_mutex);
  pthread_mutex_lock(&sink->state_mutex); sink->discarding = true; pthread_mutex_unlock(&sink->state_mutex);
  /* Synchronous disposal quiesces callbacks and resets the actual sample clock.
   * Recreate the bounded queue instead of guessing how a device clock rebases.
   * No state mutex is held while AudioQueue invokes its final callbacks. */
  OSStatus result = sink->queue ? AudioQueueDispose(sink->queue, true) : 0;
  if (result) {
    /* Do not reuse/free callback storage unless synchronous disposal succeeds. */
    pthread_mutex_lock(&sink->state_mutex); sink->discarding = false; pthread_mutex_unlock(&sink->state_mutex);
    atomic_store(&sink->last_error, result);
    pthread_mutex_unlock(&sink->api_mutex);
    return result;
  }
  sink->queue = NULL;
  pthread_mutex_lock(&sink->state_mutex);
  memset(sink->buffers, 0, sizeof(sink->buffers)); memset(sink->busy, 0, sizeof(sink->busy));
  memset(sink->frames, 0, sizeof(sink->frames));
  sink->enqueued = sink->completed = sink->position = 0;
  pthread_mutex_unlock(&sink->state_mutex);
  if (!result) result = create_queue(sink);
  pthread_mutex_lock(&sink->state_mutex); sink->discarding = false; pthread_mutex_unlock(&sink->state_mutex);
  atomic_store(&sink->last_error, result);
  pthread_mutex_unlock(&sink->api_mutex);
  return result;
}

uint64_t spotify_stream_sink_position_frames(SpotifyStreamSink *sink) {
  if (!sink) return 0;
  pthread_mutex_lock(&sink->api_mutex);
  AudioTimeStamp stamp = {0};
  OSStatus result = sink->queue ? AudioQueueGetCurrentTime(sink->queue, NULL, &stamp, NULL) : kAudioQueueErr_QueueInvalidated;
  pthread_mutex_lock(&sink->state_mutex);
  uint64_t position = sink->completed;
  if (!result && (stamp.mFlags & kAudioTimeStampSampleTimeValid) &&
      isfinite(stamp.mSampleTime) && stamp.mSampleTime >= 0 && stamp.mSampleTime < (double)UINT64_MAX) {
    position = (uint64_t)stamp.mSampleTime;
  }
  if (position > sink->enqueued) position = sink->enqueued;
  if (position < sink->position) position = sink->position;
  sink->position = position;
  pthread_mutex_unlock(&sink->state_mutex);
  pthread_mutex_unlock(&sink->api_mutex);
  return position;
}
uint64_t spotify_stream_sink_enqueued_frames(SpotifyStreamSink *sink) {
  if (!sink) return 0;
  pthread_mutex_lock(&sink->state_mutex);
  uint64_t result = sink->enqueued;
  pthread_mutex_unlock(&sink->state_mutex);
  return result;
}
int32_t spotify_stream_sink_set_volume(SpotifyStreamSink *sink, float volume) {
  if (!sink) return kAudio_ParamError;
  if (!isfinite(volume) || volume < 0 || volume > 1) { atomic_store(&sink->last_error, kAudio_ParamError); return kAudio_ParamError; }
  pthread_mutex_lock(&sink->api_mutex);
  OSStatus result = sink->queue ? AudioQueueSetParameter(sink->queue, kAudioQueueParam_Volume, volume) : kAudioQueueErr_QueueInvalidated;
  if (!result) sink->volume = volume;
  atomic_store(&sink->last_error, result);
  pthread_mutex_unlock(&sink->api_mutex);
  return result;
}
int32_t spotify_stream_sink_error(SpotifyStreamSink *sink) {
  return sink ? atomic_load(&sink->last_error) : kAudio_ParamError;
}
void spotify_stream_sink_dispose(SpotifyStreamSink *sink) {
  if (!sink) return;
  /* Caller serializes lifetime; never called from an AudioQueue callback. */
  pthread_mutex_lock(&sink->api_mutex);
  pthread_mutex_lock(&sink->state_mutex); sink->discarding = true; pthread_mutex_unlock(&sink->state_mutex);
  OSStatus result = sink->queue ? AudioQueueDispose(sink->queue, true) : 0;
  if (result) {
    /* A failed OS disposal must not turn a still-live callback into a UAF. */
    atomic_store(&sink->last_error, result);
    pthread_mutex_unlock(&sink->api_mutex);
    return;
  }
  sink->queue = NULL;
  pthread_mutex_unlock(&sink->api_mutex);
  pthread_mutex_destroy(&sink->state_mutex); pthread_mutex_destroy(&sink->api_mutex);
  free(sink);
}

const char *spotify_streaming_version(void) { return av_version_info(); }
