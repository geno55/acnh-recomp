// NVN command buffers. Commands are recorded as CmdRec records; a command handle is the address of a list's first
// record (the executors in runtime/nvn/vulkan/exec.c and renderer.m walk them).
//
// Records are larger than NVN's own encoding, and some games (ACNH) give a command buffer only as much memory as real
// NVN needs. So records don't go into the guest's command memory itself but into a host mirror of it, HOST_PER_GUEST
// times larger: the record charged at guest address g lives at mirror(g). Use is reported in guest bytes at about
// NVN's rate (GUEST_CMD per command plus its inline data; the record fits in that many guest bytes times
// HOST_PER_GUEST), so the game's out-of-memory callbacks come as they would, and when the game records over a guest
// range again - it knows the GPU is done with the commands there - exactly the matching host range is overwritten.
// (Lists elsewhere stay intact: a parent list may still call them by handle.)
#include <stdlib.h>
#include <string.h>

#include "nvn.h"

#define GUEST_CMD 16       // guest bytes charged per command, plus its inline data: about NVN's own rate
#define GUEST_RESERVE 16   // kept free after every record for a jump (to the next chunk or page), as NVN does
#define HOST_PER_GUEST 5   // host bytes per guest byte: the CmdRec header (80) is 5 x GUEST_CMD, data 1:1
_Static_assert(sizeof(CmdRec) <= GUEST_CMD * HOST_PER_GUEST, "record header must fit its guest charge");
#define PAGE_BITS 20       // the mirror is made of 1 MiB guest pages (HOST_PER_GUEST MiB each), allocated on first use
#define PAGE_SIZE (1ull << PAGE_BITS)

typedef struct MirrorPage { uint64_t key; uint8_t *mem; struct MirrorPage *next; } MirrorPage;
#define PAGE_BUCKETS 1024
static MirrorPage *pages[PAGE_BUCKETS];
static pthread_mutex_t page_lock = PTHREAD_MUTEX_INITIALIZER;

// Host address of guest command memory address g. Pool memory uses its guest address; memory given with no pool
// (ACNH, some command buffers: offsets only) gets an address space of its own per command buffer (1 << 62 | id << 32).
static uint64_t mirror(uint64_t g) {
    uint64_t key = g >> PAGE_BITS;
    pthread_mutex_lock(&page_lock);
    unsigned h = (unsigned)((key * 0x9E3779B97F4A7C15ull) >> 54) & (PAGE_BUCKETS - 1);
    MirrorPage *p = pages[h];
    while (p && p->key != key) p = p->next;
    if (!p) {
        p = calloc(1, sizeof *p);
        p->key = key;
        p->mem = malloc(PAGE_SIZE * HOST_PER_GUEST);
        if (!p->mem) FATAL("nvn: out of host memory for command records\n");
        p->next = pages[h];
        pages[h] = p;
    }
    pthread_mutex_unlock(&page_lock);
    return (uint64_t)(uintptr_t)(p->mem + (g & (PAGE_SIZE - 1)) * HOST_PER_GUEST);
}

static NvnCmdBuf *cb_of(uint64_t guest) { return HOST(NvnCmdBuf, guest); }

NVN(nvnCommandBufferInitialize) {
    static _Atomic uint32_t next_id;
    NvnCmdBuf *cb = calloc(1, sizeof *cb);
    cb->guest = A(0);
    cb->id = ++next_id;
    SET_HOST(A(0), cb);
    RET(1);
}
NVN(nvnCommandBufferFinalize) { free(cb_of(A(0))); SET_HOST(A(0), 0); }  // (the mirror belongs to guest memory: kept)
NVN(nvnCommandBufferSetDebugLabel) { (void)c; }

static CmdRec *raw_rec(uint64_t at, uint32_t op, uint32_t size) {
    CmdRec *r = (CmdRec *)(uintptr_t)at;
    memset(r, 0, sizeof *r);
    r->op = op;
    r->size = size;
    return r;
}

// Continue in guest command memory at g (size bytes); a list being recorded jumps there (the reserve after the last
// record holds the jump).
static void attach(NvnCmdBuf *cb, uint64_t g, uint64_t size) {
    if (cb->recording && cb->has_mem) raw_rec(mirror(cb->mem + cb->used), CMD_JUMP, sizeof(CmdRec))->x[0] = mirror(g);
    cb->mem = g, cb->size = size, cb->used = 0, cb->over = false, cb->has_mem = true;
}

