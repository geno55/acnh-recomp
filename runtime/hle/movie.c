// movie:: (nnMedia) implemented with FFmpeg: an Android MediaExtractor/MediaCodec-style API.
// The game owns the objects (vtable at +0); we keep host state at +8.
//
// Extractor slots: 4 GetTrackCount(int*), 5 GetTrackConfiguration(int, MediaData*), 6 SelectTrack(int),
//   9 GetSampleTrackIndex(size_t*), 10 Read(Buffer*), 11 Advance(), 12 GetSampleTime(int64*),
//   15 SetDataSource(DataSource*, const char* path).
// Decoder slots: 2 Configure(MediaData*), 3 RegisterClientEvents(EventType*[4]), 4 GetOutputFormat(MediaData*),
//   6 Start, 9 AcquireInputBufferIndex(int*, int*), 10 GetInputBuffer(int, Buffer*),
//   11 SendInputBufferForDecode(int, int off, int size, int64 time, uint32 flags),
//   12 AcquireOutputBufferIndex(int*, int64*, uint32*, int*), 13 GetOutputBuffer(int, Buffer*),
//   15 ReleaseOutputBufferIndex(int), 18 GetOutputBufferFormat(int, MediaData*).
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../hle.h"

#define MOVIE_EOS 4u

// ------------------------------------------------------------------ MediaData (8-byte handle)
typedef struct { char *key; char *sval; int64_t ival; bool is_str; } MdEntry;
typedef struct { MdEntry e[32]; int n; void *codecpar; } MediaData;

static MediaData *md(uint64_t guest) {
    MediaData **p = (MediaData **)(uintptr_t)guest;
    if (!*p) *p = calloc(1, sizeof(MediaData));
    return *p;
}
static void md_clear(MediaData *m) {
    for (int i = 0; i < m->n; i++) { free(m->e[i].key); free(m->e[i].sval); }
    m->n = 0;
    m->codecpar = NULL;
}
static MdEntry *md_slot(MediaData *m, const char *k) {
    for (int i = 0; i < m->n; i++) if (!strcmp(m->e[i].key, k)) return &m->e[i];
    if (m->n == 32) return NULL;
    MdEntry *e = &m->e[m->n++];
    memset(e, 0, sizeof *e);
    e->key = strdup(k);
    return e;
}
static void md_set_int(MediaData *m, const char *k, int64_t v) { MdEntry *e = md_slot(m, k); if (e) { e->ival = v; e->is_str = false; } }
static void md_set_str(MediaData *m, const char *k, const char *v) {
    MdEntry *e = md_slot(m, k);
    if (e) { free(e->sval); e->sval = strdup(v); e->is_str = true; }
}

HLE_FUNC("_ZN5movie9MediaDataC1Ev", md_ctor) { *(uint64_t *)(uintptr_t)c->x[0] = (uint64_t)(uintptr_t)calloc(1, sizeof(MediaData)); }
HLE_FUNC("_ZN5movie9MediaDataC1ERKS0_", md_copy) {
    MediaData *src = md(c->x[1]), *dst = calloc(1, sizeof(MediaData));
    for (int i = 0; i < src->n; i++) {
        dst->e[i].key = strdup(src->e[i].key);
        dst->e[i].sval = src->e[i].sval ? strdup(src->e[i].sval) : NULL;
        dst->e[i].ival = src->e[i].ival;
        dst->e[i].is_str = src->e[i].is_str;
    }
    dst->n = src->n;
    dst->codecpar = src->codecpar;
    *(uint64_t *)(uintptr_t)c->x[0] = (uint64_t)(uintptr_t)dst;
}
HLE_FUNC("_ZN5movie9MediaDataD1Ev", md_dtor) {
    MediaData *m = *(MediaData **)(uintptr_t)c->x[0];
    if (m) { md_clear(m); free(m); }
    *(uint64_t *)(uintptr_t)c->x[0] = 0;
}
HLE_FUNC("_ZN5movie9MediaData5ClearEv", md_clear_hle) { md_clear(md(c->x[0])); }
HLE_FUNC("_ZNK5movie9MediaData9FindInt32EPKcPi", md_find_int32) {
    MediaData *m = md(c->x[0]);
    const char *k = (const char *)(uintptr_t)c->x[1];
    for (int i = 0; i < m->n; i++)
        if (!m->e[i].is_str && !strcmp(m->e[i].key, k)) { *(int32_t *)(uintptr_t)c->x[2] = (int32_t)m->e[i].ival; c->x[0] = 1; return; }
    c->x[0] = 0;
}
HLE_FUNC("_ZNK5movie9MediaData10FindStringEPKcPS2_", md_find_string) {
    MediaData *m = md(c->x[0]);
    const char *k = (const char *)(uintptr_t)c->x[1];
    for (int i = 0; i < m->n; i++)
        if (m->e[i].is_str && !strcmp(m->e[i].key, k)) { *(uint64_t *)(uintptr_t)c->x[2] = (uint64_t)(uintptr_t)m->e[i].sval; c->x[0] = 1; return; }
    c->x[0] = 0;
}

