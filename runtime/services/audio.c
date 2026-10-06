// audren:u (audio renderer) and audout:u. Responses are well-formed but no sound is produced yet.
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../hle.h"
#include "../ipc.h"

typedef struct {
    uint32_t sample_rate, sample_count, mix_buffers, submixes, voices, sinks, effects, perf_frames;
    uint32_t revision;
    uint64_t elapsed_frames;
    uint32_t event_r, event_w;
    KEvent *event;
    uint32_t state;  // 0 started? (1 = stopped)
} Renderer;

static void *renderer_tick(void *arg) {
    Renderer *r = arg;
    struct timespec ts = {0, 5000000};  // 5 ms audio frames
    for (;;) {
        nanosleep(&ts, NULL);
        pthread_mutex_lock(&g_klock);
        kernel_signal(r->event);
        pthread_mutex_unlock(&g_klock);
    }
    return NULL;
}

// RequestUpdate: input is an UpdateDataHeader + sections; write a matching output.
static void request_update(Renderer *r, IpcReq *req, IpcResp *resp) {
    IpcBuf *in = in_buf(req, 0), *out = out_buf(req, 0);
    if (!in || !out || !in->size || !out->size) return;
    const uint8_t *ip = (const uint8_t *)(uintptr_t)in->addr;
    uint8_t *op = (uint8_t *)(uintptr_t)out->addr;
    const uint32_t *h = (const uint32_t *)ip;
    uint32_t behavior_sz = h[1], pools_sz = h[2], voices_sz = h[3], chans_sz = h[4], effects_sz = h[5];
    uint32_t mixes_sz = h[6], sinks_sz = h[7], perf_sz = h[8];
    uint32_t npools = pools_sz / 0x20, nvoices = voices_sz / 0x170, neffects = effects_sz / 0xC0;
    uint32_t nsinks = sinks_sz / 0x140;
    (void)mixes_sz;
    memset(op, 0, out->size);
    uint32_t *oh = (uint32_t *)op;
    oh[0] = h[0];
    uint32_t o = 0x40;
    // memory pools: acknowledge attach/detach requests
    const uint8_t *pin = ip + 0x40 + behavior_sz;
    oh[2] = npools * 0x10;
    for (uint32_t i = 0; i < npools && o + 0x10 <= out->size; i++, o += 0x10) {
        uint32_t st = *(const uint32_t *)(pin + i * 0x20 + 0x10);
        *(uint32_t *)(op + o) = st == 4 ? 5 : st == 2 ? 3 : st;
    }
    // voices: report progress so streaming code keeps feeding buffers
    const uint8_t *vin = pin + pools_sz + chans_sz;
    oh[3] = nvoices * 0x10;
    for (uint32_t i = 0; i < nvoices && o + 0x10 <= out->size; i++, o += 0x10) {
        const uint8_t *v = vin + i * 0x170;
        uint8_t used = v[9], play_state = v[10];
        if (used && play_state == 0) {
            *(uint64_t *)(op + o) = (r->elapsed_frames + 1) * r->sample_count;
            *(uint32_t *)(op + o + 8) = (uint32_t)(r->elapsed_frames + 1);
        }
    }
    oh[5] = neffects * 0x10;
    o += neffects * 0x10;
    oh[7] = nsinks * 0x20;
    o += nsinks * 0x20;
    oh[8] = perf_sz ? 0x10 : 0;
    o += oh[8];
    oh[1] = 0xB0;  // behavior / error info
    o += 0xB0;
    oh[10] = 0x10;  // render info: elapsed frame count
    if (o + 0x10 <= out->size) *(uint64_t *)(op + o) = r->elapsed_frames;
    o += 0x10;
    oh[15] = o;
    r->elapsed_frames++;
    (void)resp;
}

static void audio_renderer(Service *s, IpcReq *req, IpcResp *resp) {
    Renderer *r = s->state;
    switch (req->cmd) {
    case 0: OUT(uint32_t, 0) = r->sample_rate; resp_size(resp, 4); break;
    case 1: OUT(uint32_t, 0) = r->sample_count; resp_size(resp, 4); break;
    case 2: OUT(uint32_t, 0) = r->mix_buffers; resp_size(resp, 4); break;
    case 3: OUT(uint32_t, 0) = r->state; resp_size(resp, 4); break;
    case 4: case 10: request_update(r, req, resp); break;
    case 5: r->state = 0; break;
    case 6: r->state = 1; break;
    case 7: resp->copy_handles[resp->ncopy++] = r->event_r; break;
    case 8: break;
    case 9: OUT(uint32_t, 0) = 100; resp_size(resp, 4); break;
    default: LOG("[audren] IAudioRenderer cmd %u (ok)\n", req->cmd);
    }
}

static uint32_t new_event_handle(void) {
    uint32_t w, r;
    kernel_create_event_pair(&w, &r);
    return r;
}

static void audio_device(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 0: case 6: {  // ListAudioDeviceName(Auto)
        IpcBuf *b = out_buf(req, 0);
        if (b && b->size >= 0x100) strcpy((char *)(uintptr_t)b->addr, "AudioTvOutput");
        OUT(uint32_t, 0) = 1;
        resp_size(resp, 4);
        break;
    }
    case 3: case 10: {  // GetActiveAudioDeviceName(Auto)
        IpcBuf *b = out_buf(req, 0);
        if (b && b->size) strncpy((char *)(uintptr_t)b->addr, "AudioTvOutput", b->size);
        break;
    }
    case 4: case 11: case 12: resp->copy_handles[resp->ncopy++] = new_event_handle(); break;
    case 5: OUT(uint32_t, 0) = 2; resp_size(resp, 4); break;  // GetActiveChannelCount
    case 8: OUT(float, 0) = 1.0f; resp_size(resp, 4); break;
    default: break;
    }
}

SERVICE("audren:u", audren_u) {
    (void)s;
    switch (req->cmd) {
    case 0: {  // OpenAudioRenderer(params, work size, aruid, pid, transfer mem, process)
        Renderer *r = calloc(1, sizeof *r);
        const uint32_t *p = (const uint32_t *)req->data;
        r->sample_rate = p[0]; r->sample_count = p[1]; r->mix_buffers = p[2]; r->submixes = p[3];
        r->voices = p[4]; r->sinks = p[5]; r->effects = p[6]; r->perf_frames = p[7];
        r->revision = p[12];
        r->state = 1;
        r->event = kernel_create_event_pair(&r->event_w, &r->event_r);
        pthread_t t;
        pthread_create(&t, NULL, renderer_tick, r);
        LOG("[audren] renderer %u Hz, %u samples/frame, %u voices, %u sinks, %u effects\n", r->sample_rate,
            r->sample_count, r->voices, r->sinks, r->effects);
        ipc_return_object(resp, service_new("IAudioRenderer", audio_renderer, r));
        break;
    }
    case 1: OUT(uint64_t, 0) = 0x1000000; resp_size(resp, 8); break;  // GetWorkBufferSize: 16 MB
    case 2: case 4: ipc_return_object(resp, service_new("IAudioDevice", audio_device, NULL)); break;
    default: LOG("[audren] cmd %u (ok)\n", req->cmd);
    }
}

SERVICE("audout:u", audout_u) {
    (void)s;
    LOG("[audout] cmd %u (ok)\n", req->cmd);
    resp_size(resp, 0x10);
}