NVN(nvnCommandBufferAddCommandMemory) {
    NvnCmdBuf *cb = cb_of(A(0));
    uint64_t off = A(2), size = A(3);
    attach(cb, A(1) ? HOST(NvnPool, A(1))->storage + off : (1ull << 62) | ((uint64_t)cb->id << 32) | off, size);
}
NVN(nvnCommandBufferAddControlMemory) { (void)c; }
NVN(nvnCommandBufferGetCommandMemorySize) { RET(cb_of(A(0))->size); }
NVN(nvnCommandBufferGetCommandMemoryUsed) {
    NvnCmdBuf *cb = cb_of(A(0));
    RET(cb->used < cb->size ? cb->used : cb->size);
}
NVN(nvnCommandBufferGetCommandMemoryFree) {
    NvnCmdBuf *cb = cb_of(A(0));
    RET(cb->size > cb->used + GUEST_RESERVE ? cb->size - cb->used - GUEST_RESERVE : 0);
}
NVN(nvnCommandBufferGetControlMemorySize) { RET(0x10000); }
NVN(nvnCommandBufferGetControlMemoryUsed) { RET(0); }
NVN(nvnCommandBufferGetControlMemoryFree) { RET(0x10000); }
NVN(nvnCommandBufferSetMemoryCallback) { cb_of(A(0))->callback = A(1); }
NVN(nvnCommandBufferGetMemoryCallback) { RET(cb_of(A(0))->callback); }
NVN(nvnCommandBufferSetMemoryCallbackData) { cb_of(A(0))->callback_data = A(1); }
NVN(nvnCommandBufferGetMemoryCallbackData) { RET(cb_of(A(0))->callback_data); }
NVN(nvnCommandBufferSetCommandMemoryCallbackEnabled) { (void)c; }

// Reserve a record. May call back into the guest for more memory, so callers snapshot their
// arguments first.
static CmdRec *rec(Cpu *c, NvnCmdBuf *cb, uint32_t op, uint32_t extra) {
    uint32_t size = (uint32_t)((sizeof(CmdRec) + extra + 7) & ~7u);
    uint64_t cost = GUEST_CMD + ((extra + 7) & ~7u);
    for (int tries = 0;; tries++) {
        if (cb->has_mem) {  // a record and the jump after it stay inside one mirror page: else go on at the next page
            uint64_t g = cb->mem + cb->used, room = PAGE_SIZE - (g & (PAGE_SIZE - 1));
            if (cost + GUEST_RESERVE > room && (cb->over || cb->used + room + cost + GUEST_RESERVE <= cb->size)) {
                raw_rec(mirror(g), CMD_JUMP, sizeof(CmdRec))->x[0] = mirror(g + room);
                cb->used += room;
            }
            if (cb->over || cb->used + cost + GUEST_RESERVE <= cb->size) break;
        }
        if (!cb->callback || tries == 2) {
            // the game gives no (more) memory: go on in host memory of this command buffer's own (reported use stops
            // at the chunk's size) until it adds some
            static int nlog;
            if (nlog++ < 5)
                LOG("[nvn] cmdbuf %llx: no guest command memory left (%llx, size %llx), recording on in host memory\n",
                    (unsigned long long)cb->guest, (unsigned long long)cb->mem, (unsigned long long)cb->size);
            attach(cb, (1ull << 61) | ((uint64_t)cb->id << 32), 1ull << 31);
            cb->over = true;
            continue;
        }
        uint64_t saved[8];
        memcpy(saved, c->x, sizeof saved);
        c->x[0] = cb->guest;
        c->x[1] = 0;  // NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY
        c->x[2] = cost + GUEST_RESERVE;
        c->x[3] = cb->callback_data;
        guest_call(c, cb->callback);
        memcpy(c->x, saved, sizeof saved);
    }
    // (the record's size spans its whole mirror slot, so walking the list - p += size - finds the next one)
    CmdRec *r = raw_rec(mirror(cb->mem + cb->used), op, (uint32_t)(cost * HOST_PER_GUEST));
    (void)size;
    cb->used += cost;
    return r;
}

NVN(nvnCommandBufferBeginRecording) {
    NvnCmdBuf *cb = cb_of(A(0));
    cb->recording = true;
    cb->start = (uint64_t)(uintptr_t)rec(c, cb, CMD_BARRIER, 0);  // the list starts here
}
NVN(nvnCommandBufferEndRecording) {
    NvnCmdBuf *cb = cb_of(A(0));
    rec(c, cb, CMD_END, 0);
    cb->recording = false;
    RET(cb->start);
}
NVN(nvnCommandBufferIsRecording) { RET(cb_of(A(0))->recording); }