// ------------------------------------------------------------------ Buffer (opaque, <= 0x40 bytes)
typedef struct {
    uint64_t base, capacity;
    int32_t offset, size;
    int64_t i64;
    uint32_t u32;
    int32_t i32;
} MBuffer;
_Static_assert(sizeof(MBuffer) <= 0x40, "movie::Buffer size");
#define BUF(x) ((MBuffer *)(uintptr_t)(x))

HLE_FUNC("_ZN5movie6BufferC1Ev", buf_ctor) { memset(BUF(c->x[0]), 0, sizeof(MBuffer)); }
HLE_FUNC("_ZN5movie6BufferC1EPvm", buf_ctor_ext) {
    MBuffer *b = BUF(c->x[0]);
    memset(b, 0, sizeof *b);
    b->base = c->x[1];
    b->capacity = c->x[2];
    b->size = (int32_t)c->x[2];
}
HLE_FUNC("_ZN5movie6BufferC1Em", buf_ctor_alloc) {
    MBuffer *b = BUF(c->x[0]);
    memset(b, 0, sizeof *b);
    b->base = (uint64_t)(uintptr_t)calloc(1, c->x[1] + 64);
    b->capacity = c->x[1];
    b->size = (int32_t)c->x[1];
}
HLE_FUNC("_ZN5movie6BufferC1ERKS0_", buf_copy) { *BUF(c->x[0]) = *BUF(c->x[1]); }
HLE_FUNC("_ZN5movie6BufferaSERKS0_", buf_assign) { *BUF(c->x[0]) = *BUF(c->x[1]); }
HLE_FUNC("_ZN5movie6BufferD1Ev", buf_dtor) { (void)c; }
HLE_FUNC("_ZNK5movie6Buffer4BaseEv", buf_base) { c->x[0] = BUF(c->x[0])->base; }
HLE_FUNC("_ZNK5movie6Buffer4SizeEv", buf_size) { c->x[0] = (uint32_t)BUF(c->x[0])->size; }
HLE_FUNC("_ZNK5movie6Buffer6OffsetEv", buf_offset) { c->x[0] = (uint32_t)BUF(c->x[0])->offset; }
HLE_FUNC("_ZNK5movie6Buffer8CapacityEv", buf_capacity) { c->x[0] = BUF(c->x[0])->capacity; }
HLE_FUNC("_ZN5movie6Buffer8SetRangeEii", buf_set_range) { BUF(c->x[0])->offset = (int32_t)c->x[1]; BUF(c->x[0])->size = (int32_t)c->x[2]; }
HLE_FUNC("_ZN5movie6Buffer18SetDataAndCapacityEPvm", buf_set_data) {
    MBuffer *b = BUF(c->x[0]);
    b->base = c->x[1];
    b->capacity = c->x[2];
}
HLE_FUNC("_ZN5movie6Buffer12SetInt64DataEl", buf_set_i64) { BUF(c->x[0])->i64 = (int64_t)c->x[1]; }
HLE_FUNC("_ZNK5movie6Buffer12GetInt64DataEv", buf_get_i64) { c->x[0] = (uint64_t)BUF(c->x[0])->i64; }
HLE_FUNC("_ZN5movie6Buffer13SetUint32DataEj", buf_set_u32) { BUF(c->x[0])->u32 = (uint32_t)c->x[1]; }
HLE_FUNC("_ZNK5movie6Buffer13GetUint32DataEv", buf_get_u32) { c->x[0] = BUF(c->x[0])->u32; }
HLE_FUNC("_ZN5movie6Buffer12SetInt32DataEi", buf_set_i32) { BUF(c->x[0])->i32 = (int32_t)c->x[1]; }

