/* Prepared standalone decoder. No App/microphone/network; not compiled here. */
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libavutil/avconfig.h>
#include <libswresample/swresample.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define OUT_RATE 16000
#define CHUNK 320             /* 20ms mono float32. */
#define HEADER 112
#define MAX_SAMPLES (OUT_RATE * 120)
#define LINEAR_CREDIT_CAPACITY 11584
#define LINEAR_EXTERNAL_SAMPLE_CAP 11584
#define LINEAR_C_BUFFER_CAP 16000
_Static_assert(LIBAVFORMAT_VERSION_MAJOR == 63 && LIBAVCODEC_VERSION_MAJOR == 63 &&
               LIBAVUTIL_VERSION_MAJOR == 61 && LIBSWRESAMPLE_VERSION_MAJOR == 7,
               "Requires reviewed FFmpeg 9 ABI 63/63/61/7");
_Static_assert(sizeof(float) == 4 && AV_HAVE_BIGENDIAN == 0, "SPCM Float32 little-endian payload required");

typedef struct { uint64_t sequence, end; } LinearCredit;
typedef struct {
  AVFormatContext *format;
  AVIOContext *io;
  AVCodecContext *codec;
  SwrContext *swr;
  AVChannelLayout input_layout;
  enum AVSampleFormat input_format;
  int rate, stream, paused, paced, cancelled, next_used, failed, has_input, seek_floor_active, source_fd, cancel_reported, control_eof, graceful_limit, input_limit_reached;
  struct stat source_fingerprint;
  uint64_t epoch, segment, sequence, item, next_item, decoded_frames, output_samples, max_samples;
  const char *input, *next_input;
  int next_stream;
  double speed, pace_deadline, pace_paused_at;
  int pace_deadline_valid;
  int first_block_hold, first_block_emitted, first_block_waiting;
  AVRational time_base;
  int64_t previous_source_end, swr_next_output, denominator;
  int64_t seek_target_us;
  int range_floor_active;
  int64_t range_target_num, range_target_den;
  uint64_t range_preroll_samples, range_preroll_frames;
  int previous_pts_valid, swr_pts_valid;
  char controls[512];
  size_t control_used;
  int persistent_windows, linear_prime_done, linear_held, linear_last_pts_known, linear_source_eof, linear_fp_verified;
  int linear_fd_close_confirmed;
  uint64_t linear_window, linear_window_samples, linear_credited, linear_credit_sequence;
  uint64_t linear_control_serial, linear_converted, linear_packets, linear_work_packets, linear_work_quantum;
  uint64_t linear_window_records;
  int64_t linear_last_end, linear_next_start;
  unsigned linear_credit_head, linear_credit_count;
  LinearCredit linear_credit[LINEAR_CREDIT_CAPACITY];
} Decoder;

static volatile sig_atomic_t stop_requested;
static double monotonic(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void on_signal(int value) { (void)value; stop_requested = 1; }
static int interrupted(void *opaque) { (void)opaque; return stop_requested != 0; }
static int fail(const char *category, int code) {
  fprintf(stderr, "{\"event\":\"error\",\"category\":\"%s\",\"av_error_code\":%d}\n", category, code);
  return 0;
}
static void event(Decoder *d, const char *name, const char *reason) {
  fprintf(stderr, "{\"event\":\"%s\",\"reason\":\"%s\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 "}\n",
          name, reason, d->epoch, d->segment, d->item);
}
static int uint_value(const char *value, uint64_t *out) {
  if (!value || !*value || *value == '-' || *value == '+') return 0;
  errno = 0; char *end; unsigned long long n = strtoull(value, &end, 10);
  if (errno || *end) return 0; *out = n; return 1;
}
static int signed_value(const char *value, int64_t *out) {
  if (!value || !*value) return 0;
  errno = 0; char *end; long long n = strtoll(value, &end, 10);
  if (errno || *end || n == AV_NOPTS_VALUE) return 0; *out = n; return 1;
}
static int local_file(const char *path) {
  struct stat info;
  if (!path || path[0] != '/' || strnlen(path, 4096) == 4096) return 0;
  for (const unsigned char *p = (const unsigned char *)path; *p; ++p) if (*p < 32 || *p == 127) return 0;
  return stat(path, &info) == 0 && S_ISREG(info.st_mode);
}
static int source_read(void *opaque, uint8_t *buffer, int count) {
  Decoder *d = opaque;
  if (stop_requested || d->cancelled) return AVERROR_EXIT;
  ssize_t n = read(d->source_fd, buffer, count);
  return n > 0 ? (int)n : n == 0 ? AVERROR_EOF : AVERROR(errno);
}
static int64_t source_seek(void *opaque, int64_t offset, int whence) {
  Decoder *d = opaque;
  if (whence == AVSEEK_SIZE) return d->source_fingerprint.st_size;
  whence &= ~AVSEEK_FORCE;
  if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return AVERROR(EINVAL);
  off_t result = lseek(d->source_fd, offset, whence);
  return result < 0 ? AVERROR(errno) : result;
}
static void reset_swr(Decoder *d, const char *reason) {
  if (d->swr) {
    fprintf(stderr, "{\"event\":\"resampler_discard\",\"reason\":\"%s\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"delay_units\":%" PRId64 ",\"time_denominator\":%" PRId64 "}\n",
            reason, d->epoch, d->segment, swr_is_initialized(d->swr) ? swr_get_delay(d->swr, d->denominator) : 0, d->denominator);
    swr_free(&d->swr);
  }
  av_channel_layout_uninit(&d->input_layout);
  d->rate = 0; d->previous_pts_valid = d->swr_pts_valid = d->has_input = 0;
  d->previous_source_end = d->swr_next_output = AV_NOPTS_VALUE;
}
static void close_media(Decoder *d, const char *reason) {
  reset_swr(d, reason); avcodec_free_context(&d->codec); avformat_close_input(&d->format);
  if (d->io) { av_freep(&d->io->buffer); avio_context_free(&d->io); }
  if (d->source_fd >= 0) {
    struct stat end;
    if (fstat(d->source_fd, &end) || end.st_dev != d->source_fingerprint.st_dev ||
        end.st_ino != d->source_fingerprint.st_ino || end.st_size != d->source_fingerprint.st_size ||
        end.st_mtimespec.tv_sec != d->source_fingerprint.st_mtimespec.tv_sec ||
        end.st_mtimespec.tv_nsec != d->source_fingerprint.st_mtimespec.tv_nsec) {
      fail("source_fd_changed", -1); d->failed = 1;
    }
    int closed_fd = d->source_fd; int close_result = close(closed_fd); int close_error = close_result < 0 ? errno : 0;
    d->source_fd = -1;
    if (d->persistent_windows) {
      d->linear_fd_close_confirmed = close_result == 0;
      if (close_result < 0) { fail("linear_source_close_failed", close_error); d->failed = 1; }
    }
  }
}
static int open_held_media(Decoder *d, const char *path, int stream) {
  d->format = avformat_alloc_context();
  if (!d->format) return fail("format_allocation", AVERROR(ENOMEM));
  unsigned char *buffer = av_malloc(32768);
  d->io = buffer ? avio_alloc_context(buffer, 32768, 0, d, source_read, NULL, source_seek) : NULL;
  if (!d->io) { av_free(buffer); return fail("custom_avio_allocation", AVERROR(ENOMEM)); }
  d->format->pb = d->io; d->format->flags |= AVFMT_FLAG_CUSTOM_IO;
  d->format->interrupt_callback = (AVIOInterruptCB){interrupted, NULL};
  AVDictionary *options = NULL;
  /* Input is this already-open FD; demuxer nested protocol opens are forbidden. */
  av_dict_set(&options, "protocol_whitelist", "", 0);
  av_dict_set(&options, "probesize", "4194304", 0);
  av_dict_set(&options, "analyzeduration", "5000000", 0);
  int code = avformat_open_input(&d->format, NULL, NULL, &options); av_dict_free(&options);
  if (code < 0 || (code = avformat_find_stream_info(d->format, NULL)) < 0) return fail("demux_open_or_probe", code);
  if (stream < 0 || stream >= (int)d->format->nb_streams || d->format->streams[stream]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO)
    return fail("selected_stream_is_not_audio", -1);
  AVStream *s = d->format->streams[stream];
  const AVCodec *codec = avcodec_find_decoder(s->codecpar->codec_id);
  d->codec = codec ? avcodec_alloc_context3(codec) : NULL;
  if (!d->codec) return fail("audio_decoder_unavailable", -1);
  if ((code = avcodec_parameters_to_context(d->codec, s->codecpar)) < 0) return fail("codec_parameters", code);
  d->codec->pkt_timebase = s->time_base; d->codec->thread_count = 1;
  if ((code = avcodec_open2(d->codec, codec, NULL)) < 0) return fail("codec_open", code);
  if (s->time_base.num <= 0 || s->time_base.den <= 0) return fail("invalid_stream_time_base", -1);
  d->input = path; d->stream = stream; d->time_base = s->time_base;
  fprintf(stderr, "{\"event\":\"source_fd_fingerprint\",\"epoch\":%" PRIu64 ",\"item\":%" PRIu64 ",\"device\":%" PRIu64 ",\"inode\":%" PRIu64 ",\"bytes\":%" PRId64 ",\"mtime_seconds\":%" PRId64 ",\"mtime_nanoseconds\":%ld,\"nofollow\":true,\"custom_avio\":true}\n",
          d->epoch, d->item, (uint64_t)d->source_fingerprint.st_dev, (uint64_t)d->source_fingerprint.st_ino,
          (int64_t)d->source_fingerprint.st_size, (int64_t)d->source_fingerprint.st_mtimespec.tv_sec,
          d->source_fingerprint.st_mtimespec.tv_nsec);
  fprintf(stderr, "{\"event\":\"media_opened\",\"epoch\":%" PRIu64 ",\"item\":%" PRIu64 ",\"selected_stream_index\":%d,\"stream_id\":%d,\"codec_id\":%d,\"time_base\":[%d,%d],\"format_start_time\":%" PRId64 ",\"stream_start_time\":%" PRId64 "}\n",
          d->epoch, d->item, stream, s->id, s->codecpar->codec_id, s->time_base.num, s->time_base.den,
          d->format->start_time, s->start_time);
  return 1;
}
static int open_media(Decoder *d, const char *path, int stream) {
  d->pace_deadline_valid = 0; d->pace_paused_at = 0;
  if (!local_file(path)) return fail("local_regular_file_required", -1);
  d->source_fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (d->source_fd < 0 || fstat(d->source_fd, &d->source_fingerprint) || !S_ISREG(d->source_fingerprint.st_mode))
    return fail("regular_nofollow_source_fd_required", errno);
  return open_held_media(d, path, stream);
}