// ---- generic recorders
typedef struct { uint64_t x[8]; float f[4]; } Snap;
static Snap snap(Cpu *c) {
    Snap s;
    memcpy(s.x, c->x, sizeof s.x);
    for (int i = 0; i < 4; i++) s.f[i] = *(float *)&c->v[i];
    return s;
}
static CmdRec *record(Cpu *c, uint32_t op, uint32_t extra, Snap *s) {
    CmdRec *r = rec(c, cb_of(s->x[0]), op, extra);
    memcpy(r->x, s->x + 1, sizeof r->x);
    memcpy(r->f, s->f, sizeof r->f);
    return r;
}
// record with a copy of `len` bytes from the guest pointer in argument `arg`
static CmdRec *record_copy(Cpu *c, uint32_t op, int arg, uint32_t len) {
    Snap s = snap(c);
    CmdRec *r = record(c, op, len, &s);
    if (s.x[arg] && len) memcpy(r->extra, (void *)(uintptr_t)s.x[arg], len);
    return r;
}
#define PLAIN(name, op) NVN(name) { Snap s = snap(c); record(c, op, 0, &s); }

// ---- state binding
NVN(nvnCommandBufferBindProgram) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_PROGRAM, 0, &s);
    r->x[0] = (uint64_t)(uintptr_t)HOST(NvnProgram, s.x[1]);  // host program
}
NVN(nvnCommandBufferBindBlendState) { record_copy(c, CMD_BIND_BLEND, 1, 8); }
NVN(nvnCommandBufferBindChannelMaskState) { record_copy(c, CMD_BIND_CHANNEL_MASK, 1, 4); }
NVN(nvnCommandBufferBindColorState) { record_copy(c, CMD_BIND_COLOR, 1, 4); }
NVN(nvnCommandBufferBindDepthStencilState) { record_copy(c, CMD_BIND_DEPTH_STENCIL, 1, 8); }
NVN(nvnCommandBufferBindMultisampleState) { record_copy(c, CMD_BIND_MULTISAMPLE, 1, 0x18); }
NVN(nvnCommandBufferBindPolygonState) { record_copy(c, CMD_BIND_POLYGON, 1, 4); }
NVN(nvnCommandBufferBindVertexAttribState) { record_copy(c, CMD_BIND_VERTEX_ATTRIB, 2, (uint32_t)A(1) * 4); }
NVN(nvnCommandBufferBindVertexStreamState) { record_copy(c, CMD_BIND_VERTEX_STREAM, 2, (uint32_t)A(1) * 8); }

// (cmd, first, count, const NVNbufferRange*) and the single-binding forms
NVN(nvnCommandBufferBindVertexBuffers) { record_copy(c, CMD_BIND_VERTEX_BUFFERS, 3, (uint32_t)A(2) * 16); }
NVN(nvnCommandBufferBindVertexBuffer) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_VERTEX_BUFFERS, 16, &s);
    r->x[0] = s.x[1]; r->x[1] = 1;
    memcpy(r->extra, &s.x[2], 16);
}
// (cmd, stage, first, count, const NVNbufferRange*)
NVN(nvnCommandBufferBindUniformBuffers) { record_copy(c, CMD_BIND_UNIFORM_BUFFERS, 4, (uint32_t)A(3) * 16); }
NVN(nvnCommandBufferBindUniformBuffer) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_UNIFORM_BUFFERS, 16, &s);
    r->x[0] = s.x[1]; r->x[1] = s.x[2]; r->x[2] = 1;
    memcpy(r->extra, &s.x[3], 16);
}
NVN(nvnCommandBufferBindStorageBuffers) { record_copy(c, CMD_BIND_STORAGE_BUFFERS, 4, (uint32_t)A(3) * 16); }
NVN(nvnCommandBufferBindStorageBuffer) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_STORAGE_BUFFERS, 16, &s);
    r->x[0] = s.x[1]; r->x[1] = s.x[2]; r->x[2] = 1;
    memcpy(r->extra, &s.x[3], 16);
}
// (cmd, stage, first, count, const handle*)
NVN(nvnCommandBufferBindTextures) { record_copy(c, CMD_BIND_TEXTURES, 4, (uint32_t)A(3) * 8); }
NVN(nvnCommandBufferBindTexture) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_TEXTURES, 8, &s);
    r->x[0] = s.x[1]; r->x[1] = s.x[2]; r->x[2] = 1;
    memcpy(r->extra, &s.x[3], 8);
}
NVN(nvnCommandBufferBindImages) { record_copy(c, CMD_BIND_IMAGES, 4, (uint32_t)A(3) * 8); }
NVN(nvnCommandBufferBindImage) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_IMAGES, 8, &s);
    r->x[0] = s.x[1]; r->x[1] = s.x[2]; r->x[2] = 1;
    memcpy(r->extra, &s.x[3], 8);
}
NVN(nvnCommandBufferBindSeparateTextures) { record_copy(c, CMD_BIND_TEXTURES, 4, (uint32_t)A(3) * 8); }
NVN(nvnCommandBufferBindSeparateTexture) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_BIND_TEXTURES, 8, &s);
    r->x[0] = s.x[1]; r->x[1] = s.x[2]; r->x[2] = 1;
    memcpy(r->extra, &s.x[3], 8);
}
NVN(nvnCommandBufferBindSeparateSamplers) { (void)c; }
NVN(nvnCommandBufferBindSeparateSampler) { (void)c; }
NVN(nvnCommandBufferBindTransformFeedbackBuffers) { (void)c; }
NVN(nvnCommandBufferBindTransformFeedbackBuffer) { (void)c; }
NVN(nvnCommandBufferBindCoverageModulationTable) { (void)c; }