HLE_FUNC("_ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", movie_set_allocator) { (void)c; }
HLE_FUNC("_ZN5movie17SetThreadPriorityEi", movie_set_thread_priority) { (void)c; }
HLE_FUNC("_ZN5movie17GetThreadPriorityEv", movie_get_thread_priority) { c->x[0] = 16; }

// ------------------------------------------------------------------ helpers
static uint64_t make_vtable(HostFn *fns, int n, const char *prefix) {
    uint64_t *t = hle_alloc(64 * 8);
    char name[96];
    for (int i = 0; i < 64; i++) {
        snprintf(name, sizeof name, "<%s slot %d>", prefix, i);
        t[i] = hle_register(name, i < n ? fns[i] : NULL);
    }
    return (uint64_t)(uintptr_t)t;
}

static void *self_state(Cpu *c) { return (void *)(uintptr_t)((uint64_t *)(uintptr_t)c->x[0])[1]; }

static void signal_guest_event(Cpu *c, uint64_t event) {
    if (!event) return;
    uint64_t saved[8];
    memcpy(saved, c->x, sizeof saved);
    c->x[0] = event;
    guest_call(c, guest_sym("_ZN2nn2os11SignalEventEPNS0_9EventTypeE"));
    memcpy(c->x, saved, sizeof saved);
}

static void ok(Cpu *c) { c->x[0] = 0; }

// ------------------------------------------------------------------ Extractor
typedef struct {
    AVFormatContext *fmt;
    int map[16], ntracks;  // exposed track -> stream (video only for now; audio output isn't wired up)
    uint64_t selected;  // bitmask of streams
    AVPacket *pkt;
    bool have_pkt, eof;
} Extractor;

static void ex_fill(Extractor *e) {
    while (!e->have_pkt && !e->eof) {
        if (av_read_frame(e->fmt, e->pkt) < 0) { e->eof = true; break; }
        if (e->selected & (1ull << e->pkt->stream_index)) e->have_pkt = true;
        else av_packet_unref(e->pkt);
    }
}

static void ex_set_data_source(Cpu *c) {
    Extractor *e = self_state(c);
    const char *path = (const char *)(uintptr_t)c->x[2];
    // "rom:/region_common/movie/title.webm" -> extracted/romfs/region_common/movie/title.webm
    const char *rel = path && strstr(path, ":/") ? strstr(path, ":/") + 2 : path;
    char host[1024];
    snprintf(host, sizeof host, "%s/%s", g_romfs_dir, rel ? rel : "");
    LOG("[movie] open %s -> %s\n", path ? path : "(null)", host);
    if (avformat_open_input(&e->fmt, host, NULL, NULL) < 0 || avformat_find_stream_info(e->fmt, NULL) < 0) {
        LOG("[movie] cannot open %s\n", host);
        c->x[0] = 1;
        return;
    }
    e->pkt = av_packet_alloc();
    e->ntracks = 0;
    for (unsigned i = 0; i < e->fmt->nb_streams && e->ntracks < 16; i++)
        if (e->fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) e->map[e->ntracks++] = (int)i;
    c->x[0] = 0;
}

static void ex_get_track_count(Cpu *c) {
    Extractor *e = self_state(c);
    *(int32_t *)(uintptr_t)c->x[1] = e->fmt ? e->ntracks : 0;
    c->x[0] = 0;
}

static void ex_get_track_config(Cpu *c) {
    Extractor *e = self_state(c);
    int i = (int)c->x[1];
    MediaData *m = md(c->x[2]);
    md_clear(m);
    if (!e->fmt || i >= e->ntracks) { c->x[0] = 1; return; }
    AVStream *s = e->fmt->streams[e->map[i]];
    AVCodecParameters *p = s->codecpar;
    m->codecpar = p;
    if (p->codec_type == AVMEDIA_TYPE_VIDEO) {
        md_set_str(m, "mime", p->codec_id == AV_CODEC_ID_VP9 ? "video/x-vnd.on2.vp9" :
                              p->codec_id == AV_CODEC_ID_VP8 ? "video/x-vnd.on2.vp8" : "video/avc");
        md_set_int(m, "width", p->width);
        md_set_int(m, "height", p->height);
        int fps = s->avg_frame_rate.den ? s->avg_frame_rate.num / s->avg_frame_rate.den : 30;
        md_set_int(m, "frame-rate", fps ? fps : 30);
    } else {
        md_set_str(m, "mime", p->codec_id == AV_CODEC_ID_VORBIS ? "audio/vorbis" : "audio/mp4a-latm");
        md_set_int(m, "sample-rate", p->sample_rate);
        md_set_int(m, "channel-count", p->ch_layout.nb_channels);
    }
    if (e->fmt->duration > 0) md_set_int(m, "durationUs", e->fmt->duration);
    c->x[0] = 0;
}