static int same_source_fingerprint(const struct stat *a, const struct stat *b) {
  return S_ISREG(b->st_mode) && a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
    a->st_size == b->st_size && a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
    a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}
static int reopen_original_held_source(Decoder *d, uint64_t next, int64_t num, int64_t den) {
  struct stat observed;
  if (d->source_fd < 0 || fstat(d->source_fd, &observed) ||
      !same_source_fingerprint(&d->source_fingerprint, &observed)) return fail("range_source_fd_changed", -1);
  if (d->segment == UINT64_MAX || d->failed || d->cancelled || stop_requested) return fail("range_unavailable", -1);
  int held = d->source_fd, stream = d->stream; const char *path = d->input;
  /* AV contexts can be recreated, but this exact original owned FD never closes
     or reopens a path. A replacement pathname cannot change our source. */
  reset_swr(d, "range_redecode"); avcodec_free_context(&d->codec); avformat_close_input(&d->format);
  if (d->io) { av_freep(&d->io->buffer); avio_context_free(&d->io); }
  /* All AV close callbacks still see the live original FD; no sentinel gap. */
  if (lseek(held, 0, SEEK_SET) != 0) return fail("range_source_rewind", errno);
  d->epoch = next; ++d->segment;
  d->pace_deadline_valid = 0; d->pace_paused_at = 0;
  d->seek_floor_active = 0; d->range_floor_active = 1;
  d->range_target_num = num; d->range_target_den = den;
  d->range_preroll_samples = d->range_preroll_frames = 0;
  if (!open_held_media(d, path, stream) || fstat(held, &observed) ||
      !same_source_fingerprint(&d->source_fingerprint, &observed)) return fail("range_source_fd_changed", -1);
  fprintf(stderr, "{\"event\":\"range_origin_reopened\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"target_num\":%" PRId64 ",\"target_den\":%" PRId64 ",\"selected_stream_index\":%d,\"source_fingerprint_preserved\":true}\n",
      d->epoch, d->segment, d->item, num, den, stream);
  /* This confirms the actual reopen/control only. It does not claim PCM at num/den. */
  event(d, "epoch_changed", "range_reopened_held_fd_target_not_assumed_sample");
  return 1;
}
static int controls(Decoder *d); /* Applies controls only between synchronous calls. */
static void pause_wait(Decoder *d) {
  while (d->paused && !stop_requested && !d->cancelled) {
    controls(d); struct pollfd fd = {d->control_eof ? -1 : STDIN_FILENO, POLLIN, 0}; poll(&fd, 1, 10);
  }
}
/* Optional startup handshake: only the first fully written current-ticket
   SPCM block enters this gate. It is not a pause ACK. A matching explicit
   PAUSE command must actually run; normal paused control then holds the source
   until RESUME/SEEK/CANCEL. No next packet or media EOF races the host proof. */