NVN(nvnCommandBufferSetTexturePool) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_SET_TEXTURE_POOL, 0, &s);
    r->x[0] = (uint64_t)(uintptr_t)HOST(NvnDescPool, s.x[1]);
}
NVN(nvnCommandBufferSetSamplerPool) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_SET_SAMPLER_POOL, 0, &s);
    r->x[0] = (uint64_t)(uintptr_t)HOST(NvnDescPool, s.x[1]);
}

// SetRenderTargets(cmd, n, colors[], colorViews[], depth, depthView)
// extra: { u64 tex[8]; NvnTextureView views[8]; u8 has_view[8]; u64 depth; NvnTextureView dview; u8 has_dview }
typedef struct {
    uint64_t tex[8];
    NvnTextureView views[8];
    uint8_t has_view[8];
    uint64_t depth;
    NvnTextureView dview;
    uint8_t has_dview;
} RtRec;
NVN(nvnCommandBufferSetRenderTargets) {
    Snap s = snap(c);
    int n = (int)s.x[1];
    if (n > 8) n = 8;
    RtRec rt = {0};
    const uint64_t *colors = (const uint64_t *)(uintptr_t)s.x[2], *views = (const uint64_t *)(uintptr_t)s.x[3];
    for (int i = 0; i < n; i++) {
        rt.tex[i] = colors && colors[i] ? (uint64_t)(uintptr_t)HOST(NvnTexture, colors[i]) : 0;
        if (views && views[i]) { rt.has_view[i] = 1; memcpy(&rt.views[i], (void *)(uintptr_t)views[i], sizeof(NvnTextureView)); }
    }
    rt.depth = s.x[4] ? (uint64_t)(uintptr_t)HOST(NvnTexture, s.x[4]) : 0;
    if (s.x[5]) { rt.has_dview = 1; memcpy(&rt.dview, (void *)(uintptr_t)s.x[5], sizeof(NvnTextureView)); }
    CmdRec *r = record(c, CMD_SET_RENDER_TARGETS, sizeof rt, &s);
    r->x[0] = (uint64_t)n;
    memcpy(r->extra, &rt, sizeof rt);
}