static void ex_select_track(Cpu *c) {
    Extractor *e = self_state(c);
    int i = (int)c->x[1];
    if (i >= 0 && i < e->ntracks) e->selected |= 1ull << e->map[i];
    c->x[0] = 0;
}

static void ex_get_sample_track(Cpu *c) {
    Extractor *e = self_state(c);
    ex_fill(e);
    if (!e->have_pkt) { c->x[0] = 1; return; }
    uint64_t t = 0;
    for (int i = 0; i < e->ntracks; i++) if (e->map[i] == e->pkt->stream_index) t = (uint64_t)i;
    *(uint64_t *)(uintptr_t)c->x[1] = t;
    c->x[0] = 0;
}

static void ex_read(Cpu *c) {
    Extractor *e = self_state(c);
    MBuffer *b = BUF(c->x[1]);
    ex_fill(e);
    if (!e->have_pkt) { c->x[0] = 1; return; }
    uint32_t n = (uint32_t)e->pkt->size;
    if (n > b->capacity) { LOG("[movie] packet %u > buffer %llu\n", n, b->capacity); n = (uint32_t)b->capacity; }
    memcpy((void *)(uintptr_t)b->base, e->pkt->data, n);
    b->offset = 0;
    b->size = (int32_t)n;
    c->x[0] = 0;
}

static void ex_advance(Cpu *c) {
    Extractor *e = self_state(c);
    if (e->have_pkt) { av_packet_unref(e->pkt); e->have_pkt = false; }
    c->x[0] = 0;
}

static void ex_get_sample_time(Cpu *c) {
    Extractor *e = self_state(c);
    ex_fill(e);
    if (!e->have_pkt) { c->x[0] = 1; return; }
    AVStream *s = e->fmt->streams[e->pkt->stream_index];
    int64_t ts = e->pkt->pts != AV_NOPTS_VALUE ? e->pkt->pts : e->pkt->dts;
    *(int64_t *)(uintptr_t)c->x[1] = av_rescale_q(ts, s->time_base, (AVRational){1, 1000000});
    c->x[0] = 0;
}

// slot 8: SeekTo(int64 timeUs)
static void ex_seek(Cpu *c) {
    Extractor *e = self_state(c);
    if (!e->fmt) { c->x[0] = 1; return; }
    if (e->have_pkt) { av_packet_unref(e->pkt); e->have_pkt = false; }
    e->eof = false;
    av_seek_frame(e->fmt, -1, (int64_t)c->x[1], AVSEEK_FLAG_BACKWARD);
    c->x[0] = 0;
}

// slot 14: GetCachedDuration(out1, int64* durationUs) -- local files are fully cached
static void ex_cached_duration(Cpu *c) {
    Extractor *e = self_state(c);
    int64_t dur = e->fmt && e->fmt->duration > 0 ? e->fmt->duration : INT64_MAX / 4;
    if (c->x[1]) *(int64_t *)(uintptr_t)c->x[1] = 1;
    if (c->x[2]) *(int64_t *)(uintptr_t)c->x[2] = dur;
    c->x[0] = 0;
}

static void ex_dtor(Cpu *c) {
    Extractor *e = self_state(c);
    if (e && e->fmt) avformat_close_input(&e->fmt);
    c->x[0] = 0;
}

static void movie_log_slot(Cpu *c) {
    static int n;
    if (n++ < 20) LOG("[movie] unimplemented virtual (lr=%llx)\n", c->x[30]);
    c->x[0] = 0;
}

