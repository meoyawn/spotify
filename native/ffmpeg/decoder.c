/* Standard FFmpeg demux/decode/resample primitive. No player or network policy. */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

typedef struct { atomic_int cancelled; } DecodeCancellation;

static int is_cancelled(void *opaque) {
  DecodeCancellation *cancellation = opaque;
  return cancellation && atomic_load_explicit(&cancellation->cancelled, memory_order_acquire);
}

__attribute__((visibility("default")))
void *spotify_ffmpeg_cancellation_create(void) {
  DecodeCancellation *cancellation = calloc(1, sizeof(*cancellation));
  if (cancellation) atomic_init(&cancellation->cancelled, 0);
  return cancellation;
}

__attribute__((visibility("default")))
void spotify_ffmpeg_cancellation_request(void *opaque) {
  DecodeCancellation *cancellation = opaque;
  if (cancellation) atomic_store_explicit(&cancellation->cancelled, 1, memory_order_release);
}

__attribute__((visibility("default")))
void spotify_ffmpeg_cancellation_destroy(void *opaque) { free(opaque); }

typedef struct {
  DecodeCancellation *cancellation;
  FILE *output;
  SwrContext *resampler;
  AVChannelLayout channels;
  uint8_t *samples;
  unsigned int samples_capacity;
  int rate, count;
  uint64_t bytes;
} DecodeOutput;