// viewports/scissors/depth ranges
NVN(nvnCommandBufferSetViewports) { record_copy(c, CMD_SET_VIEWPORTS, 3, (uint32_t)A(2) * 16); }
NVN(nvnCommandBufferSetViewport) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_SET_VIEWPORTS, 16, &s);
    float v[4] = {(float)(int32_t)s.x[1], (float)(int32_t)s.x[2], (float)(int32_t)s.x[3], (float)(int32_t)s.x[4]};
    r->x[0] = 0; r->x[1] = 1;
    memcpy(r->extra, v, 16);
}
NVN(nvnCommandBufferSetScissors) { record_copy(c, CMD_SET_SCISSORS, 3, (uint32_t)A(2) * 16); }
NVN(nvnCommandBufferSetScissor) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_SET_SCISSORS, 16, &s);
    int32_t v[4] = {(int32_t)s.x[1], (int32_t)s.x[2], (int32_t)s.x[3], (int32_t)s.x[4]};
    r->x[0] = 0; r->x[1] = 1;
    memcpy(r->extra, v, 16);
}
NVN(nvnCommandBufferSetDepthRanges) { record_copy(c, CMD_SET_DEPTH_RANGES, 3, (uint32_t)A(2) * 8); }
NVN(nvnCommandBufferSetDepthRange) {
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_SET_DEPTH_RANGES, 8, &s);
    r->x[0] = 0; r->x[1] = 1;
    memcpy(r->extra, s.f, 8);
}
NVN(nvnCommandBufferSetBlendColor) { record_copy(c, CMD_SET_BLEND_COLOR, 1, 16); }
NVN(nvnCommandBufferSetStencilRef) { Snap s = snap(c); CmdRec *r = record(c, CMD_SET_STENCIL, 0, &s); r->x[6] = 0; }
NVN(nvnCommandBufferSetStencilMask) { Snap s = snap(c); CmdRec *r = record(c, CMD_SET_STENCIL, 0, &s); r->x[6] = 1; }
NVN(nvnCommandBufferSetStencilValueMask) { Snap s = snap(c); CmdRec *r = record(c, CMD_SET_STENCIL, 0, &s); r->x[6] = 2; }
PLAIN(nvnCommandBufferSetPrimitiveRestart, CMD_SET_PRIMITIVE_RESTART)
PLAIN(nvnCommandBufferSetAlphaRef, CMD_SET_ALPHA_REF)
PLAIN(nvnCommandBufferSetDepthBounds, CMD_SET_DEPTH_BOUNDS)
PLAIN(nvnCommandBufferSetPolygonOffsetClamp, CMD_SET_POLYGON_OFFSET)
PLAIN(nvnCommandBufferSetLineWidth, CMD_SET_LINE_WIDTH)
PLAIN(nvnCommandBufferSetPointSize, CMD_SET_POINT_SIZE)
PLAIN(nvnCommandBufferSetSampleMask, CMD_SET_SAMPLE_MASK)
PLAIN(nvnCommandBufferSetRenderEnable, CMD_SET_RENDER_ENABLE)
// SetRenderEnableConditional(cmd, mode, counters): rendering on or off by comparing the 64-bit values at counters and
// counters + 16 (two counter reports) when the list runs. Mode 0: render if equal, 1: render if not equal.
PLAIN(nvnCommandBufferSetRenderEnableConditional, CMD_SET_RENDER_ENABLE_COND)
NVN(nvnCommandBufferSetDepthClamp) { (void)c; }
NVN(nvnCommandBufferSetRasterizerDiscard) { (void)c; }
NVN(nvnCommandBufferSetConservativeRasterEnable) { (void)c; }
NVN(nvnCommandBufferSetConservativeRasterDilate) { (void)c; }
NVN(nvnCommandBufferSetSubpixelPrecisionBias) { (void)c; }
NVN(nvnCommandBufferSetViewportSwizzles) { (void)c; }
NVN(nvnCommandBufferSetStencilCullCriteria) { (void)c; }
NVN(nvnCommandBufferSetColorReductionEnable) { (void)c; }
NVN(nvnCommandBufferSetColorReductionThresholds) { (void)c; }
NVN(nvnCommandBufferSetTiledCacheAction) { (void)c; }
NVN(nvnCommandBufferSetTiledCacheTileSize) { (void)c; }
NVN(nvnCommandBufferSetShaderScratchMemory) { (void)c; }
NVN(nvnCommandBufferSetPatchSize) { (void)c; }
NVN(nvnCommandBufferSetInnerTessellationLevels) { (void)c; }
NVN(nvnCommandBufferSetOuterTessellationLevels) { (void)c; }
NVN(nvnCommandBufferSetProgramSubroutines) { (void)c; }
NVN(nvnCommandBufferSaveZCullData) { (void)c; }
NVN(nvnCommandBufferRestoreZCullData) { (void)c; }