HLE_FUNC("_ZN5movie9ExtractorC1ENS_13ContainerTypeE", movie_extractor_ctor) {
    static uint64_t vt;
    if (!vt) {
        HostFn f[16] = {ex_dtor, ex_dtor, movie_log_slot, movie_log_slot, ex_get_track_count, ex_get_track_config,
                        ex_select_track, movie_log_slot, ex_seek, ex_get_sample_track, ex_read, ex_advance,
                        ex_get_sample_time, movie_log_slot, ex_cached_duration, ex_set_data_source};
        vt = make_vtable(f, 16, "Extractor");
    }
    uint64_t *self = (uint64_t *)(uintptr_t)c->x[0];
    self[0] = vt;
    self[1] = (uint64_t)(uintptr_t)calloc(1, sizeof(Extractor));
}

// ------------------------------------------------------------------ Decoder
#define NIN 4
#define NOUT 6

typedef struct {
    int idx;
    int64_t time;
    uint32_t flags;
} OutReady;

typedef struct {
    AVCodecContext *ctx;
    AVFrame *frame;
    AVPacket *pkt;
    bool video;
    uint64_t events[4];  // input available, output available, format changed, error
    uint8_t *in_mem[NIN];
    uint32_t in_cap;
    bool in_busy[NIN];
    uint8_t *out_mem[NOUT];
    uint32_t out_cap, out_size[NOUT];
    bool out_busy[NOUT];
    OutReady ready[NOUT];
    int nready;
    int width, height, stride, sample_rate, channels;
    struct SwsContext *sws;
    uint8_t *rgba;
    pthread_mutex_t lock;
    // asynchronous decode: packets are copied to a host worker thread
    pthread_cond_t cond;
    pthread_t worker;
    struct { uint8_t *data; int size; int64_t time; uint32_t flags; } q[16];
    int qn;
    bool output_pending;  // an output-available event is owed to the guest
    bool running;
} Decoder;

typedef struct NvnTexture NvnTexture;
void renderer_upload_rgba(NvnTexture *t, const void *rgba, uint32_t w, uint32_t h, uint32_t stride);

static void dec_configure(Cpu *c) {
    Decoder *d = self_state(c);
    MediaData *m = md(c->x[1]);
    AVCodecParameters *p = m->codecpar;
    if (!p) { LOG("[movie] Configure without codec parameters\n"); c->x[0] = 1; return; }
    const AVCodec *codec = avcodec_find_decoder(p->codec_id);
    d->ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(d->ctx, p);
    d->ctx->thread_count = 4;
    if (avcodec_open2(d->ctx, codec, NULL) < 0) { LOG("[movie] cannot open decoder\n"); c->x[0] = 1; return; }
    d->frame = av_frame_alloc();
    d->pkt = av_packet_alloc();
    d->video = p->codec_type == AVMEDIA_TYPE_VIDEO;
    d->width = p->width;
    d->height = p->height;
    d->stride = (p->width + 255) & ~255;
    d->sample_rate = p->sample_rate;
    d->channels = p->ch_layout.nb_channels;
    d->in_cap = d->video ? 4 << 20 : 256 << 10;
    d->out_cap = d->video ? (uint32_t)(d->stride * ((d->height + 15) & ~15) * 3 / 2) : 64 << 10;
    for (int i = 0; i < NIN; i++) d->in_mem[i] = hle_alloc(d->in_cap);
    for (int i = 0; i < NOUT; i++) d->out_mem[i] = hle_alloc(d->out_cap);
    LOG("[movie] decoder %s configured: %dx%d %d Hz %d ch\n", codec->name, d->width, d->height, d->sample_rate, d->channels);
    c->x[0] = 0;
}

static void dec_register_events(Cpu *c) {
    Decoder *d = self_state(c);
    memcpy(d->events, (void *)(uintptr_t)c->x[1], sizeof d->events);
    c->x[0] = 0;
}

static void dec_output_format(Decoder *d, MediaData *m) {
    md_clear(m);
    if (d->video) {
        md_set_str(m, "mime", "video/raw");
        md_set_int(m, "width", d->width);
        md_set_int(m, "height", d->height);
        md_set_int(m, "nv12-y-stride", d->stride);
        md_set_int(m, "nv12-y-offset", 0);
        md_set_int(m, "nv12-uv-offset", d->stride * ((d->height + 15) & ~15));
        md_set_int(m, "nv12-colorspace", 0);
    } else {
        md_set_str(m, "mime", "audio/raw");
        md_set_int(m, "sample-rate", d->sample_rate);
        md_set_int(m, "channel-count", d->channels);
    }
}