static void le16(uint8_t *out, uint16_t value) {
  out[0] = value; out[1] = value >> 8;
}
static void le32(uint8_t *out, uint32_t value) {
  out[0] = value; out[1] = value >> 8; out[2] = value >> 16; out[3] = value >> 24;
}
static int write_pcm(DecodeOutput *out, int samples) {
  if (is_cancelled(out->cancellation)) return AVERROR_EXIT;
  size_t bytes = (size_t)samples * out->count * 2;
  if (out->bytes + bytes > UINT32_MAX - 36) return AVERROR(EFBIG);
  if (bytes && fwrite(out->samples, 1, bytes, out->output) != bytes) return AVERROR(errno ? errno : EIO);
  out->bytes += bytes;
  return 0;
}
static int convert_frame(DecodeOutput *out, AVFrame *frame) {
  int result;
  if (!out->resampler) {
    out->rate = frame->sample_rate;
    if (out->rate <= 0 || frame->ch_layout.nb_channels <= 0) return AVERROR_INVALIDDATA;
    out->count = frame->ch_layout.nb_channels == 1 ? 1 : 2;
    av_channel_layout_default(&out->channels, out->count);
    result = swr_alloc_set_opts2(&out->resampler, &out->channels, AV_SAMPLE_FMT_S16, out->rate,
      &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
    if (result < 0) return result;
    if ((result = swr_init(out->resampler)) < 0) return result;
  }
  if (frame->sample_rate != out->rate) return AVERROR_PATCHWELCOME;
  int capacity = swr_get_out_samples(out->resampler, frame->nb_samples);
  if (capacity < 0 || capacity > INT32_MAX / (out->count * 2)) return AVERROR(ENOMEM);
  av_fast_malloc(&out->samples, &out->samples_capacity, (size_t)capacity * out->count * 2);
  if (!out->samples) return AVERROR(ENOMEM);
  result = swr_convert(out->resampler, &out->samples, capacity,
    (const uint8_t **)frame->extended_data, frame->nb_samples);
  return result < 0 ? result : write_pcm(out, result);
}
static int drain(AVCodecContext *codec, AVFrame *frame, DecodeOutput *out) {
  int result;
  while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
    if (is_cancelled(out->cancellation)) { av_frame_unref(frame); return AVERROR_EXIT; }
    result = convert_frame(out, frame);
    av_frame_unref(frame);
    if (result < 0) return result;
  }
  return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

__attribute__((visibility("default")))
const char *spotify_ffmpeg_version(void) { return av_version_info(); }

/* Decodes one caller-owned decrypted container into PCM16 LE WAV. All file
 * selection, temporary-file ownership, cancellation and audio output stay Dart. */
__attribute__((visibility("default")))
int spotify_ffmpeg_decode_file_cancellable(const char *input_path, const char *output_path,
    char *error, size_t error_capacity, void *cancellation) {
  AVFormatContext *format = NULL;
  AVCodecContext *codec = NULL;
  AVPacket *packet = NULL;
  AVFrame *frame = NULL;
  const AVCodec *decoder = NULL;
  DecodeOutput out = {.cancellation = cancellation};
  uint8_t header[44] = {0};
  int result, stream;
  if (is_cancelled(cancellation)) { result = AVERROR_EXIT; goto done; }
  if (!input_path || !output_path || !strcmp(input_path, output_path)) { result = AVERROR(EINVAL); goto done; }
  format = avformat_alloc_context();
  if (!format) { result = AVERROR(ENOMEM); goto done; }
  format->interrupt_callback = (AVIOInterruptCB){is_cancelled, cancellation};
  if ((result = avformat_open_input(&format, input_path, NULL, NULL)) < 0) goto done;
  if ((result = avformat_find_stream_info(format, NULL)) < 0) goto done;
  stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
  if (stream < 0) { result = stream; goto done; }
  codec = avcodec_alloc_context3(decoder);
  if (!codec) { result = AVERROR(ENOMEM); goto done; }
  if ((result = avcodec_parameters_to_context(codec, format->streams[stream]->codecpar)) < 0) goto done;
  codec->pkt_timebase = format->streams[stream]->time_base;
  if ((result = avcodec_open2(codec, decoder, NULL)) < 0) goto done;
  packet = av_packet_alloc(); frame = av_frame_alloc();
  if (!packet || !frame) { result = AVERROR(ENOMEM); goto done; }
  out.output = fopen(output_path, "wbx");
  if (!out.output) { result = AVERROR(errno); goto done; }
  if (fwrite(header, 1, sizeof(header), out.output) != sizeof(header)) { result = AVERROR(EIO); goto done; }
  while ((result = av_read_frame(format, packet)) >= 0) {
    if (is_cancelled(cancellation)) { result = AVERROR_EXIT; goto done; }
    if (packet->stream_index == stream) {
      result = avcodec_send_packet(codec, packet);
      if (result >= 0) result = drain(codec, frame, &out);
    }
    av_packet_unref(packet);
    if (result < 0) goto done;
  }
  if (is_cancelled(cancellation)) { result = AVERROR_EXIT; goto done; }
  if (result != AVERROR_EOF) goto done;
  result = avcodec_send_packet(codec, NULL);
  if (result >= 0) result = drain(codec, frame, &out);
  if (result < 0) goto done;
  if (!out.resampler || !out.bytes) { result = AVERROR_INVALIDDATA; goto done; }
  for (;;) {
    if (is_cancelled(cancellation)) { result = AVERROR_EXIT; goto done; }
    int capacity = swr_get_out_samples(out.resampler, 0);
    if (capacity <= 0) break;
    av_fast_malloc(&out.samples, &out.samples_capacity, (size_t)capacity * out.count * 2);
    if (!out.samples) { result = AVERROR(ENOMEM); goto done; }
    int count = swr_convert(out.resampler, &out.samples, capacity, NULL, 0);
    if (count < 0) { result = count; goto done; }
    if (!count) break;
    if ((result = write_pcm(&out, count)) < 0) goto done;
  }
  memcpy(header, "RIFF", 4); le32(header + 4, (uint32_t)out.bytes + 36);
  memcpy(header + 8, "WAVEfmt ", 8); le32(header + 16, 16); le16(header + 20, 1);
  le16(header + 22, out.count); le32(header + 24, out.rate); le32(header + 28, out.rate * out.count * 2);
  le16(header + 32, out.count * 2); le16(header + 34, 16);
  memcpy(header + 36, "data", 4); le32(header + 40, (uint32_t)out.bytes);
  if (fseek(out.output, 0, SEEK_SET) || fwrite(header, 1, sizeof(header), out.output) != sizeof(header) || fflush(out.output)) {
    result = AVERROR(EIO); goto done;
  }
  result = 0;
done:
  if (out.output) fclose(out.output);
  swr_free(&out.resampler); av_channel_layout_uninit(&out.channels); av_free(out.samples);
  av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&codec); avformat_close_input(&format);
  if (result < 0) {
    if (out.output && output_path) remove(output_path);
    if (error && error_capacity) av_strerror(result, error, error_capacity);
  } else if (error && error_capacity) error[0] = 0;
  return result;
}

__attribute__((visibility("default")))
int spotify_ffmpeg_decode_file(const char *input_path, const char *output_path,
    char *error, size_t error_capacity) {
  return spotify_ffmpeg_decode_file_cancellable(input_path, output_path, error, error_capacity, NULL);
}