static uint64_t copy_row_stride, copy_image_stride;
RT_ON_RESET(cmdbuf_reset) {
    copy_row_stride = copy_image_stride = 0;
    for (int i = 0; i < PAGE_BUCKETS; i++) {
        for (MirrorPage *pg = pages[i], *next; pg; pg = next) next = pg->next, free(pg->mem), free(pg);
        pages[i] = NULL;
    }
}
NVN(nvnCommandBufferSetCopyRowStride) {
    Snap s = snap(c);
    copy_row_stride = s.x[1];
    CmdRec *r = record(c, CMD_SET_COPY_STRIDES, 0, &s);
    r->x[0] = copy_row_stride; r->x[1] = copy_image_stride;
}
NVN(nvnCommandBufferSetCopyImageStride) {
    Snap s = snap(c);
    copy_image_stride = s.x[1];
    CmdRec *r = record(c, CMD_SET_COPY_STRIDES, 0, &s);
    r->x[0] = copy_row_stride; r->x[1] = copy_image_stride;
}
NVN(nvnCommandBufferGetCopyRowStride) { RET(copy_row_stride); }
NVN(nvnCommandBufferGetCopyImageStride) { RET(copy_image_stride); }

// ---- clears
NVN(nvnCommandBufferClearColor) { record_copy(c, CMD_CLEAR_COLOR, 2, 16); }
NVN(nvnCommandBufferClearColori) { CmdRec *r = record_copy(c, CMD_CLEAR_COLOR, 2, 16); r->x[5] = 1; }
NVN(nvnCommandBufferClearColorui) { CmdRec *r = record_copy(c, CMD_CLEAR_COLOR, 2, 16); r->x[5] = 2; }
PLAIN(nvnCommandBufferClearDepthStencil, CMD_CLEAR_DEPTH_STENCIL)
// ClearTexture(cmd, texture, view, region, color, mask)
typedef struct { uint64_t tex; NvnTextureView view; uint8_t has_view; int32_t region[6]; float color[4]; } ClearTexRec;
static void clear_texture(Cpu *c, int kind) {
    Snap s = snap(c);
    ClearTexRec ct = {0};
    ct.tex = (uint64_t)(uintptr_t)HOST(NvnTexture, s.x[1]);
    if (s.x[2]) { ct.has_view = 1; memcpy(&ct.view, (void *)(uintptr_t)s.x[2], sizeof ct.view); }
    if (s.x[3]) memcpy(ct.region, (void *)(uintptr_t)s.x[3], sizeof ct.region);
    if (s.x[4]) memcpy(ct.color, (void *)(uintptr_t)s.x[4], 16);
    CmdRec *r = record(c, CMD_CLEAR_TEXTURE, sizeof ct, &s);
    r->x[6] = (uint64_t)kind;
    memcpy(r->extra, &ct, sizeof ct);
}
NVN(nvnCommandBufferClearTexture) { clear_texture(c, 0); }
NVN(nvnCommandBufferClearTexturei) { clear_texture(c, 1); }
NVN(nvnCommandBufferClearTextureui) { clear_texture(c, 2); }
PLAIN(nvnCommandBufferClearBuffer, CMD_CLEAR_BUFFER)
// DiscardColor(cmdbuf, index): the target's contents become undefined. On the Switch a discarded (compressed)
// target reads back cleared; areas the game then leaves undrawn (e.g. a pit after a floor tile falls away) stay
// black there. Treated as a clear to (0,0,0,0) (LARECOMP_KEEP_DISCARD=1: old no-op behaviour).
NVN(nvnCommandBufferDiscardColor) {
    static int keep = -1, logged;
    if (keep < 0) keep = getenv("LARECOMP_KEEP_DISCARD") != NULL;
    if (logged < 5) { logged++; LOG("[nvn] DiscardColor index %llu%s\n", (unsigned long long)c->x[1], keep ? " (kept)" : " -> clear"); }
    if (keep) return;
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_CLEAR_COLOR, 16, &s);
    memset(r->extra, 0, 16);
    r->x[2] = 0xF;  // all channels
    r->x[5] = 0;    // float clear
}
NVN(nvnCommandBufferDiscardDepthStencil) { (void)c; }

// ---- draws (all integer arguments fit in x1..x7)
NVN(nvnCommandBufferDrawArrays) { Snap s = snap(c); CmdRec *r = record(c, CMD_DRAW_ARRAYS, 0, &s); r->x[3] = 0; r->x[4] = 1; }
NVN(nvnCommandBufferDrawArraysInstanced) { Snap s = snap(c); record(c, CMD_DRAW_ARRAYS, 0, &s); }
// Debug: LARECOMP_TRACE_COUNT=<n> logs the guest call chain of indexed draws with n indices.
static void trace_draw(Cpu *c, uint64_t count) {
    static long want = -2;
    if (want == -2) want = getenv("LARECOMP_TRACE_COUNT") ? atol(getenv("LARECOMP_TRACE_COUNT")) : -1;
    if (want < 0 || (long)count != want) return;
    static int n;
    if (n++ > 40) return;
    LOG("[trace] draw count %llu lr %llx chain:", (unsigned long long)count, (unsigned long long)c->x[30]);
    uint64_t fp = c->x[29];
    for (int i = 0; i < 14 && fp >= 0x7000000000ull && fp < 0x8000000000ull && (fp & 7) == 0; i++) {
        uint64_t next = *(uint64_t *)(uintptr_t)fp, lr = *(uint64_t *)(uintptr_t)(fp + 8);
        LOG(" %llx", (unsigned long long)lr);
        if (next <= fp) break;
        fp = next;
    }
    LOG("\n");
}