static void dec_get_output_format(Cpu *c) { dec_output_format(self_state(c), md(c->x[1])); c->x[0] = 0; }
static void dec_get_output_buffer_format(Cpu *c) { dec_output_format(self_state(c), md(c->x[2])); c->x[0] = 0; }

static void dec_start(Cpu *c) {
    Decoder *d = self_state(c);
    signal_guest_event(c, d->events[0]);  // all input buffers are free
    c->x[0] = 0;
}

static void flush_signals(Cpu *c, Decoder *d);
static uint64_t n_acq_in, n_send, n_acq_out, n_get_out, n_rel_out, n_frames;
static void movie_stats(void) {
    static uint64_t last;
    uint64_t now = n_acq_in + n_send + n_acq_out + n_rel_out;
    if (now / 200 != last / 200)
        LOG("[movie] acq_in %llu send %llu frames %llu acq_out %llu get_out %llu rel_out %llu\n", n_acq_in, n_send,
            n_frames, n_acq_out, n_get_out, n_rel_out);
    last = now;
}

static void dec_acquire_input(Cpu *c) {
    Decoder *d = self_state(c);
    n_acq_in++;
    movie_stats();
    flush_signals(c, d);
    pthread_mutex_lock(&d->lock);
    if (d->qn >= 4) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 20000000;
        if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
        if (d->running) pthread_cond_timedwait(&d->cond, &d->lock, &ts);
    }
    if (d->qn >= 4) {  // backpressure: the release of an output buffer re-signals input
        pthread_mutex_unlock(&d->lock);
        flush_signals(c, d);
        c->x[0] = 1;
        return;
    }
    int idx = -1, free_n = 0;
    for (int i = 0; i < NIN; i++)
        if (!d->in_busy[i]) { if (idx < 0) idx = i; else free_n++; }
    if (idx >= 0) d->in_busy[idx] = true;
    pthread_mutex_unlock(&d->lock);
    if (idx < 0) { c->x[0] = 1; return; }
    *(int32_t *)(uintptr_t)c->x[1] = idx;
    if (c->x[2]) *(int32_t *)(uintptr_t)c->x[2] = free_n;
    c->x[0] = 0;
}

static void dec_get_input_buffer(Cpu *c) {
    Decoder *d = self_state(c);
    int i = (int)c->x[1];
    MBuffer *b = BUF(c->x[2]);
    if (i < 0 || i >= NIN) { c->x[0] = 1; return; }
    memset(b, 0, sizeof *b);
    b->base = (uint64_t)(uintptr_t)d->in_mem[i];
    b->capacity = d->in_cap;
    c->x[0] = 0;
}

// Copy a decoded frame into an output slot; caller holds the lock.
static bool emit_frame(Decoder *d, int64_t time, uint32_t flags) {
    int slot = -1;
    for (int i = 0; i < NOUT; i++) if (!d->out_busy[i]) { slot = i; break; }
    if (slot < 0) return false;
    uint8_t *o = d->out_mem[slot];
    uint32_t size = 0;
    if (flags & MOVIE_EOS) {
        size = 0;
    } else if (d->video) {
        AVFrame *f = d->frame;
        int h = d->height, w = d->width, uv_off = d->stride * ((h + 15) & ~15);
        for (int y = 0; y < h; y++) memcpy(o + y * d->stride, f->data[0] + y * f->linesize[0], w);
        for (int y = 0; y < h / 2; y++) {  // interleave U and V into NV12
            uint8_t *uv = o + uv_off + y * d->stride;
            const uint8_t *u = f->data[1] + y * f->linesize[1], *v = f->data[2] + y * f->linesize[2];
            for (int x = 0; x < w / 2; x++) { uv[2 * x] = u[x]; uv[2 * x + 1] = v[x]; }
        }
        size = (uint32_t)(uv_off + d->stride * (h / 2));
    } else {
        // planar float -> interleaved s16
        AVFrame *f = d->frame;
        int ch = f->ch_layout.nb_channels, n = f->nb_samples;
        int16_t *out = (int16_t *)o;
        if ((uint32_t)(n * ch * 2) > d->out_cap) n = (int)(d->out_cap / (ch * 2));
        for (int i = 0; i < n; i++)
            for (int k = 0; k < ch; k++) {
                float s = f->format == AV_SAMPLE_FMT_FLTP ? ((const float *)f->data[k])[i] : 0.0f;
                if (s > 1.0f) s = 1.0f;
                if (s < -1.0f) s = -1.0f;
                out[i * ch + k] = (int16_t)(s * 32767.0f);
            }
        size = (uint32_t)(n * ch * 2);
    }
    d->out_busy[slot] = true;
    d->out_size[slot] = size;
    d->ready[d->nready++] = (OutReady){slot, time, flags};
    return true;
}