static int first_block_wait(Decoder *d) {
  double deadline = monotonic() + 5.0;
  while (d->first_block_waiting && !stop_requested && !d->cancelled) {
    if (!controls(d)) return 0;
    if (!d->first_block_waiting || stop_requested || d->cancelled) break;
    if (monotonic() >= deadline) {
      d->failed = 1; return fail("first_block_handshake_deadline", -1);
    }
    struct pollfd fd = {d->control_eof ? -1 : STDIN_FILENO, POLLIN, 0};
    poll(&fd, 1, 10);
  }
  return !d->failed;
}
static void pace(Decoder *d, int count) {
  if (!d->paced) return;
  /* One accumulated wall-clock deadline; decode/write/poll cost is included
     instead of being added again after every PCM chunk. Raw media PTS stays
     untouched. A pause shifts this deadline; a new input/seek resets it. */
  if (!d->pace_deadline_valid) {
    d->pace_deadline = monotonic(); d->pace_deadline_valid = 1;
  }
  d->pace_deadline += (double)count / (OUT_RATE * d->speed);
  uint64_t epoch = d->epoch;
  while (!stop_requested && !d->cancelled && epoch == d->epoch) {
    controls(d);
    if (stop_requested || d->cancelled || epoch != d->epoch) break;
    if (d->paused) { pause_wait(d); continue; }
    double left = d->pace_deadline - monotonic();
    if (left <= 0) break;
    int timeout = (int)ceil(FFMIN(left * 1000.0, 5.0));
    struct pollfd fd = {d->control_eof ? -1 : STDIN_FILENO, POLLIN, 0};
    poll(&fd, 1, timeout);
  }
}
static void le32(unsigned char *p, uint32_t v) { for (int i = 0; i < 4; ++i) p[i] = (unsigned char)(v >> (i * 8)); }
static void le64(unsigned char *p, uint64_t v) { for (int i = 0; i < 8; ++i) p[i] = (unsigned char)(v >> (i * 8)); }
static int write_record(Decoder *d, const unsigned char *bytes, size_t length, uint64_t epoch) {
  size_t done = 0; double deadline = monotonic() + 3;
  while (done < length) {
    if (!done && (epoch != d->epoch || stop_requested || d->cancelled)) return 0;
    ssize_t count = write(STDOUT_FILENO, bytes + done, length - done);
    if (count > 0) { done += (size_t)count; continue; }
    if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return -1;
    /* Continue polling controls even when PCM stdout is full. A partially
       committed record finishes under its old ticket; the consumer rejects
       stale epochs. Never insert a new header into an incomplete payload. */
    controls(d);
    /* Unpaced continuation transport can be deliberately held by the Host's
       two-second ring budget. Exclude only a real same-epoch PAUSE interval
       from the existing three-second ACTIVE write budget, never reset it on
       RESUME. Cancellation, error, signal or epoch replacement cannot keep an
       old partially committed record indefinitely in this paused wait. */
    if ((!d->paced || d->persistent_windows) && d->paused && epoch == d->epoch && !d->failed &&
        !stop_requested && !d->cancelled) {
      double held_at = monotonic();
      fprintf(stderr, "{\"event\":\"blocked_write_pause\",\"epoch\":%" PRIu64 ",\"record_epoch\":%" PRIu64 ",\"written_bytes\":%zu,\"record_bytes\":%zu}\n",
              d->epoch, epoch, done, length);
      while (d->paused && epoch == d->epoch && !d->failed &&
             !stop_requested && !d->cancelled) {
        if (!controls(d)) break;
        if (!d->paused || epoch != d->epoch || d->failed || stop_requested || d->cancelled) break;
        struct pollfd fd = {d->control_eof ? -1 : STDIN_FILENO, POLLIN, 0};
        poll(&fd, 1, 10);
      }
      deadline += monotonic() - held_at;
    }
    if (monotonic() >= deadline) { fail("pcm_backpressure_deadline", -1); d->failed = 1; return -1; }
    struct pollfd fds[2] = {{d->control_eof ? -1 : STDIN_FILENO, POLLIN, 0}, {STDOUT_FILENO, POLLOUT, 0}};
    poll(fds, 2, 10);
  }
  return 1;
}
static int linear_publication_budget(Decoder *d, int remaining, int samples, uint64_t epoch) {
  if (!d->persistent_windows) return 1;
  int pending = d->swr ? swr_get_out_samples(d->swr,0) : 0;
  if (pending < 0 || remaining < 0 || samples < 1 ||
      (uint64_t)remaining + (uint64_t)pending + (uint64_t)samples > LINEAR_C_BUFFER_CAP)
    return fail("linear_converted_swr_record_budget",-1);
  double active_deadline = monotonic()+3;
  while (!stop_requested && !d->cancelled && epoch==d->epoch) {
    uint64_t outstanding=d->linear_window_samples-d->linear_credited;
    uint64_t reserved=(uint64_t)remaining+(uint64_t)pending+(uint64_t)samples;
    if (outstanding+(uint64_t)samples<=LINEAR_EXTERNAL_SAMPLE_CAP &&
        outstanding+(uint64_t)samples+reserved<=32000) {
      fprintf(stderr,"{\"event\":\"provider_budget\",\"epoch\":%" PRIu64 ",\"window\":%" PRIu64 ",\"for_sequence\":%" PRIu64 ",\"converted_remaining\":%d,\"swr_out_upper\":%d,\"record_copy_samples\":%d,\"published_unaccepted\":%" PRIu64 ",\"reserved_total\":%" PRIu64 ",\"external_cap\":11584}\n",d->epoch,d->linear_window,d->sequence+1,remaining,pending,samples,outstanding,outstanding+(uint64_t)samples+reserved);
      return 1;
    }
    if(!controls(d))return 0;
    if(d->paused) {
      double began=monotonic();pause_wait(d);active_deadline+=monotonic()-began;
    }
    if(monotonic()>=active_deadline)return fail("linear_actual_accept_credit_deadline",-1);
    struct pollfd fd={d->control_eof?-1:STDIN_FILENO,POLLIN,0};poll(&fd,1,10);
  }
  return !d->failed;
}