NVN(nvnCommandBufferDrawElements) {
    trace_draw(c, c->x[3]);
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_DRAW_ELEMENTS, 0, &s);
    r->x[4] = 0; r->x[5] = 0; r->x[6] = 1;  // base vertex, base instance, instances
}
NVN(nvnCommandBufferDrawElementsBaseVertex) {
    trace_draw(c, c->x[3]);
    Snap s = snap(c);
    CmdRec *r = record(c, CMD_DRAW_ELEMENTS, 0, &s);
    r->x[5] = 0; r->x[6] = 1;
}
NVN(nvnCommandBufferDrawElementsInstanced) { trace_draw(c, c->x[3]); Snap s = snap(c); record(c, CMD_DRAW_ELEMENTS, 0, &s); }
PLAIN(nvnCommandBufferDrawArraysIndirect, CMD_DRAW_ARRAYS_INDIRECT)
PLAIN(nvnCommandBufferDrawElementsIndirect, CMD_DRAW_ELEMENTS_INDIRECT)
NVN(nvnCommandBufferMultiDrawArraysIndirectCount) { (void)c; }
NVN(nvnCommandBufferMultiDrawElementsIndirectCount) { (void)c; }
NVN(nvnCommandBufferDrawTransformFeedback) { (void)c; }
NVN(nvnCommandBufferDrawTexture) { (void)c; }
PLAIN(nvnCommandBufferDispatchCompute, CMD_DISPATCH)
PLAIN(nvnCommandBufferDispatchComputeIndirect, CMD_DISPATCH_INDIRECT)
NVN(nvnCommandBufferBeginTransformFeedback) { (void)c; }
NVN(nvnCommandBufferEndTransformFeedback) { (void)c; }
NVN(nvnCommandBufferPauseTransformFeedback) { (void)c; }
NVN(nvnCommandBufferResumeTransformFeedback) { (void)c; }

// ---- copies
typedef struct { uint64_t tex; NvnTextureView view; uint8_t has_view; int32_t region[6]; } TexRef;
static void tex_ref(TexRef *t, uint64_t tex, uint64_t view, uint64_t region) {
    t->tex = tex ? (uint64_t)(uintptr_t)HOST(NvnTexture, tex) : 0;
    if (view) { t->has_view = 1; memcpy(&t->view, (void *)(uintptr_t)view, sizeof t->view); }
    if (region) memcpy(t->region, (void *)(uintptr_t)region, sizeof t->region);
}
NVN(nvnCommandBufferCopyBufferToTexture) {  // (cmd, src, dst, dstView, dstRegion, flags)
    Snap s = snap(c);
    TexRef t = {0};
    tex_ref(&t, s.x[2], s.x[3], s.x[4]);
    CmdRec *r = record(c, CMD_COPY_BUFFER_TO_TEXTURE, sizeof t, &s);
    memcpy(r->extra, &t, sizeof t);
}
NVN(nvnCommandBufferCopyTextureToBuffer) {  // (cmd, src, srcView, srcRegion, dst, flags)
    Snap s = snap(c);
    TexRef t = {0};
    tex_ref(&t, s.x[1], s.x[2], s.x[3]);
    CmdRec *r = record(c, CMD_COPY_TEXTURE_TO_BUFFER, sizeof t, &s);
    memcpy(r->extra, &t, sizeof t);
}
NVN(nvnCommandBufferCopyTextureToTexture) {  // (cmd, src, srcView, srcRegion, dst, dstView, dstRegion, flags)
    Snap s = snap(c);
    TexRef t[2] = {{0}};
    tex_ref(&t[0], s.x[1], s.x[2], s.x[3]);
    tex_ref(&t[1], s.x[4], s.x[5], s.x[6]);
    CmdRec *r = record(c, CMD_COPY_TEXTURE_TO_TEXTURE, sizeof t, &s);
    memcpy(r->extra, t, sizeof t);
}
PLAIN(nvnCommandBufferCopyBufferToBuffer, CMD_COPY_BUFFER_TO_BUFFER)
NVN(nvnCommandBufferDownsample) {
    Snap s = snap(c);
    TexRef t[2] = {{0}};
    tex_ref(&t[0], s.x[1], 0, 0);
    tex_ref(&t[1], s.x[2], 0, 0);
    CmdRec *r = record(c, CMD_DOWNSAMPLE, sizeof t, &s);
    memcpy(r->extra, t, sizeof t);
}
NVN(nvnCommandBufferDownsampleTextureView) {
    Snap s = snap(c);
    TexRef t[2] = {{0}};
    tex_ref(&t[0], s.x[1], s.x[2], 0);
    tex_ref(&t[1], s.x[3], s.x[4], 0);
    CmdRec *r = record(c, CMD_DOWNSAMPLE, sizeof t, &s);
    memcpy(r->extra, t, sizeof t);
}
NVN(nvnCommandBufferTiledDownsample) { (void)c; }
NVN(nvnCommandBufferTiledDownsampleTextureView) { (void)c; }
NVN(nvnCommandBufferResolveDepthBuffer) { (void)c; }
// UpdateUniformBuffer(cmd, buffer, size, offset, dataSize, data)
NVN(nvnCommandBufferUpdateUniformBuffer) { record_copy(c, CMD_UPDATE_UNIFORM_BUFFER, 5, (uint32_t)A(4)); }