static void *dec_worker(void *arg) {
    Decoder *d = arg;
    pthread_mutex_lock(&d->lock);
    for (;;) {
        while (!d->qn) pthread_cond_wait(&d->cond, &d->lock);
        uint8_t *data = d->q[0].data;
        int size = d->q[0].size;
        int64_t time = d->q[0].time;
        uint32_t flags = d->q[0].flags;
        memmove(d->q, d->q + 1, --d->qn * sizeof d->q[0]);
        pthread_mutex_unlock(&d->lock);
        AVPacket *pkt = av_packet_alloc();
        if (size > 0) {
            pkt->data = data;
            pkt->size = size;
            pkt->pts = time;
            avcodec_send_packet(d->ctx, pkt);
        }
        if (flags & MOVIE_EOS) avcodec_send_packet(d->ctx, NULL);
        av_packet_free(&pkt);
        free(data);
        pthread_mutex_lock(&d->lock);
        for (;;) {
            // wait for a free output slot rather than dropping frames
            int free_slots = 0;
            for (int i = 0; i < NOUT; i++) if (!d->out_busy[i]) free_slots++;
            if (!free_slots) { pthread_cond_wait(&d->cond, &d->lock); continue; }
            pthread_mutex_unlock(&d->lock);
            int r = avcodec_receive_frame(d->ctx, d->frame);
            pthread_mutex_lock(&d->lock);
            if (r != 0) break;
            int64_t t = d->frame->pts != AV_NOPTS_VALUE ? d->frame->pts : time;
            emit_frame(d, t, 0);
            n_frames++;
            d->output_pending = true;
        }
        if (flags & MOVIE_EOS) { emit_frame(d, time, MOVIE_EOS); d->output_pending = true; }
        pthread_cond_broadcast(&d->cond);
    }
    return NULL;
}

// Signal events owed to the guest; runs on guest threads (inside decoder calls).
static void flush_signals(Cpu *c, Decoder *d) {
    pthread_mutex_lock(&d->lock);
    bool out = d->output_pending;
    d->output_pending = false;
    pthread_mutex_unlock(&d->lock);
    if (out) signal_guest_event(c, d->events[1]);
}