static int publish(Decoder *d, float *pcm, int count, int64_t source_pts, int64_t pts,
                   int64_t delay, int drain, uint64_t ordinal, int block_offset) {
  uint64_t epoch = d->epoch;
  int begin = 0;
  if (d->range_floor_active) {
    if (pts == AV_NOPTS_VALUE) return fail("range_missing_pts", -1);
    __int128 distance = (__int128)d->range_target_num * d->denominator
                      - (__int128)pts * d->range_target_den;
    __int128 step = (__int128)d->rate * d->range_target_den;
    if (distance > 0) {
      __int128 skipped = (distance + step - 1) / step;
      begin = skipped >= count ? count : (int)skipped;
    }
    if (UINT64_MAX - d->range_preroll_samples < (uint64_t)begin || d->range_preroll_frames == UINT64_MAX)
      return fail("range_preroll_counter_bound", -1);
    d->range_preroll_samples += (uint64_t)begin; ++d->range_preroll_frames;
    if (begin < count) {
      int64_t first = pts + (int64_t)begin * d->rate;
      int exact = (__int128)first * d->range_target_den
                == (__int128)d->range_target_num * d->denominator;
      fprintf(stderr, "{\"event\":\"range_first_sample\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"stream_index\":%d,\"target_num\":%" PRId64 ",\"target_den\":%" PRId64 ",\"pcm_pts\":%" PRId64 ",\"time_denominator\":%" PRId64 ",\"exact\":%s,\"preroll_samples_not_published\":%" PRIu64 ",\"preroll_converted_frames\":%" PRIu64 ",\"source_pts\":%" PRId64 ",\"delay_units_before_convert\":%" PRId64 ",\"converted_frame_offset\":%d}\n",
          d->epoch, d->segment, d->item, d->stream, d->range_target_num, d->range_target_den,
          first, d->denominator, exact ? "true" : "false", d->range_preroll_samples,
          d->range_preroll_frames, source_pts, delay, block_offset + begin);
      d->range_floor_active = 0; /* Actual unchanged PTS in the SPCM header remains authoritative. */
    }
  }
  if (d->seek_floor_active && pts != AV_NOPTS_VALUE) {
    int64_t floor = av_rescale_q(d->seek_target_us, AV_TIME_BASE_Q, (AVRational){1,(int)d->denominator});
    if (floor > pts) begin = (int)FFMIN(count, (floor - pts + d->rate - 1) / d->rate);
    if (begin) fprintf(stderr, "{\"event\":\"seek_preroll_trim\",\"epoch\":%" PRIu64 ",\"decoded_frame\":%" PRIu64 ",\"samples_not_published\":%d,\"raw_media_target_us\":%" PRId64 "}\n", d->epoch, ordinal, begin, d->seek_target_us);
    if (begin < count) d->seek_floor_active = 0;
  }
  for (int offset = begin; offset < count && !stop_requested && !d->cancelled; offset += CHUNK) {
    controls(d); if(!d->persistent_windows || d->linear_prime_done)pause_wait(d);
    if (epoch != d->epoch || stop_requested || d->cancelled) return 1; /* No stale publication after acknowledged epoch. */
    int samples = FFMIN(CHUNK, count - offset);
    if(d->persistent_windows && d->linear_window_samples+(uint64_t)samples>d->max_samples) {
      int64_t next=pts==AV_NOPTS_VALUE?AV_NOPTS_VALUE:pts+(int64_t)offset*d->rate;
      if(!d->linear_last_pts_known || next==AV_NOPTS_VALUE || next!=d->linear_last_end || d->linear_held)
        return fail("linear_boundary_real_source_seam",-1);
      d->linear_held=1;d->linear_next_start=next;
      fprintf(stderr,"{\"event\":\"provider_window_held\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":%" PRIu64 ",\"stream_index\":%d,\"output_samples\":%" PRIu64 ",\"last_sequence\":%" PRIu64 ",\"raw_end_num\":%" PRId64 ",\"raw_end_den\":%" PRId64 ",\"next_start_num\":%" PRId64 ",\"next_start_den\":%" PRId64 ",\"next_samples_held\":%d,\"converted_remaining\":%d,\"decoder_contexts_live\":true,\"held_fd\":%d,\"monotonic_seconds\":%.9f}\n",
        d->epoch,d->segment,d->item,d->linear_window,d->stream,d->linear_window_samples,d->sequence,d->linear_last_end,d->denominator,next,d->denominator,samples,count-offset,d->source_fd,monotonic());
      while(d->linear_held && epoch==d->epoch && !stop_requested && !d->cancelled) {
        if(!controls(d))return 0;
        if(d->linear_held){struct pollfd fd={d->control_eof?-1:STDIN_FILENO,POLLIN,0};poll(&fd,1,10);}
      }
      if(epoch!=d->epoch || stop_requested || d->cancelled)return !d->failed;
      fprintf(stderr,"{\"event\":\"frame_anchor_reused\",\"window\":%" PRIu64 ",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"decoded_frame\":%" PRIu64 ",\"source_pts\":%" PRId64 ",\"converted_offset\":%d,\"actual_same_allocation\":true,\"monotonic_seconds\":%.9f}\n",d->linear_window,d->epoch,d->segment,ordinal,source_pts,block_offset+offset,monotonic());
    }
    if (!d->persistent_windows && d->output_samples + (uint64_t)samples > d->max_samples) {
      if (!d->graceful_limit) return fail("output_sample_bound", -1);
      d->input_limit_reached = 1;
      fprintf(stderr, "{\"event\":\"input_limit_reached\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"max_samples\":%" PRIu64 ",\"output_samples\":%" PRIu64 ",\"next_chunk_samples_not_published\":%d}\n",
              d->epoch, d->segment, d->item, d->max_samples, d->output_samples, samples);
      return 1; /* No part of this next whole SPCM chunk is published. */
    }
    if(d->persistent_windows && (d->sequence==UINT64_MAX || d->linear_window_records>=16384))return fail("linear_sequence_or_original_ledger_bound",-1);
    if(!linear_publication_budget(d,count-offset,samples,epoch))return 0;
    if(epoch!=d->epoch || stop_requested || d->cancelled)return !d->failed;
    for (int i = 0; i < samples; ++i) if (!isfinite(pcm[offset + i])) return fail("nonfinite_pcm", -1);
    int known = pts != AV_NOPTS_VALUE;
    if(d->persistent_windows && !known)return fail("linear_no_unknown_source_pts_publication",-1);
    int64_t chunk_pts = known ? pts + (int64_t)offset * d->rate : AV_NOPTS_VALUE;
    uint64_t segment = d->segment, item = d->item, sequence = d->sequence + 1;
    int stream = d->stream; int64_t denominator = d->denominator;
    unsigned char header[HEADER] = {'S','P','C','M',1,0,HEADER,0};
    le32(header + 8, HEADER + samples * 4);
    le32(header + 12, (known ? 1 : 0) | (known && chunk_pts < 0 ? 2 : 0) | (drain ? 4 : 0));
    le64(header + 16, d->epoch); le64(header + 24, d->segment); le64(header + 32, d->item);
    le32(header + 40, d->stream); le32(header + 44, d->time_base.num); le32(header + 48, d->time_base.den);
    le32(header + 52, OUT_RATE); le64(header + 56, (uint64_t)source_pts); le64(header + 64, (uint64_t)chunk_pts);
    le64(header + 72, d->denominator); le64(header + 80, delay);
    le64(header + 88, sequence); le32(header + 96, samples); le32(header + 100, d->rate);
    le32(header + 104, (uint32_t)ordinal); le32(header + 108, (uint32_t)(block_offset + offset));
    unsigned char packet[HEADER + CHUNK * sizeof(float)];
    memcpy(packet, header, HEADER); memcpy(packet + HEADER, pcm + offset, samples * sizeof(float));
    if(d->persistent_windows && !d->linear_prime_done) {
      d->linear_prime_done=1;d->paused=1;
      fprintf(stderr,"{\"event\":\"provider_primed\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":%" PRIu64 ",\"published\":false,\"record_hex\":\"",epoch,segment,item,d->linear_window);
      for(size_t i=0;i<HEADER+(size_t)samples*sizeof(float);++i)fprintf(stderr,"%02x",packet[i]);
      fprintf(stderr,"\",\"held_fd\":%d,\"monotonic_seconds\":%.9f}\n",d->source_fd,monotonic());
      pause_wait(d);
      if(epoch!=d->epoch || stop_requested || d->cancelled)return !d->failed;
    }
    if (d->paced && !d->pace_deadline_valid) {
      d->pace_deadline = monotonic(); d->pace_deadline_valid = 1;
    }
    int wrote = write_record(d, packet, HEADER + samples * sizeof(float), epoch);
    if (wrote < 0) return fail("pcm_sink_failure", errno);
    if (!wrote) return 1;
    d->sequence = sequence;
    if(d->persistent_windows && epoch==d->epoch) {
      if(d->linear_credit_count>=LINEAR_CREDIT_CAPACITY || UINT64_MAX-d->output_samples<(uint64_t)samples)
        return fail("linear_actual_publication_counter_or_pts",-1);
      d->linear_window_samples+=(uint64_t)samples;++d->linear_window_records;
      unsigned at=(d->linear_credit_head+d->linear_credit_count)%LINEAR_CREDIT_CAPACITY;
      d->linear_credit[at]=(LinearCredit){sequence,d->linear_window_samples};++d->linear_credit_count;
      d->linear_last_end=chunk_pts+(int64_t)samples*d->rate;d->linear_last_pts_known=1;
    }
    d->output_samples += samples;
    fprintf(stderr, "{\"event\":\"pcm\",\"sequence\":%" PRIu64 ",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"stream_index\":%d,\"decoded_frame\":%" PRIu64 ",\"source_pts\":%" PRId64 ",\"pcm_pts\":%" PRId64 ",\"pts_known\":%s,\"negative_pts\":%s,\"samples\":%d,\"time_denominator\":%" PRId64 ",\"delay_units_before_convert\":%" PRId64 ",\"drain_from_last_real_anchor\":%s,\"completed_old_epoch_inflight_record\":%s}\n",
            sequence, epoch, segment, item, stream, ordinal, source_pts, chunk_pts,
            known ? "true" : "false", known && chunk_pts < 0 ? "true" : "false", samples, denominator, delay, drain ? "true" : "false",
            epoch != d->epoch ? "true" : "false");
    if (d->first_block_hold && !d->first_block_emitted && epoch == d->epoch && !stop_requested && !d->cancelled) {
      d->first_block_emitted = d->first_block_waiting = 1;
      fprintf(stderr, "{\"event\":\"first_block_waiting\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"sequence\":%" PRIu64 ",\"samples\":%d,\"record_bytes\":%zu,\"header_bytes\":112}\n",
              epoch, segment, item, sequence, samples, (size_t)(HEADER + samples * sizeof(float)));
      if (!first_block_wait(d)) return 0;
      pause_wait(d); /* Even unpaced one-sample WAV must remain alive paused. */
    }
    if (epoch == d->epoch) pace(d, samples);
    if (epoch != d->epoch) return 1;
  }
  return 1;
}
static int frame_bounds(const AVFrame *frame) {
  if (frame->sample_rate < 8000 || frame->sample_rate > 96000 || frame->nb_samples <= 0 || frame->nb_samples > 65536 ||
      frame->ch_layout.nb_channels <= 0 || frame->ch_layout.nb_channels > 16) return fail("audio_frame_bounds", -1);
  return 1;
}
static int create_swr(Decoder *d, AVFrame *frame) {
  if (!frame_bounds(frame)) return 0;
  d->rate = frame->sample_rate; d->denominator = (int64_t)d->rate * OUT_RATE;
  AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
  int code = swr_alloc_set_opts2(&d->swr, &mono, AV_SAMPLE_FMT_FLT, OUT_RATE,
                               &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
  if (code < 0 || !d->swr) return fail("resampler_allocation", code);
  if ((code = av_opt_set_double(d->swr, "min_comp", FLT_MAX, 0)) < 0 || (code = swr_init(d->swr)) < 0)
    return fail("resampler_initialization", code);
  double compensation;
  if (av_opt_get_double(d->swr, "min_comp", 0, &compensation) < 0 || compensation < FLT_MAX)
    return fail("unexpected_timestamp_compensation", -1);
  d->input_format = frame->format;
  if (av_channel_layout_copy(&d->input_layout, &frame->ch_layout) < 0) return fail("layout_copy", -1);
  return 1;
}
static int decoded_frame(Decoder *d, AVFrame *frame) {
  if (!frame_bounds(frame)) return 0; /* Required for every frame, including reused swr. */
  if(d->persistent_windows && d->decoded_frames>=UINT32_MAX)return fail("linear_real_frame_ordinal_bound",-1);
  uint64_t ordinal = ++d->decoded_frames, epoch = d->epoch;
  /* best_effort_timestamp is explicitly documented in stream time_base. */
  int64_t source = frame->best_effort_timestamp;
  int known = source != AV_NOPTS_VALUE;
  if (d->swr && (d->rate != frame->sample_rate || d->input_format != frame->format ||
                 av_channel_layout_compare(&d->input_layout, &frame->ch_layout))) {
    reset_swr(d, "audio_format_changed"); ++d->segment;
  }
  if (!d->swr && !create_swr(d, frame)) return 0;
  int64_t scaled = known ? av_rescale_q_rnd(source, d->time_base, (AVRational){1, (int)d->denominator}, AV_ROUND_NEAR_INF) : AV_NOPTS_VALUE;
  if (known && scaled == AV_NOPTS_VALUE) return fail("pts_rescale_overflow", -1);
  if (known && (scaled < -INT64_C(1000000000000000) || scaled > INT64_C(1000000000000000)))
    return fail("bounded_source_timestamp_required", -1);
  /* Container clock quantization (e.g. MKV milliseconds) is observable error.
     Do not mislabel ordinary timestamp rounding as a seek/discontinuity. */
  int64_t tolerance = 2 * av_rescale_q(1, d->time_base, (AVRational){1,(int)d->denominator}) + (int64_t)d->rate * 2;
  int discontinuity = d->has_input && (known != d->previous_pts_valid ||
      (known && llabs(scaled - d->previous_source_end) > tolerance));
  if (discontinuity) {
    reset_swr(d, known ? "source_pts_jump" : "missing_source_pts"); ++d->segment;
    if (!create_swr(d, frame)) return 0;
  }
  fprintf(stderr, "{\"event\":\"decoded_frame\",\"ordinal\":%" PRIu64 ",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"stream_index\":%d,\"best_effort_timestamp\":%" PRId64 ",\"frame_pts\":%" PRId64 ",\"frame_time_base\":[%d,%d],\"stream_time_base\":[%d,%d],\"source_pts_known\":%s,\"input_samples\":%d,\"input_rate\":%d,\"source_discontinuity\":%s}\n",
          ordinal, d->epoch, d->segment, d->item, d->stream, source, frame->pts, frame->time_base.num, frame->time_base.den,
          d->time_base.num, d->time_base.den, known ? "true" : "false", frame->nb_samples, frame->sample_rate, discontinuity ? "true" : "false");
  int64_t delay = swr_get_delay(d->swr, d->denominator);
  int64_t pts = known ? swr_next_pts(d->swr, scaled) : AV_NOPTS_VALUE;
  if (known && pts != scaled - delay) return fail("unexpected_delay_compensation", -1);
  int capacity = swr_get_out_samples(d->swr, frame->nb_samples);
  if (capacity <= 0 || capacity > 262144) return fail("resampler_output_bound", -1);
  if(d->persistent_windows) {
    int delayed_upper = swr_get_out_samples(d->swr, 0);
    if (delayed_upper < 0 || (uint64_t)capacity + (uint64_t)delayed_upper + CHUNK > LINEAR_C_BUFFER_CAP)
      return fail("linear_supported_frame_budget",-1);
  }
  float *pcm = av_malloc_array((size_t)capacity, sizeof(float));
  if (!pcm) return fail("pcm_allocation", AVERROR(ENOMEM));
  uint8_t *output[] = {(uint8_t *)pcm};
  int count = swr_convert(d->swr, output, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
  if(d->persistent_windows && count>=0) {
    if(UINT64_MAX-d->linear_converted<(uint64_t)count){av_free(pcm);return fail("linear_converted_counter_bound",-1);}
    d->linear_converted+=(uint64_t)count;
  }
  int success = count >= 0 && publish(d, pcm, count, source, pts, delay, 0, ordinal, 0); av_free(pcm);
  if (epoch == d->epoch) {
    d->has_input = 1;
    d->previous_pts_valid = d->swr_pts_valid = known;
    d->previous_source_end = known ? scaled + (int64_t)frame->nb_samples * OUT_RATE : AV_NOPTS_VALUE;
    d->swr_next_output = known ? pts + (int64_t)count * d->rate : AV_NOPTS_VALUE;
  }
  return success ? 1 : fail("audio_conversion", count);
}
static int receive(Decoder *d, AVFrame *frame) {
  for (;;) {
    uint64_t epoch = d->epoch;
    int code = avcodec_receive_frame(d->codec, frame);
    if (code == AVERROR(EAGAIN) || code == AVERROR_EOF) return 1;
    if (code < 0) return fail("audio_receive", code);
    int success = decoded_frame(d, frame); av_frame_unref(frame);
    if (!success || stop_requested || d->cancelled || d->input_limit_reached || epoch != d->epoch) return success;
  }
}
static int drain(Decoder *d) {
  if (!d->swr) return 1;
  uint64_t epoch = d->epoch;
  for (int i = 0; i < 128 && epoch == d->epoch; ++i) {
    if (d->persistent_windows) {
      int delayed_upper = swr_get_out_samples(d->swr, 0);
      if (delayed_upper < 0 || (uint64_t)delayed_upper + 4096 + CHUNK > LINEAR_C_BUFFER_CAP)
        return fail("linear_supported_drain_budget", -1);
    }
    float pcm[4096]; uint8_t *out[] = {(uint8_t *)pcm};
    int64_t delay = swr_get_delay(d->swr, d->denominator);
    int count = swr_convert(d->swr, out, 4096, NULL, 0);
    if (count < 0) return fail("resampler_drain", count);
    if(d->persistent_windows && count>0) {
      if(UINT64_MAX-d->linear_converted<(uint64_t)count)return fail("linear_drain_counter_bound",-1);
      d->linear_converted+=(uint64_t)count;
    }
    if (!count) return 1;
    int64_t pts = d->swr_pts_valid ? d->swr_next_output : AV_NOPTS_VALUE;
    if (!publish(d, pcm, count, AV_NOPTS_VALUE, pts, delay, 1, d->decoded_frames, 0)) return 0;
    if (d->input_limit_reached) return 1;
    if (epoch == d->epoch && d->swr_pts_valid) d->swr_next_output += (int64_t)count * d->rate;
  }
  return epoch != d->epoch ? 1 : fail("resampler_drain_limit", -1);
}
static int legacy_command(Decoder *d, char *line) {
  char *parts[5], *rest = NULL; int n = 0;
  for (char *word = strtok_r(line, " \t\r", &rest); word; word = strtok_r(NULL, " \t\r", &rest)) {
    if (n == 5) return fail("control_token_bound", -1); parts[n++] = word;
  }
  uint64_t expected, next = 0, argument = 0; int64_t target = 0;
  if (n < 2 || !uint_value(parts[1], &expected) || expected != d->epoch) { event(d, "control_rejected", "stale_or_invalid_epoch"); return 1; }
  if (n == 2 && !strcmp(parts[0], "PAUSE")) {
    if (!d->paused && d->pace_deadline_valid) d->pace_paused_at = monotonic();
    d->paused = 1; event(d, "paused", "explicit_control");
    if (d->first_block_waiting) {
      d->first_block_waiting = 0;
      event(d, "first_block_pause_confirmed", "explicit_control");
    }
    return 1;
  }
  if (n == 2 && !strcmp(parts[0], "RESUME")) {
    if (d->first_block_waiting) return fail("first_block_requires_pause", -1);
    if (d->paused && d->pace_deadline_valid) d->pace_deadline += monotonic() - d->pace_paused_at;
    d->pace_paused_at = 0; d->paused = 0; event(d, "resumed", "explicit_control"); return 1;
  }
  if (n == 2 && !strcmp(parts[0], "CANCEL")) { d->cancelled = d->cancel_reported = 1; event(d, "cancel_acknowledged", "explicit_control"); return 1; }
  if (n == 3 && !strcmp(parts[0], "SPEED")) {
    char *end; double speed = strtod(parts[2], &end);
    if (*end || !isfinite(speed) || speed < 0.25 || speed > 4) return fail("speed_bound", -1);
    if (d->pace_deadline_valid) {
      double reference = d->paused ? d->pace_paused_at : monotonic();
      d->pace_deadline = reference + (d->pace_deadline - reference) * d->speed / speed;
    }
    d->speed = speed; event(d, "speed_changed", "pace_only_media_pts_unchanged"); return 1;
  }
  if (d->first_block_waiting) return fail("first_block_requires_pause", -1);
  if (n < 3 || !uint_value(parts[2], &next) || next <= d->epoch) return fail("new_epoch_required", -1);
  if (n == 5 && !strcmp(parts[0], "RANGE")) {
    int64_t numerator; uint64_t denominator;
    if (!signed_value(parts[3], &numerator) || !uint_value(parts[4], &denominator) ||
        !denominator || denominator > UINT64_C(1000000000)) return fail("range_target_invalid", -1);
    if ((__int128)numerator < -(__int128)86400 * denominator ||
        (__int128)numerator > (__int128)86400 * denominator) return fail("range_target_bound", -1);
    return reopen_original_held_source(d, next, numerator, (int64_t)denominator);
  }
  /* Ordinary control bodies below are unchanged; an explicit new operation
     retires only a prior uncompleted range crop, never a published packet. */
  if ((n == 4 && (!strcmp(parts[0], "SEEK") || !strcmp(parts[0], "TRACK"))) ||
      (n == 3 && !strcmp(parts[0], "QUEUE"))) d->range_floor_active = 0;
  if (n == 4 && !strcmp(parts[0], "SEEK") && signed_value(parts[3], &target)) {
    if (target < -INT64_C(86400000000) || target > INT64_C(86400000000)) return fail("seek_target_bound", -1);
    int64_t timestamp = av_rescale_q(target, AV_TIME_BASE_Q, d->time_base);
    int code = avformat_seek_file(d->format, d->stream, INT64_MIN, timestamp, timestamp, 0);
    if (code < 0) return fail("seek_failed", code);
    avcodec_flush_buffers(d->codec); reset_swr(d, "seek"); d->epoch = next; ++d->segment;
    d->pace_deadline_valid = 0; d->pace_paused_at = 0;
    d->seek_target_us = target; d->seek_floor_active = 1;
    event(d, "epoch_changed", "seek_acknowledged_target_not_assumed_frame_pts"); return 1;
  }
  if (n == 4 && !strcmp(parts[0], "TRACK") && uint_value(parts[3], &argument) && argument <= INT_MAX) {
    const char *path = d->input;
    close_media(d, "track_switch"); d->epoch = next; ++d->segment; d->seek_floor_active = 0;
    return open_media(d, path, (int)argument);
  }
  if (n == 3 && !strcmp(parts[0], "QUEUE") && d->next_input && !d->next_used) {
    close_media(d, "queue_switch"); d->epoch = next; ++d->segment; d->item = d->next_item; d->next_used = 1; d->seek_floor_active = 0;
    return open_media(d, d->next_input, d->next_stream);
  }
  return fail("unknown_control", -1);
}
/* New long-mode state machine only. Ordinary decoder commands remain below. */
static int legacy_command(Decoder *d, char *line);
static int linear_command(Decoder *d, char *line) {
  char *parts[8], *rest = NULL; int n = 0;
  for (char *word = strtok_r(line, " \t\r", &rest); word; word = strtok_r(NULL, " \t\r", &rest)) {
    if (n == 8) return fail("linear_control_token_bound", -1); parts[n++] = word;
  }
  uint64_t epoch, first, second, last; int64_t num; uint64_t den;
  if (n < 2 || !uint_value(parts[1], &epoch) || epoch != d->epoch)
    return fail("linear_control_epoch_identity", -1);
  if (n == 2 && !strcmp(parts[0], "CANCEL")) {
    char command[96]; snprintf(command, sizeof(command), "CANCEL %" PRIu64, epoch);
    return legacy_command(d, command);
  }
  if (n == 5 && !strcmp(parts[0], "CREDIT")) {
    if (!uint_value(parts[2], &first) || first != d->linear_window ||
        !uint_value(parts[3], &second) || !uint_value(parts[4], &last) ||
        second < d->linear_credited || second > d->linear_window_samples)
      return fail("linear_credit_bounds", -1);
    if (second == d->linear_credited && last == d->linear_credit_sequence) return 1;
    int found = -1;
    for (unsigned i = 0; i < d->linear_credit_count; ++i) {
      unsigned at = (d->linear_credit_head + i) % LINEAR_CREDIT_CAPACITY;
      if (d->linear_credit[at].sequence == last && d->linear_credit[at].end == second) { found = (int)i; break; }
    }
    if (found < 0 || last <= d->linear_credit_sequence) return fail("linear_credit_not_published_record_prefix", -1);
    d->linear_credit_head = (d->linear_credit_head + (unsigned)found + 1) % LINEAR_CREDIT_CAPACITY;
    d->linear_credit_count -= (unsigned)found + 1;
    d->linear_credited = second; d->linear_credit_sequence = last;
    fprintf(stderr, "{\"event\":\"credit_ack\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":%" PRIu64 ",\"accepted_samples\":%" PRIu64 ",\"last_sequence\":%" PRIu64 ",\"outstanding_samples\":%" PRIu64 ",\"monotonic_seconds\":%.9f}\n",
      d->epoch,d->segment,d->item,d->linear_window,second,last,d->linear_window_samples-second,monotonic());
    return 1;
  }
  if (n == 7 && !strcmp(parts[0], "NEXT_WINDOW")) {
    if (!uint_value(parts[2], &first) || !uint_value(parts[3], &second) ||
        !uint_value(parts[4], &last) || !signed_value(parts[5], &num) ||
        !uint_value(parts[6], &den) || !den || d->denominator <= 0 || den > (uint64_t)d->denominator ||
        !d->linear_held || first != d->linear_window || first == UINT64_MAX || second != first + 1 ||
        last != d->sequence || d->linear_credit_count || d->linear_credited != d->linear_window_samples ||
        !d->linear_last_pts_known || (__int128)num*d->denominator != (__int128)d->linear_last_end*den ||
        d->linear_next_start != d->linear_last_end)
      return fail("linear_next_window_not_exact_closed_prefix", -1);
    fprintf(stderr, "{\"event\":\"next_window_ack\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"previous_window\":%" PRIu64 ",\"next_window\":%" PRIu64 ",\"last_sequence\":%" PRIu64 ",\"previous_end_num\":%" PRId64 ",\"previous_end_den\":%" PRId64 ",\"next_start_num\":%" PRId64 ",\"next_start_den\":%" PRId64 ",\"next_output_before_release\":0,\"monotonic_seconds\":%.9f}\n",
      d->epoch,d->segment,d->item,first,second,last,d->linear_last_end,d->denominator,
      d->linear_next_start,d->denominator,monotonic());
    d->linear_window = second; d->linear_window_samples = d->linear_credited = 0;
    d->linear_window_records = 0; d->linear_held = 0; return 1;
  }
  if ((n == 4 || n == 5) && !strcmp(parts[0], "CONTROL")) {
    if (!uint_value(parts[2], &first) || d->linear_control_serial == UINT64_MAX ||
        first != d->linear_control_serial + 1) return fail("linear_control_serial", -1);
    char command[160];
    if (n == 4 && (!strcmp(parts[3], "PAUSE") || !strcmp(parts[3], "RESUME")))
      snprintf(command,sizeof(command),"%s %" PRIu64,parts[3],epoch);
    else if (n == 5 && !strcmp(parts[3], "SPEED") && strlen(parts[4]) < 64)
      snprintf(command,sizeof(command),"SPEED %" PRIu64 " %s",epoch,parts[4]);
    else return fail("linear_control_command", -1);
    if (!legacy_command(d,command)) return 0;
    d->linear_control_serial = first;
    fprintf(stderr,"{\"event\":\"control_ack\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"control_serial\":%" PRIu64 ",\"command\":\"%s\",\"paused\":%s,\"speed\":%.17g,\"monotonic_seconds\":%.9f}\n",
      d->epoch,d->segment,d->item,first,parts[3],d->paused?"true":"false",d->speed,monotonic());
    return 1;
  }
  if (n == 6 && !strcmp(parts[0], "LINEAR_SEEK")) {
    uint64_t next_epoch, old_window, next_window; int64_t target;
    struct stat observed;
    if (!uint_value(parts[2],&next_epoch) || next_epoch <= epoch ||
        !uint_value(parts[3],&old_window) || old_window != d->linear_window ||
        !uint_value(parts[4],&next_window) || !signed_value(parts[5],&target) ||
        !d->paused ||
        d->segment == UINT64_MAX || d->source_fd < 0 || fstat(d->source_fd,&observed) ||
        !same_source_fingerprint(&d->source_fingerprint,&observed) ||
        !((!d->sequence && !d->linear_window_samples && next_window == old_window) ||
          (old_window < UINT64_MAX && next_window == old_window+1)))
      return fail("linear_seek_unclosed_or_source_changed",-1);
    char command[160];snprintf(command,sizeof(command),"SEEK %" PRIu64 " %" PRIu64 " %" PRId64,epoch,next_epoch,target);
    if (!legacy_command(d,command) || fstat(d->source_fd,&observed) ||
        !same_source_fingerprint(&d->source_fingerprint,&observed)) return fail("linear_seek_held_fd_changed",-1);
    uint64_t retired=d->linear_window_samples-d->linear_credited;
    d->linear_credit_head=d->linear_credit_count=0;
    d->linear_window=next_window;d->linear_window_samples=d->linear_credited=0;
    d->linear_window_records=0;d->linear_held=0;d->linear_last_pts_known=0;
    fprintf(stderr,"{\"event\":\"linear_seek_ack\",\"old_epoch\":%" PRIu64 ",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":%" PRIu64 ",\"target_microseconds\":%" PRId64 ",\"held_fd\":%d,\"device\":%" PRIu64 ",\"inode\":%" PRIu64 ",\"bytes\":%" PRId64 ",\"mtime_seconds\":%" PRId64 ",\"mtime_nanoseconds\":%ld,\"retired_unaccepted_published_samples\":%" PRIu64 ",\"codec_flushed\":true,\"resampler_reset\":true,\"paused\":%s,\"monotonic_seconds\":%.9f}\n",
      epoch,d->epoch,d->segment,d->item,d->linear_window,target,d->source_fd,
      (uint64_t)observed.st_dev,(uint64_t)observed.st_ino,(int64_t)observed.st_size,
      (int64_t)observed.st_mtimespec.tv_sec,observed.st_mtimespec.tv_nsec,retired,d->paused?"true":"false",monotonic());
    return 1;
  }
  return fail("linear_unknown_control",-1);
}
static int command(Decoder *d, char *line) {
  return d->persistent_windows ? linear_command(d,line) : legacy_command(d,line);
}

static int controls(Decoder *d) {
  if (d->control_eof) return 1;
  char bytes[256]; ssize_t count;
  for (int batch = 0; batch < 64 && (count = read(STDIN_FILENO, bytes, sizeof(bytes))) > 0; ++batch) {
    for (ssize_t i = 0; i < count; ++i) {
      unsigned char value = (unsigned char)bytes[i];
      if (value == '\n') {
        d->controls[d->control_used] = 0;
        if (!command(d, d->controls)) { d->failed = d->cancelled = 1; return 0; }
        d->control_used = 0;
      } else {
        if ((!value || value < 32) && value != '\t' && value != '\r') { d->failed = d->cancelled = 1; return fail("control_byte_invalid", -1); }
        if (d->control_used + 1 >= sizeof(d->controls)) { d->failed = d->cancelled = 1; return fail("control_line_bound", -1); }
        d->controls[d->control_used++] = (char)value;
      }
    }
  }
  if (count == 0) {
    d->control_eof = 1;
    if (d->control_used || d->paused || d->first_block_waiting) { d->failed = d->cancelled = 1; return fail("control_eof_incomplete_or_paused", -1); }
  }
  return count >= 0 || errno == EAGAIN || errno == EWOULDBLOCK ? 1 : fail("control_read_failed", errno);
}
int main(int argc, char **argv) {
  Decoder d = {.stream = -1, .next_stream = -1, .epoch = 1, .item = 1, .next_item = 2, .speed = 1, .source_fd = -1, .max_samples = MAX_SAMPLES};
  int ok = 0; const char *input = NULL; int selftest = 0;
  setvbuf(stderr, NULL, _IOLBF, 0);
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--persistent-windows")) { if (d.persistent_windows) return 2; d.persistent_windows = 1; d.paused = 1; d.linear_window = 1; continue; }
    if (!strcmp(argv[i], "--paced")) { d.paced = 1; continue; }
    if (!strcmp(argv[i], "--first-block-hold")) {
      if (d.first_block_hold) return 2;
      d.first_block_hold = 1; d.paused = 1; continue; /* Held birth; still requires actual PAUSE/RESUME commands. */
    }
    if (!strcmp(argv[i], "--time-domain-selftest")) { selftest = 1; continue; }
    if (++i >= argc) return 2;
    uint64_t value;
    if (!strcmp(argv[i - 1], "--input")) input = argv[i];
    else if (!strcmp(argv[i - 1], "--next-input")) d.next_input = argv[i];
    else if (!uint_value(argv[i], &value)) return 2;
    else if (!strcmp(argv[i - 1], "--audio-stream") && value <= INT_MAX) d.stream = (int)value;
    else if (!strcmp(argv[i - 1], "--next-audio-stream") && value <= INT_MAX) d.next_stream = (int)value;
    else if (!strcmp(argv[i - 1], "--epoch") && value) d.epoch = value;
    else if (!strcmp(argv[i - 1], "--item") && value) d.item = value;
    else if (!strcmp(argv[i - 1], "--next-item") && value) d.next_item = value;
    else if (!strcmp(argv[i - 1], "--max-seconds") && value >= 1 && value <= 21600) {
      d.max_samples = value * OUT_RATE; d.graceful_limit = 1;
    }
    else return 2;
  }
  av_log_set_level(AV_LOG_QUIET);
  fprintf(stderr, "{\"event\":\"runtime_versions\",\"avformat\":%u,\"avcodec\":%u,\"avutil\":%u,\"swresample\":%u,\"compiled\":[%u,%u,%u,%u]}\n",
          avformat_version(), avcodec_version(), avutil_version(), swresample_version(),
          LIBAVFORMAT_VERSION_INT, LIBAVCODEC_VERSION_INT, LIBAVUTIL_VERSION_INT, LIBSWRESAMPLE_VERSION_INT);
  if (avformat_version() != LIBAVFORMAT_VERSION_INT || avcodec_version() != LIBAVCODEC_VERSION_INT ||
      avutil_version() != LIBAVUTIL_VERSION_INT || swresample_version() != LIBSWRESAMPLE_VERSION_INT) return 3;
  if (selftest) {
    /* Explicit pure time-domain check, never represented as an actual media frame. */
    int64_t negative = av_rescale_q(-4800, (AVRational){1,48000}, (AVRational){1,768000000});
    int passed = negative == -76800000 && AV_NOPTS_VALUE == INT64_MIN;
    fprintf(stderr, "{\"event\":\"time_domain_selftest\",\"passed\":%s,\"synthetic_only\":true,\"negative_scaled\":%" PRId64 ",\"missing_pts_sentinel\":%" PRId64 "}\n",
            passed ? "true" : "false", negative, AV_NOPTS_VALUE);
    return passed ? 0 : 4;
  }
  if (!input || d.stream < 0 || (d.next_input && d.next_stream < 0)) return 2;
  if (d.persistent_windows && (!d.graceful_limit || d.max_samples != MAX_SAMPLES || d.next_input || d.first_block_hold)) return 2;
  signal(SIGTERM, on_signal); signal(SIGINT, on_signal); signal(SIGPIPE, on_signal);
  if (fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) < 0) return 2;
  if (fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK) < 0) return 2;
  AVPacket *packet = av_packet_alloc(); AVFrame *frame = av_frame_alloc();
  if (!packet || !frame || !open_media(&d, input, d.stream)) goto done;
  if (d.persistent_windows) fprintf(stderr,"{\"event\":\"provider_born\",\"pid\":%d,\"held_fd\":%d,\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":1,\"monotonic_seconds\":%.9f}\n",getpid(),d.source_fd,d.epoch,d.segment,d.item,monotonic());
  for (uint64_t iteration = 0; (d.persistent_windows || iteration < 1000000) && !stop_requested && !d.cancelled && !d.input_limit_reached; ++iteration) {
    if (d.persistent_windows) {
      uint64_t quantum = d.linear_converted / MAX_SAMPLES;
      if (quantum > d.linear_work_quantum) { d.linear_work_quantum=quantum; d.linear_work_packets=0; }
      if (iteration==UINT64_MAX || d.linear_packets==UINT64_MAX || d.linear_work_packets>=1000000) { fail("linear_actual_conversion_work_bound",-1);goto done; }
      ++d.linear_packets;++d.linear_work_packets;
    }
    if (!controls(&d)) goto done;
    if(!d.persistent_windows || d.linear_prime_done)pause_wait(&d);
    if (stop_requested || d.cancelled) break;
    uint64_t epoch = d.epoch;
    int code = av_read_frame(d.format, packet);
    if (code == AVERROR_EOF) {
      code = avcodec_send_packet(d.codec, NULL);
      if (code < 0 && code != AVERROR_EOF) { fail("decoder_eof_send", code); goto done; }
      if (!receive(&d, frame)) goto done;
      if (stop_requested || d.cancelled) break; /* Cancellation during startup/drain is not media EOF. */
      if (d.input_limit_reached) break;
      if (epoch != d.epoch) continue;
      if (!drain(&d)) goto done;
      if (stop_requested || d.cancelled) break;
      if (d.input_limit_reached) break;
      if (epoch != d.epoch) continue;
      if (d.persistent_windows) {
        d.linear_source_eof=1;
        fprintf(stderr,"{\"event\":\"provider_source_eof\",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"item\":%" PRIu64 ",\"window\":%" PRIu64 ",\"output_samples\":%" PRIu64 ",\"last_sequence\":%" PRIu64 ",\"raw_end_num\":%" PRId64 ",\"raw_end_den\":%" PRId64 ",\"codec_eof\":true,\"resampler_drained\":true,\"monotonic_seconds\":%.9f}\n",d.epoch,d.segment,d.item,d.linear_window,d.linear_window_samples,d.sequence,d.linear_last_end,d.denominator,monotonic());
      }
      event(&d, "media_eof", "decoder_and_resampler_drained"); ok = 1; break;
    }
    if (code < 0) { if (stop_requested) break; fail("demux_read", code); goto done; }
    if (packet->stream_index == d.stream) {
      code = avcodec_send_packet(d.codec, packet);
      if (code == AVERROR(EAGAIN)) {
        if (!receive(&d, frame)) goto done;
        if (d.input_limit_reached) { av_packet_unref(packet); break; }
        if (epoch != d.epoch) { av_packet_unref(packet); continue; }
        code = avcodec_send_packet(d.codec, packet);
      }
      if (code < 0) { fail("audio_send", code); goto done; }
      if (!receive(&d, frame)) goto done;
    }
    av_packet_unref(packet);
  }
  if (d.input_limit_reached) ok = 1;
  if (stop_requested || d.cancelled) { if (!d.failed && !d.cancel_reported) event(&d, "cancel_acknowledged", stop_requested ? "owned_signal" : "control"); ok = !d.failed; }