// ---- synchronization and misc
NVN(nvnCommandBufferFenceSync) {
    // work executes at submit time, so the sync is satisfied once this list has run
    Snap s = snap(c);
    record(c, CMD_FENCE_SYNC, 0, &s);
}
PLAIN(nvnCommandBufferWaitSync, CMD_WAIT_SYNC)
PLAIN(nvnCommandBufferBarrier, CMD_BARRIER)
PLAIN(nvnCommandBufferSignalEvent, CMD_SIGNAL_EVENT)
PLAIN(nvnCommandBufferWaitEvent, CMD_WAIT_EVENT)
PLAIN(nvnCommandBufferReportCounter, CMD_REPORT_COUNTER)
NVN(nvnCommandBufferReportValue) { (void)c; }
NVN(nvnCommandBufferResetCounter) { (void)c; }
NVN(nvnCommandBufferCallCommands) { record_copy(c, CMD_CALL, 2, (uint32_t)A(1) * 8); }
// CopyCommands(cmd, count, handles): unlike CallCommands, the commands are copied into this list now - the game may
// record over the source lists' memory right after (ACNH's worker threads re-record theirs for the next frame: by
// reference, this frame replayed the next frame's "set target + clear" and presented black).
NVN(nvnCommandBufferCopyCommands) {
    NvnCmdBuf *cb = cb_of(A(0));
    uint64_t n = A(1), handles[64];
    if (n > 64) n = 64;
    memcpy(handles, (const void *)(uintptr_t)A(2), n * 8);  // (rec may call back into the guest)
    for (uint64_t i = 0; i < n; i++) {
        uint64_t p = handles[i];
        for (int guard = 0; p && guard < 1000000; guard++) {
            const CmdRec *src = (const CmdRec *)(uintptr_t)p;
            if (src->op == CMD_END) break;
            if (src->op == CMD_JUMP) { p = src->x[0]; continue; }
            uint32_t size = src->size;
            CmdRec *dst = rec(c, cb, src->op, size - (uint32_t)sizeof(CmdRec));
            memcpy((uint8_t *)dst + 8, (const uint8_t *)src + 8, size - 8);  // (op and size set by rec)
            p += size;
        }
    }
}
NVN(nvnCommandBufferInsertDebugMarker) { (void)c; }
NVN(nvnCommandBufferInsertDebugMarkerDynamic) { (void)c; }
NVN(nvnCommandBufferInsertDebugMarkerStatic) { (void)c; }
NVN(nvnCommandBufferPushDebugGroup) { (void)c; }
NVN(nvnCommandBufferPushDebugGroupDynamic) { (void)c; }
NVN(nvnCommandBufferPushDebugGroupStatic) { (void)c; }
NVN(nvnCommandBufferPopDebugGroup) { (void)c; }
NVN(nvnCommandBufferPopDebugGroupId) { (void)c; }