static void dec_send_input(Cpu *c) {
    Decoder *d = self_state(c);
    n_send++;
    int idx = (int)c->x[1], off = (int)c->x[2], size = (int)c->x[3];
    int64_t time = (int64_t)c->x[4];
    uint32_t flags = (uint32_t)c->x[5];
    pthread_mutex_lock(&d->lock);
    if (!d->running) {
        d->running = true;
        pthread_cond_init(&d->cond, NULL);
        pthread_create(&d->worker, NULL, dec_worker, d);
    }
    if (d->qn < 16) {
        uint8_t *copy = NULL;
        if (size > 0 && idx >= 0 && idx < NIN) {
            copy = malloc((size_t)size + AV_INPUT_BUFFER_PADDING_SIZE);
            memcpy(copy, d->in_mem[idx] + off, (size_t)size);
            memset(copy + size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        }
        d->q[d->qn].data = copy;
        d->q[d->qn].size = copy ? size : 0;
        d->q[d->qn].time = time;
        d->q[d->qn].flags = flags;
        d->qn++;
        pthread_cond_broadcast(&d->cond);
    }
    if (idx >= 0 && idx < NIN) d->in_busy[idx] = false;
    pthread_mutex_unlock(&d->lock);
    signal_guest_event(c, d->events[0]);
    flush_signals(c, d);
    c->x[0] = 0;
}

static void dec_acquire_output(Cpu *c) {
    Decoder *d = self_state(c);
    n_acq_out++;
    flush_signals(c, d);
    pthread_mutex_lock(&d->lock);
    if (!d->nready) { pthread_mutex_unlock(&d->lock); c->x[0] = 1; return; }
    OutReady r = d->ready[0];
    memmove(d->ready, d->ready + 1, --d->nready * sizeof *d->ready);
    int remaining = d->nready;
    pthread_mutex_unlock(&d->lock);
    *(int32_t *)(uintptr_t)c->x[1] = r.idx;
    if (c->x[2]) *(int64_t *)(uintptr_t)c->x[2] = r.time;
    if (c->x[3]) *(uint32_t *)(uintptr_t)c->x[3] = r.flags;
    if (c->x[4]) *(int32_t *)(uintptr_t)c->x[4] = remaining;
    c->x[0] = 0;
}

static void dec_get_output_buffer(Cpu *c) {
    Decoder *d = self_state(c);
    n_get_out++;
    int i = (int)c->x[1];
    MBuffer *b = BUF(c->x[2]);
    if (i < 0 || i >= NOUT) { c->x[0] = 1; return; }
    if (d->video && b->base && b->capacity == 8) {
        // texture output mode: the buffer points at the game's NVNtexture; write RGBA into it
        NvnTexture *t = *(NvnTexture **)(uintptr_t)b->base;
        int w = d->width, h = d->height;
        if (!d->sws)
            d->sws = sws_getContext(w, h, AV_PIX_FMT_NV12, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
        if (!d->rgba) d->rgba = malloc((size_t)w * h * 4);
        const uint8_t *src[2] = {d->out_mem[i], d->out_mem[i] + d->stride * ((h + 15) & ~15)};
        int src_stride[2] = {d->stride, d->stride};
        uint8_t *dst[1] = {d->rgba};
        int dst_stride[1] = {w * 4};
        sws_scale(d->sws, src, src_stride, 0, h, dst, dst_stride);
        renderer_upload_rgba(t, d->rgba, (uint32_t)w, (uint32_t)h, (uint32_t)w * 4);
        c->x[0] = 0;
        return;
    }
    memset(b, 0, sizeof *b);
    b->base = (uint64_t)(uintptr_t)d->out_mem[i];
    b->capacity = d->out_cap;
    b->size = (int32_t)d->out_size[i];
    c->x[0] = 0;
}

static void dec_release_output(Cpu *c) {
    Decoder *d = self_state(c);
    n_rel_out++;
    signal_guest_event(c, d->events[0]);  // input may be accepted again
    int i = (int)c->x[1];
    pthread_mutex_lock(&d->lock);
    if (i >= 0 && i < NOUT) d->out_busy[i] = false;
    if (d->running) pthread_cond_broadcast(&d->cond);
    pthread_mutex_unlock(&d->lock);
    flush_signals(c, d);
    c->x[0] = 0;
}

static void dec_dtor(Cpu *c) {
    Decoder *d = self_state(c);
    if (d && d->ctx) avcodec_free_context(&d->ctx);
    c->x[0] = 0;
}

static void dec_get_counts(Cpu *c) {  // slot 14: (int*, int64*) queried after Configure
    if (c->x[1]) *(int32_t *)(uintptr_t)c->x[1] = 0;
    if (c->x[2]) *(int64_t *)(uintptr_t)c->x[2] = 0;
    c->x[0] = 0;
}

HLE_FUNC("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", movie_decoder_ctor) {
    static uint64_t vt;
    if (!vt) {
        HostFn f[19] = {dec_dtor, dec_dtor, dec_configure, dec_register_events, dec_get_output_format,
                        dec_start, ok, ok, ok, dec_acquire_input, dec_get_input_buffer, dec_send_input,
                        dec_acquire_output, dec_get_output_buffer, dec_get_counts, dec_release_output, ok,
                        movie_log_slot, dec_get_output_buffer_format};
        vt = make_vtable(f, 19, "Decoder");
    }
    uint64_t *self = (uint64_t *)(uintptr_t)c->x[0];
    Decoder *d = calloc(1, sizeof *d);
    pthread_mutex_init(&d->lock, NULL);
    self[0] = vt;
    self[1] = (uint64_t)(uintptr_t)d;
}