done:
  if (d.persistent_windows && d.source_fd>=0) { struct stat observed;d.linear_fp_verified=fstat(d.source_fd,&observed)==0 && same_source_fingerprint(&d.source_fingerprint,&observed); }
  close_media(&d, "close"); av_packet_free(&packet); av_frame_free(&frame);
  if(d.persistent_windows)fprintf(stderr,"{\"event\":\"provider_closed\",\"ok\":%s,\"source_fd_closed\":%s,\"source_fingerprint_verified\":%s,\"remaining_av_contexts\":%d,\"lifetime_packets\":%" PRIu64 ",\"lifetime_converted_samples\":%" PRIu64 ",\"lifetime_published_samples\":%" PRIu64 ",\"epoch\":%" PRIu64 ",\"segment\":%" PRIu64 ",\"window\":%" PRIu64 "}\n",ok&&!d.failed?"true":"false",d.linear_fd_close_confirmed?"true":"false",d.linear_fp_verified&&!d.failed?"true":"false",(d.format!=NULL)+(d.codec!=NULL)+(d.swr!=NULL)+(d.io!=NULL)+(packet!=NULL)+(frame!=NULL),d.linear_packets,d.linear_converted,d.output_samples,d.epoch,d.segment,d.linear_window);
  if (d.failed) ok = 0;
  fprintf(stderr, "{\"event\":\"closed\",\"ok\":%s,\"cancelled\":%s,\"epoch\":%" PRIu64 ",\"output_samples\":%" PRIu64 ",\"decoded_frames\":%" PRIu64 ",\"remaining_owned_contexts\":%d,\"application_groups_added\":0}\n",
          ok ? "true" : "false", stop_requested || d.cancelled ? "true" : "false", d.epoch, d.output_samples, d.decoded_frames,
          (d.format != NULL) + (d.codec != NULL) + (d.swr != NULL));
  return ok ? 0 : 1;
}
