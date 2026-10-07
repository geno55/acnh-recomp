// Executes recorded NVN command lists with Metal.
#import <Metal/Metal.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <math.h>
#include <sys/stat.h>
#include <SDL3/SDL_timer.h>

#include "maxwell/shader.h"
#include "nvn.h"
#include "renderer.h"

static id<MTLDevice> dev;
static id<MTLCommandBuffer> cmdbuf;
static id<MTLRenderCommandEncoder> enc;
static id<MTLRenderPipelineState> clear_pipes[64];
static NSMutableDictionary<NSString *, id> *cache;
static uint64_t stat_draws, stat_skipped, stat_passes, stat_dispatches;
static uint64_t op_counts[CMD_COUNT];
bool g_debug_frame;
void renderer_save_texture(id<MTLTexture> tex, const char *path);
void renderer_save_texture_alpha(id<MTLTexture> tex, const char *path);
static char stats_text[128];

// ------------------------------------------------------------------ state
typedef struct {
    NvnTexture *color[8];
    NvnTextureView cview[8];
    uint8_t has_cview[8];
    int ncolor;
    NvnTexture *depth;
    NvnTextureView dview;
    uint8_t has_dview;
} RtState;

typedef struct { uint64_t addr, size; } Range;

static struct {
    RtState rt;
    bool rt_dirty;
    NvnProgram *program;
    uint8_t blend[8][8];
    uint32_t channel_mask;
    uint8_t color_state[4], ds[8], ms[0x18], poly[4];
    uint32_t attrib[16];
    int nattrib;
    uint32_t stream[16][2];
    int nstream;
    Range vbuf[16], ubuf[6][18], sbuf[6][16];
    uint64_t tex[6][32], img[6][8];
    NvnDescPool *tpool, *spool;
    float viewport[16][4];
    int32_t scissor[16][4];
    float depth_range[16][2];
    float blend_color[4];
    uint32_t stencil_ref[2], stencil_mask[2], stencil_vmask[2];
    bool prim_restart;
    uint32_t restart_index;
    uint64_t copy_row_stride, copy_image_stride;
} st;

extern uint32_t g_window_origin_lower_left_hack;
uint32_t nvn_window_origin(void);
bool renderer_origin_lower_left(void) { return nvn_window_origin() == 0; }

const char *renderer_stats(void) {
    static int dumps;
    if (dumps++ < 3) {
        LOG("[metal] command counts:");
        for (int i = 0; i < CMD_COUNT; i++) if (op_counts[i]) LOG(" %d:%llu", i, op_counts[i]);
        LOG("\n");
    }
    snprintf(stats_text, sizeof stats_text, "%llu draws, %llu skipped, %llu passes, %llu dispatches", stat_draws, stat_skipped,
             stat_passes, stat_dispatches);
    stat_draws = stat_skipped = stat_passes = stat_dispatches = 0;
    return stats_text;
}

void renderer_init(id<MTLDevice> d) {
    dev = d;
    cache = [NSMutableDictionary new];
    for (int i = 0; i < 16; i++) {
        st.viewport[i][2] = 1280; st.viewport[i][3] = 720;
        st.scissor[i][2] = 16384; st.scissor[i][3] = 16384;
        st.depth_range[i][1] = 1.0f;
    }
    st.channel_mask = 0xFFFFFFFF;
    st.ds[1] = 1; st.ds[2] = 2;
    st.poly[1] = 1; st.poly[2] = 2;
    for (int i = 0; i < 8; i++) { st.blend[i][1] = 2; st.blend[i][2] = 1; st.blend[i][3] = 2; st.blend[i][4] = 1; st.blend[i][5] = 1; st.blend[i][6] = 1; }
}

static id<MTLCommandBuffer> cb(void) {
    if (!cmdbuf) cmdbuf = [renderer_queue() commandBuffer];
    return cmdbuf;
}

static int debug_pass_no;
static void end_pass(void) {
    if (enc) {
        [enc endEncoding];
        enc = nil;
        if (g_debug_frame && st.rt.ncolor && st.rt.color[0] && st.rt.color[0]->backend) {
            id<MTLTexture> t = renderer_texture(st.rt.color[0], nil, true);
            id<MTLCommandBuffer> c = cmdbuf;
            cmdbuf = nil;
            [c commit];
            [c waitUntilCompleted];
            char path[256];
            snprintf(path, sizeof path, "build/pass_%03d.png", debug_pass_no++);
            renderer_save_texture(t, path);
        }
    }
}

static void ring_reset(void);
void renderer_flush(void) {
    end_pass();
    if (cmdbuf) {
        [cmdbuf commit];
        [cmdbuf waitUntilCompleted];
        if (cmdbuf.error) LOG("[metal] command buffer error: %s\n", cmdbuf.error.localizedDescription.UTF8String);
        cmdbuf = nil;
    }
    ring_reset();
}

// ------------------------------------------------------------------ textures with views
static id<MTLTexture> view_texture(NvnTexture *t, const NvnTextureView *v, bool has_view, bool render,
                                   id<MTLBlitCommandEncoder> blit) {
    id<MTLTexture> base = renderer_texture(t, blit, render);
    if (!has_view || !v->setmask) return base;
    MTLPixelFormat pf = (v->setmask & 4) ? renderer_pixel_format(v->format) : base.pixelFormat;
    NSUInteger lv0 = (v->setmask & 1) ? v->base_level : 0;
    NSUInteger nlv = (v->setmask & 1) && v->num_levels ? v->num_levels : base.mipmapLevelCount - lv0;
    NSUInteger ly0 = (v->setmask & 2) ? v->min_layer : 0;
    NSUInteger nly = (v->setmask & 2) && v->num_layers ? v->num_layers : base.arrayLength - ly0;
    if (base.textureType == MTLTextureTypeCube) nly = 6;
    MTLTextureType type = base.textureType;
    if (render && (type == MTLTextureType2DArray || type == MTLTextureTypeCube) && nly == 1) type = MTLTextureType2D;
    if (lv0 + nlv > base.mipmapLevelCount) nlv = base.mipmapLevelCount - lv0;
    if (pf == base.pixelFormat && lv0 == 0 && nlv == base.mipmapLevelCount && ly0 == 0 && type == base.textureType)
        return base;
    id<MTLTexture> view = [base newTextureViewWithPixelFormat:pf textureType:type levels:NSMakeRange(lv0, nlv)
                                                       slices:NSMakeRange(ly0, type == MTLTextureType2D ? 1 : nly)];
    return view ? view : base;
}

// ------------------------------------------------------------------ render passes
static void begin_pass(void) {
    if (enc && !st.rt_dirty) return;
    end_pass();
    st.rt_dirty = false;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    int w = 0, h = 0;
    for (int i = 0; i < st.rt.ncolor; i++) {
        NvnTexture *t = st.rt.color[i];
        if (!t) continue;
        renderer_mark_gpu_owned(t);
        id<MTLTexture> tex = view_texture(t, &st.rt.cview[i], st.rt.has_cview[i], true, nil);
        rp.colorAttachments[i].texture = tex;
        rp.colorAttachments[i].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        w = (int)tex.width; h = (int)tex.height;
    }
    if (st.rt.depth) {
        renderer_mark_gpu_owned(st.rt.depth);
        id<MTLTexture> tex = view_texture(st.rt.depth, &st.rt.dview, st.rt.has_dview, true, nil);
        if (renderer_format_is_depth(st.rt.depth->format) && st.rt.depth->format != 0x31) {
            rp.depthAttachment.texture = tex;
            rp.depthAttachment.loadAction = MTLLoadActionLoad;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (renderer_format_has_stencil(st.rt.depth->format)) {
            rp.stencilAttachment.texture = tex;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        if (!w) { w = (int)tex.width; h = (int)tex.height; }
    }
    if (!w) {
        rp.renderTargetWidth = 16; rp.renderTargetHeight = 16;
        rp.defaultRasterSampleCount = 1;
    }
    enc = [cb() renderCommandEncoderWithDescriptor:rp];
    stat_passes++;
}

static void pass_size(int *w, int *h) {
    *w = *h = 0;
    for (int i = 0; i < st.rt.ncolor && !*w; i++)
        if (st.rt.color[i]) { *w = (int)st.rt.color[i]->width; *h = (int)st.rt.color[i]->height; }
    if (!*w && st.rt.depth) { *w = (int)st.rt.depth->width; *h = (int)st.rt.depth->height; }
}

static void apply_scissor(void) {
    int w, h;
    pass_size(&w, &h);
    if (!w) return;
    int x = st.scissor[0][0], y = st.scissor[0][1], sw = st.scissor[0][2], sh = st.scissor[0][3];
    if (x < 0) { sw += x; x = 0; }
    if (y < 0) { sh += y; y = 0; }
    if (x >= w || y >= h) { x = y = 0; sw = sh = 0; }
    if (x + sw > w) sw = w - x;
    if (y + sh > h) sh = h - y;
    if (sw < 0) sw = 0;
    if (sh < 0) sh = 0;
    [enc setScissorRect:(MTLScissorRect){(NSUInteger)x, (NSUInteger)y, (NSUInteger)sw, (NSUInteger)sh}];
}

// ------------------------------------------------------------------ clears (full-screen triangle)
static const char *clear_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]], constant float4 &d [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2.0 - 1.0, d.x, 1); return o; }\n"
    "struct OF { float4 c [[color(INDEX)]]; };\n"
    "fragment OF fs_f(V in [[stage_in]], constant float4 &c [[buffer(0)]]) { OF o; o.c = c; return o; }\n"
    "struct OI { int4 c [[color(INDEX)]]; };\n"
    "fragment OI fs_i(V in [[stage_in]], constant int4 &c [[buffer(0)]]) { OI o; o.c = c; return o; }\n"
    "struct OU { uint4 c [[color(INDEX)]]; };\n"
    "fragment OU fs_u(V in [[stage_in]], constant uint4 &c [[buffer(0)]]) { OU o; o.c = c; return o; }\n"
    "fragment void fs_none(V in [[stage_in]]) {}\n";

static id<MTLLibrary> clear_lib(int index) {
    static id<MTLLibrary> libs[8];
    if (!libs[index]) {
        NSString *src = [@(clear_src) stringByReplacingOccurrencesOfString:@"INDEX" withString:[NSString stringWithFormat:@"%d", index]];
        NSError *err;
        libs[index] = [dev newLibraryWithSource:src options:nil error:&err];
        if (!libs[index]) FATAL("clear shader: %s\n", err.localizedDescription.UTF8String);
    }
    return libs[index];
}

static void attachment_formats(MTLRenderPipelineDescriptor *pd) {
    for (int i = 0; i < st.rt.ncolor; i++)
        if (st.rt.color[i]) pd.colorAttachments[i].pixelFormat = view_texture(st.rt.color[i], &st.rt.cview[i], st.rt.has_cview[i], true, nil).pixelFormat;
    if (st.rt.depth) {
        MTLPixelFormat pf = renderer_pixel_format(st.rt.depth->format);
        if (renderer_format_is_depth(st.rt.depth->format) && st.rt.depth->format != 0x31) pd.depthAttachmentPixelFormat = pf;
        if (renderer_format_has_stencil(st.rt.depth->format)) pd.stencilAttachmentPixelFormat = pf;
    }
    for (int i = 0; i < st.rt.ncolor; i++)
        if (st.rt.color[i] && st.rt.color[i]->samples > 1) pd.rasterSampleCount = st.rt.color[i]->samples;
}

static void clear(int index, int kind, const void *color, uint32_t mask, bool depth, float dval, bool stencil,
                  uint32_t sval, uint32_t smask) {
    begin_pass();
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    id<MTLLibrary> lib = clear_lib(index < 0 ? 0 : index);
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    static NSString *const fs[] = {@"fs_f", @"fs_i", @"fs_u"};
    pd.fragmentFunction = [lib newFunctionWithName:index >= 0 ? fs[kind] : @"fs_none"];
    attachment_formats(pd);
    for (int i = 0; i < 8; i++) pd.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
    if (index >= 0) {
        MTLColorWriteMask m = 0;
        if (mask & 1) m |= MTLColorWriteMaskRed;
        if (mask & 2) m |= MTLColorWriteMaskGreen;
        if (mask & 4) m |= MTLColorWriteMaskBlue;
        if (mask & 8) m |= MTLColorWriteMaskAlpha;
        pd.colorAttachments[index].writeMask = m;
    }
    NSError *err;
    NSString *key = [NSString stringWithFormat:@"clear %d %d %u %d %d %lu %lu %lu", index, kind, mask, depth, stencil,
                     (unsigned long)pd.colorAttachments[index < 0 ? 0 : index].pixelFormat,
                     (unsigned long)pd.depthAttachmentPixelFormat, (unsigned long)pd.stencilAttachmentPixelFormat];
    id<MTLRenderPipelineState> pipe = cache[key];
    if (!pipe) {
        pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pipe) { LOG("[metal] clear pipeline: %s\n", err.localizedDescription.UTF8String); return; }
        cache[key] = pipe;
    }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = depth;
    if (stencil) {
        MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = MTLCompareFunctionAlways;
        sd.depthStencilPassOperation = MTLStencilOperationReplace;
        sd.writeMask = smask;
        dd.frontFaceStencil = sd;
        dd.backFaceStencil = sd;
    }
    [enc setRenderPipelineState:pipe];
    [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dd]];
    [enc setStencilReferenceValue:sval];
    [enc setCullMode:MTLCullModeNone];
    int w, h;
    pass_size(&w, &h);
    [enc setViewport:(MTLViewport){0, 0, w, h, 0, 1}];
    apply_scissor();
    float d4[4] = {dval, 0, 0, 0};
    [enc setVertexBytes:d4 length:16 atIndex:0];
    if (index >= 0) [enc setFragmentBytes:color length:16 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

// ------------------------------------------------------------------ shaders (debug dump)
static void dump_program(NvnProgram *p) {
    if (!getenv("LARECOMP_DUMP_SHADERS")) return;
    static int n;
    mkdir("build/shaders", 0755);
    for (int s = 0; s < 6; s++) {
        if (!(p->stage_mask & (1u << s))) continue;
        char path[256];
        snprintf(path, sizeof path, "build/shaders/p%03d_s%d_code.bin", n, s);
        FILE *f = fopen(path, "wb");
        fwrite((void *)(uintptr_t)p->stages[s].code_addr, 1, 0x10000, f);
        fclose(f);
        snprintf(path, sizeof path, "build/shaders/p%03d_s%d_ctrl.bin", n, s);
        f = fopen(path, "wb");
        fwrite(p->stages[s].control, 1, 0x4000, f);
        fclose(f);
    }
    n++;
}

// ------------------------------------------------------------------ draw support
uint32_t nvn_window_origin(void);
uint32_t nvn_depth_mode(void);
static int cbuf_base = 3, tex_base = 8;

@interface Prog : NSObject {
@public
    id<MTLFunction> vs, fs;
    ShaderInfo *vi, *fi;
    bool failed;
}
@end
@implementation Prog
@end

static id<MTLBuffer> ring;
static uint64_t ring_off;
#define RING_SIZE (64u << 20)

static uint64_t ring_alloc(const void *data, uint64_t size) {
    if (!ring) ring = [dev newBufferWithLength:RING_SIZE options:MTLResourceStorageModeShared];
    uint64_t aligned = (ring_off + 255) & ~255ull;
    if (aligned + size > RING_SIZE) {
        renderer_flush();  // the ring resets after the GPU has caught up
        aligned = 0;
    }
    memcpy((uint8_t *)ring.contents + aligned, data, size);
    ring_off = aligned + size;
    return aligned;
}

static void ring_reset(void) { ring_off = 0; }

// Bind guest memory [addr, addr+size) as a buffer: zero-copy inside the heap, copied otherwise.
static void bind_guest(id<MTLRenderCommandEncoder> e, bool vertex_stage, uint64_t addr, uint64_t size, int index) {
    if (addr >= HEAP_BASE && addr + size <= HEAP_BASE + HEAP_MAX && (addr & 3) == 0) {
        if (vertex_stage) [e setVertexBuffer:g_guest_buffer offset:addr - HEAP_BASE atIndex:index];
        else [e setFragmentBuffer:g_guest_buffer offset:addr - HEAP_BASE atIndex:index];
        return;
    }
    uint64_t off = ring_alloc((void *)(uintptr_t)addr, size);
    if (vertex_stage) [e setVertexBuffer:ring offset:off atIndex:index];
    else [e setFragmentBuffer:ring offset:off atIndex:index];
}

static int attr_kind(uint32_t fmt) {
    switch (fmt) {
    case 0x03: case 0x08: case 0x0B: case 0x0F: case 0x14: case 0x17: case 0x1B: case 0x20: case 0x23:
    case 0x27: case 0x2C: case 0x2F: case 0x3E:
        return 2;
    case 0x04: case 0x09: case 0x0C: case 0x10: case 0x15: case 0x18: case 0x1C: case 0x21: case 0x24:
    case 0x28: case 0x2D: case 0x30:
        return 1;
    default: return 0;
    }
}

static MTLVertexFormat vertex_format(uint32_t f) {
    switch (f) {
    case 0x01: return MTLVertexFormatUCharNormalized;
    case 0x02: return MTLVertexFormatCharNormalized;
    case 0x03: return MTLVertexFormatUChar;
    case 0x04: return MTLVertexFormatChar;
    case 0x05: return MTLVertexFormatHalf;
    case 0x06: return MTLVertexFormatUShortNormalized;
    case 0x07: return MTLVertexFormatShortNormalized;
    case 0x08: return MTLVertexFormatUShort;
    case 0x09: return MTLVertexFormatShort;
    case 0x0A: return MTLVertexFormatFloat;
    case 0x0B: return MTLVertexFormatUInt;
    case 0x0C: return MTLVertexFormatInt;
    case 0x0D: return MTLVertexFormatUChar2Normalized;
    case 0x0E: return MTLVertexFormatChar2Normalized;
    case 0x0F: return MTLVertexFormatUChar2;
    case 0x10: return MTLVertexFormatChar2;
    case 0x11: return MTLVertexFormatHalf2;
    case 0x12: return MTLVertexFormatUShort2Normalized;
    case 0x13: return MTLVertexFormatShort2Normalized;
    case 0x14: return MTLVertexFormatUShort2;
    case 0x15: return MTLVertexFormatShort2;
    case 0x16: return MTLVertexFormatFloat2;
    case 0x17: return MTLVertexFormatUInt2;
    case 0x18: return MTLVertexFormatInt2;
    case 0x19: return MTLVertexFormatUChar3Normalized;
    case 0x1A: return MTLVertexFormatChar3Normalized;
    case 0x1B: return MTLVertexFormatUChar3;
    case 0x1C: return MTLVertexFormatChar3;
    case 0x1D: return MTLVertexFormatHalf3;
    case 0x1E: return MTLVertexFormatUShort3Normalized;
    case 0x1F: return MTLVertexFormatShort3Normalized;
    case 0x20: return MTLVertexFormatUShort3;
    case 0x21: return MTLVertexFormatShort3;
    case 0x22: return MTLVertexFormatFloat3;
    case 0x23: return MTLVertexFormatUInt3;
    case 0x24: return MTLVertexFormatInt3;
    case 0x25: return MTLVertexFormatUChar4Normalized;
    case 0x26: return MTLVertexFormatChar4Normalized;
    case 0x27: return MTLVertexFormatUChar4;
    case 0x28: return MTLVertexFormatChar4;
    case 0x29: return MTLVertexFormatHalf4;
    case 0x2A: return MTLVertexFormatUShort4Normalized;
    case 0x2B: return MTLVertexFormatShort4Normalized;
    case 0x2C: return MTLVertexFormatUShort4;
    case 0x2D: return MTLVertexFormatShort4;
    case 0x2E: return MTLVertexFormatFloat4;
    case 0x2F: return MTLVertexFormatUInt4;
    case 0x30: return MTLVertexFormatInt4;
    case 0x3D: return MTLVertexFormatUInt1010102Normalized;
    case 0x69: return MTLVertexFormatInt1010102Normalized;
    case 0x3F: return MTLVertexFormatFloatRG11B10;
    case 0x40: return MTLVertexFormatFloatRGB9E5;
    // integer-to-float ("I2F") formats: converted to float by the vertex fetch
    case 0x51: return MTLVertexFormatUChar;   // these read as raw integers converted in shader
    default:
        return MTLVertexFormatFloat4;
    }
}

static bool is_int_format(uint32_t f) { return attr_kind(f) != 0; }

static MTLBlendFactor blend_factor(uint8_t f) {
    switch (f) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 0x10: return MTLBlendFactorSource1Color;
    case 0x11: return MTLBlendFactorOneMinusSource1Color;
    case 0x12: return MTLBlendFactorSource1Alpha;
    case 0x13: return MTLBlendFactorOneMinusSource1Alpha;
    case 0x61: return MTLBlendFactorBlendColor;
    case 0x62: return MTLBlendFactorOneMinusBlendColor;
    case 0x63: return MTLBlendFactorBlendAlpha;
    case 0x64: return MTLBlendFactorOneMinusBlendAlpha;
    default: {
        static uint8_t warned[256];
        if (!warned[f]++) LOG("[metal] unknown blend factor %#x\n", f);
        return MTLBlendFactorOne;
    }
    }
}

static MTLBlendOperation blend_op(uint8_t e) {
    switch (e) {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

static MTLCompareFunction compare_fn(uint8_t f) {
    switch (f) {
    case 1: return MTLCompareFunctionNever;
    case 2: return MTLCompareFunctionLess;
    case 3: return MTLCompareFunctionEqual;
    case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater;
    case 6: return MTLCompareFunctionNotEqual;
    case 7: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}

static MTLStencilOperation stencil_op(uint8_t o) {
    switch (o) {
    case 2: return MTLStencilOperationZero;
    case 3: return MTLStencilOperationReplace;
    case 4: return MTLStencilOperationIncrementClamp;
    case 5: return MTLStencilOperationDecrementClamp;
    case 6: return MTLStencilOperationInvert;
    case 7: return MTLStencilOperationIncrementWrap;
    case 8: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}

static int rt_kind(uint32_t f) {
    switch (f) {
    case 0x03: case 0x08: case 0x0B: case 0x0F: case 0x14: case 0x17: case 0x27: case 0x2C: case 0x2F: case 0x3E: return 2;
    case 0x04: case 0x09: case 0x0C: case 0x10: case 0x15: case 0x18: case 0x28: case 0x2D: case 0x30: return 1;
    default: return 0;
    }
}

static Prog *get_program(NvnProgram *p, ShaderKey *vkey, ShaderKey *fkey) {
    if (!(p->stage_mask & 1) || !(p->stage_mask & 2)) return nil;
    NSString *key = [NSString stringWithFormat:@"%llx/%llx/%@/%@", p->stages[0].code_addr, p->stages[1].code_addr,
                     [NSData dataWithBytes:vkey length:sizeof *vkey], [NSData dataWithBytes:fkey->rt_kind length:8]];
    Prog *pr = cache[key];
    if (pr) return pr->failed ? nil : pr;
    pr = [Prog new];
    cache[key] = pr;
    dump_program(p);
    maxwell_gmem_base = HEAP_BASE;
    maxwell_gmem_size = HEAP_MAX;
    // the compiler constants follow the code, so they bound the instruction scan
    size_t vmax = p->stages[0].const_offset ? p->stages[0].const_offset : 0x10000;
    size_t fmax = p->stages[1].const_offset ? p->stages[1].const_offset : 0x10000;
    pr->vi = maxwell_translate((const uint8_t *)(uintptr_t)p->stages[0].code_addr, vmax, STAGE_VERTEX, vkey);
    if (!pr->vi->msl) {
        LOG("[shader] VS translate failed: %s (code %llx)\n", pr->vi->error, p->stages[0].code_addr);
        char path[128];
        snprintf(path, sizeof path, "build/shaders/fail_%llx_s0_code.bin", p->stages[0].code_addr);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite((void *)(uintptr_t)p->stages[0].code_addr, 1, 0x4000, f); fclose(f); }
        pr->failed = true;
        return nil;
    }
    fkey->vs_out_mask = pr->vi->out_mask;
    pr->fi = maxwell_translate((const uint8_t *)(uintptr_t)p->stages[1].code_addr, fmax, STAGE_FRAGMENT, fkey);
    if (!pr->fi->msl) { LOG("[shader] FS translate failed: %s\n", pr->fi->error); pr->failed = true; return nil; }
    if (getenv("LARECOMP_SAVE_MSL")) {
        mkdir("build/msl", 0755);
        char path[256];
        snprintf(path, sizeof path, "build/msl/%llx_vs.metal", p->stages[0].code_addr);
        FILE *f = fopen(path, "w"); fputs(pr->vi->msl, f); fclose(f);
        snprintf(path, sizeof path, "build/msl/%llx_fs.metal", p->stages[1].code_addr);
        f = fopen(path, "w"); fputs(pr->fi->msl, f); fclose(f);
    }
    NSError *err = nil;
    id<MTLLibrary> vl = [dev newLibraryWithSource:@(pr->vi->msl) options:nil error:&err];
    if (!vl) { LOG("[shader] VS compile failed: %s\n%s\n", err.localizedDescription.UTF8String, pr->vi->msl); pr->failed = true; return nil; }
    id<MTLLibrary> fl = [dev newLibraryWithSource:@(pr->fi->msl) options:nil error:&err];
    if (!fl) { LOG("[shader] FS compile failed: %s\n%s\n", err.localizedDescription.UTF8String, pr->fi->msl); pr->failed = true; return nil; }
    pr->vs = [vl newFunctionWithName:@"main0"];
    pr->fs = [fl newFunctionWithName:@"main0"];
    return pr;
}

static id<MTLSamplerState> sampler_for(NvnSamplerDesc *d) {
    if (d->backend) return (__bridge id<MTLSamplerState>)d->backend;
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.magFilter = d->mag_filter == 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    uint32_t mf = d->min_filter;
    sd.minFilter = (mf == 1 || mf == 3 || mf == 5) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.mipFilter = mf <= 1 ? MTLSamplerMipFilterNotMipmapped : (mf == 2 || mf == 3) ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    MTLSamplerAddressMode modes[3];
    for (int i = 0; i < 3; i++) {
        switch (d->wrap[i]) {
        case 0: case 7: modes[i] = MTLSamplerAddressModeClampToEdge; break;
        case 1: modes[i] = MTLSamplerAddressModeRepeat; break;
        case 2: case 3: modes[i] = MTLSamplerAddressModeMirrorClampToEdge; break;
        case 4: case 5: modes[i] = MTLSamplerAddressModeClampToBorderColor; break;
        case 6: modes[i] = MTLSamplerAddressModeMirrorRepeat; break;
        default: modes[i] = MTLSamplerAddressModeRepeat;
        }
    }
    sd.sAddressMode = modes[0]; sd.tAddressMode = modes[1]; sd.rAddressMode = modes[2];
    sd.lodMinClamp = d->lod_min;
    sd.lodMaxClamp = d->lod_max > 1000 ? FLT_MAX : d->lod_max;
    if (d->max_aniso > 1) sd.maxAnisotropy = (NSUInteger)fminf(d->max_aniso, 16);
    if (d->compare_mode) sd.compareFunction = compare_fn((uint8_t)d->compare_func);
    sd.supportArgumentBuffers = NO;
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
    d->backend = (void *)CFBridgingRetain(s);
    return s;
}

static id<MTLSamplerState> default_sampler(void) {
    static id<MTLSamplerState> s;
    if (!s) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        s = [dev newSamplerStateWithDescriptor:sd];
    }
    return s;
}

static id<MTLTexture> dummy_texture(int type) {
    static id<MTLTexture> t[10];
    if (!t[type]) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.width = d.height = 1;
        d.textureType = type == TEXTYPE_CUBE ? MTLTextureTypeCube : type == TEXTYPE_3D ? MTLTextureType3D
                      : type == TEXTYPE_2D_ARRAY ? MTLTextureType2DArray : type == TEXTYPE_1D ? MTLTextureType1D
                      : MTLTextureType2D;
        t[type] = [dev newTextureWithDescriptor:d];
    }
    return t[type];
}

static MTLTextureType mtl_type_for(int t) {
    switch (t) {
    case TEXTYPE_1D: return MTLTextureType1D;
    case TEXTYPE_3D: return MTLTextureType3D;
    case TEXTYPE_CUBE: return MTLTextureTypeCube;
    case TEXTYPE_2D_ARRAY: return MTLTextureType2DArray;
    case TEXTYPE_CUBE_ARRAY: return MTLTextureTypeCubeArray;
    case TEXTYPE_1D_ARRAY: return MTLTextureType1DArray;
    default: return MTLTextureType2D;
    }
}

// NVN texture/view component swizzle (same enum values as MTLTextureSwizzle), applied as a view.
static id<MTLTexture> apply_swizzle(id<MTLTexture> tex, NvnTexture *t, const NvnTextureView *v, bool has_view) {
    const uint8_t *sw = (has_view && (v->setmask & 8)) ? v->swizzle : t->swizzle;
    uint8_t c[4];
    for (int i = 0; i < 4; i++) c[i] = sw[i] <= 5 ? sw[i] : (uint8_t)(2 + i);
    if (!c[0] && !c[1] && !c[2] && !c[3]) return tex;  // never set: identity
    if (renderer_format_alpha_one(t->format))
        for (int i = 0; i < 4; i++) if (c[i] == MTLTextureSwizzleAlpha) c[i] = MTLTextureSwizzleOne;
    if (c[0] == 2 && c[1] == 3 && c[2] == 4 && c[3] == (renderer_format_alpha_one(t->format) ? 1 : 5)) return tex;
    if (tex.sampleCount > 1 || renderer_format_is_depth(t->format)) return tex;
    static NSMutableDictionary *views;
    if (!views) views = [NSMutableDictionary new];
    NSValue *k = [NSValue valueWithPointer:(__bridge void *)tex];
    uint32_t swz = c[0] | c[1] << 8 | c[2] << 16 | (uint32_t)c[3] << 24;
    NSMutableDictionary *per = views[k];
    if (!per) { per = [NSMutableDictionary new]; views[k] = per; }
    id<MTLTexture> view = per[@(swz)];
    if (!view) {
        NSUInteger slices = tex.textureType == MTLTextureType3D ? 1 : tex.arrayLength * (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        view = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:tex.textureType
                                           levels:NSMakeRange(0, tex.mipmapLevelCount) slices:NSMakeRange(0, slices)
                                          swizzle:MTLTextureSwizzleChannelsMake(c[0], c[1], c[2], c[3])];
        if (!view) return tex;
        per[@(swz)] = view;
    }
    return view;
}

// Upload helper: a separate command buffer, committed now so it runs before the current pass.
static id<MTLTexture> sampled_texture(NvnTexture *t, const NvnTextureView *v, bool has_view, int want_type) {
    id<MTLCommandBuffer> ucb = [renderer_queue() commandBuffer];
    id<MTLBlitCommandEncoder> blit = [ucb blitCommandEncoder];
    id<MTLTexture> tex = view_texture(t, v, has_view, false, blit);
    [blit endEncoding];
    [ucb commit];
    tex = apply_swizzle(tex, t, v, has_view);
    MTLTextureType want = mtl_type_for(want_type);
    if (tex.textureType != want && tex.textureType != MTLTextureType2DMultisample) {
        if (want == MTLTextureType2D && (tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube))
            tex = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, tex.mipmapLevelCount) slices:NSMakeRange(0, 1)];
        else if (want == MTLTextureType2DArray && tex.textureType == MTLTextureType2D)
            tex = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0, tex.mipmapLevelCount) slices:NSMakeRange(0, 1)];
        else if (want == MTLTextureTypeCube && tex.textureType == MTLTextureType2DArray && tex.arrayLength >= 6)
            tex = [tex newTextureViewWithPixelFormat:tex.pixelFormat textureType:MTLTextureTypeCube levels:NSMakeRange(0, tex.mipmapLevelCount) slices:NSMakeRange(0, 6)];
        else
            return dummy_texture(want_type);
    }
    return tex;
}

static void bind_textures(int stage, ShaderInfo *si) {
    for (int i = 0; i < si->ntex; i++) {
        ShaderTexture *st_ = &si->tex[i];
        int slot = ((int)st_->handle_offset - 0x20) / 8;  // 64-bit handles from offset 0x20
        uint64_t h = (slot >= 0 && slot < 32) ? st.tex[stage][slot] : 0;
        id<MTLTexture> tex = nil;
        id<MTLSamplerState> smp = nil;
        uint32_t tic = h & 0xFFFFF, tsc = (uint32_t)(h >> 20) & 0xFFF;
        if (h && st.tpool && tic < (uint32_t)st.tpool->count) {
            NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
            if (e->tex) tex = sampled_texture(e->tex, &e->view, e->has_view, st_->type);
            if (g_debug_frame && e->tex && e->tex->addr) {
                uint64_t total = tegra_total_size(&e->tex->layout), nz = 0;
                const uint8_t *p = (const uint8_t *)(uintptr_t)e->tex->addr;
                for (uint64_t k = 0; k < total; k++) nz += p[k] != 0;
                LOG("[dtex] slot %d tex %ux%u f%#x addr %llx size %llu nonzero %llu gpu_owned %d\n", i, e->tex->width,
                    e->tex->height, e->tex->format, e->tex->addr, total, nz, renderer_is_gpu_owned(e->tex));
            }
        }
        if (h && st.spool && tsc < (uint32_t)st.spool->count) smp = sampler_for(&((NvnSamplerDesc *)st.spool->entries)[tsc]);
        if (!tex) tex = dummy_texture(st_->type);
        if (!smp) smp = default_sampler();
        if (g_debug_frame && tex.textureType == MTLTextureType2D && stage == 1) {
            static int dn;
            char path[128];
            snprintf(path, sizeof path, "build/dtex_%03d_%d.png", dn++, i);
            renderer_save_texture(tex, path);
            snprintf(path, sizeof path, "build/dtex_%03d_%d_a.png", dn - 1, i);
            renderer_save_texture_alpha(tex, path);
        }
        if (stage == 0) { [enc setVertexTexture:tex atIndex:i]; [enc setVertexSamplerState:smp atIndex:i]; }
        else { [enc setFragmentTexture:tex atIndex:i]; [enc setFragmentSamplerState:smp atIndex:i]; }
    }
}

static void bind_cbufs(int stage, ShaderInfo *si) {
    for (int k = 0; k < 18; k++) {
        if (!(si->cbuf_mask & (1u << k))) continue;
        if (k == 0) {  // driver constants: storage buffer bindings at 0x110 + 16*i {addr_lo, addr_hi, size, 0}
            uint32_t drv[0x400 / 4] = {0};
            for (int i = 0; i < 16; i++) {
                uint32_t *e = &drv[(0x110 + 16 * i) / 4];
                e[0] = (uint32_t)st.sbuf[stage][i].addr;
                e[1] = (uint32_t)(st.sbuf[stage][i].addr >> 32);
                e[2] = (uint32_t)st.sbuf[stage][i].size;
            }
            uint64_t size = si->cbuf_size[0] > sizeof drv ? sizeof drv : (si->cbuf_size[0] ? si->cbuf_size[0] : 256);
            uint64_t off = ring_alloc(drv, size);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:0];
            else [enc setFragmentBuffer:ring offset:off atIndex:0];
            continue;
        }
        if (k == 1) {  // compiler constants stored after the shader code
            NvnShaderStage *ss = &st.program->stages[stage];
            uint64_t size = ss->const_size ? ss->const_size : 16;
            if (size < si->cbuf_size[1]) size = si->cbuf_size[1];
            uint64_t off = ring_alloc((void *)(uintptr_t)(ss->code_addr + ss->const_offset), size);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:1];
            else [enc setFragmentBuffer:ring offset:off atIndex:1];
            continue;
        }
        int idx = k - cbuf_base;
        Range r = (idx >= 0 && idx < 18) ? st.ubuf[stage][idx] : (Range){0, 0};
        uint64_t size = si->cbuf_size[k];
        if (!r.addr) {
            static const uint8_t zeros[0x10000];
            uint64_t off = ring_alloc(zeros, size ? size : 256);
            if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:k];
            else [enc setFragmentBuffer:ring offset:off atIndex:k];
            continue;
        }
        if (size > r.size && r.size) size = r.size;
        if (size < 16) size = 16;
        uint64_t off = ring_alloc((void *)(uintptr_t)r.addr, size);  // snapshot, as later CPU writes must not leak in
        if (stage == 0) [enc setVertexBuffer:ring offset:off atIndex:k];
        else [enc setFragmentBuffer:ring offset:off atIndex:k];
    }
}


// ------------------------------------------------------------------ compute
// Compute driver constants (c0): 0x200 work group counts, 0x210 + 16*i uniform buffers (compute has
// few hardware cbuf slots, so the compiler reads the rest through global memory), 0x310 + 16*i
// storage buffers; each table entry is {addr_lo, addr_hi, size, 0}.
typedef struct { id<MTLComputePipelineState> pipe; ShaderInfo *si; uint32_t local[3]; bool failed; } CsProg;

static CsProg *compute_program(NvnProgram *p) {
    NvnShaderStage *ss = &p->stages[5];
    if (!ss->code_addr) return NULL;
    NSValue *key = [NSValue valueWithPointer:(void *)(uintptr_t)ss->code_addr];
    static NSMutableDictionary *progs;
    if (!progs) progs = [NSMutableDictionary new];
    NSValue *v = progs[key];
    if (v) { CsProg *cp = v.pointerValue; return cp->failed ? NULL : cp; }
    CsProg *cp = calloc(1, sizeof *cp);
    progs[key] = [NSValue valueWithPointer:cp];
    maxwell_gmem_base = HEAP_BASE;
    maxwell_gmem_size = HEAP_MAX;
    ShaderKey k = {0};
    cp->si = maxwell_translate((const uint8_t *)(uintptr_t)ss->code_addr, ss->const_offset ? ss->const_offset : 0x10000, STAGE_COMPUTE, &k);
    if (!cp->si->msl) { LOG("[compute] translate failed: %s (code %llx)\n", cp->si->error, ss->code_addr); cp->failed = true; return NULL; }
    for (int i = 0; i < 3; i++) {
        cp->local[i] = ss->control ? *(const uint32_t *)(ss->control + 0x748 + 4 * i) : 1;
        if (!cp->local[i]) cp->local[i] = 1;
    }
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(cp->si->msl) options:nil error:&err];
    id<MTLFunction> f = lib ? [lib newFunctionWithName:@"main0"] : nil;
    cp->pipe = f ? [dev newComputePipelineStateWithFunction:f error:&err] : nil;
    if (!cp->pipe) {
        LOG("[compute] compile failed: %s\n%s\n", err.localizedDescription.UTF8String, cp->si->msl);
        cp->failed = true;
        return NULL;
    }
    LOG("[compute] program %llx: local size %ux%ux%u, %d cbufs mask %#x\n", ss->code_addr, cp->local[0], cp->local[1],
        cp->local[2], 0, cp->si->cbuf_mask);
    return cp;
}

static void dispatch_compute(uint32_t gx, uint32_t gy, uint32_t gz) {
    if (!st.program || !gx || !gy || !gz) return;
    CsProg *cp = compute_program(st.program);
    if (!cp) return;
    static int trace = -1;
    if (trace < 0) trace = getenv("LARECOMP_TRACE_CS") != NULL;
#define CST(x) do { if (trace) { fprintf(stderr, "[cs] %s\n", x); fflush(stderr); } } while (0)
    CST("end_pass");
    end_pass();
    CST("encoder");
    id<MTLComputeCommandEncoder> ce = [cb() computeCommandEncoder];
    CST("pipeline");
    [ce setComputePipelineState:cp->pipe];
    ShaderInfo *si = cp->si;
    for (int k = 0; k < 18; k++) {
        if (!(si->cbuf_mask & (1u << k))) continue;
        uint64_t off;
        if (k == 0) {
            uint32_t drv[0x500 / 4] = {0};  // tables end at 0x310 + 16 * 16
            drv[0x200 / 4] = gx; drv[0x204 / 4] = gy; drv[0x208 / 4] = gz;
            for (int i = 0; i < 16; i++) {
                uint32_t *u = &drv[(0x210 + 16 * i) / 4];
                if (i < 18) { u[0] = (uint32_t)st.ubuf[5][i].addr; u[1] = (uint32_t)(st.ubuf[5][i].addr >> 32); u[2] = (uint32_t)st.ubuf[5][i].size; }
                uint32_t *e = &drv[(0x310 + 16 * i) / 4];
                e[0] = (uint32_t)st.sbuf[5][i].addr; e[1] = (uint32_t)(st.sbuf[5][i].addr >> 32); e[2] = (uint32_t)st.sbuf[5][i].size;
            }
            off = ring_alloc(drv, sizeof drv);
        } else if (k == 1) {
            NvnShaderStage *ss = &st.program->stages[5];
            uint64_t size = ss->const_size ? ss->const_size : 16;
            if (size < si->cbuf_size[1]) size = si->cbuf_size[1];
            off = ring_alloc((void *)(uintptr_t)(ss->code_addr + ss->const_offset), size);
        } else {
            int idx = k - cbuf_base;
            Range r = (idx >= 0 && idx < 18) ? st.ubuf[5][idx] : (Range){0, 0};
            uint64_t size = si->cbuf_size[k] ? si->cbuf_size[k] : 256;
            if (r.addr) {
                if (size > r.size && r.size) size = r.size;
                if (size < 16) size = 16;
                off = ring_alloc((void *)(uintptr_t)r.addr, size);
            } else {
                static const uint8_t zeros[0x10000];
                off = ring_alloc(zeros, size);
            }
        }
        [ce setBuffer:ring offset:off atIndex:k];
    }
    CST("gmem");
    if (si->uses_gmem) [ce setBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    CST("textures");
    for (int i = 0; i < si->ntex; i++) {
        ShaderTexture *st_ = &si->tex[i];
        int slot = ((int)st_->handle_offset - 0x20) / 8;
        uint64_t h = (slot >= 0 && slot < 32) ? st.tex[5][slot] : 0;
        id<MTLTexture> tex = nil;
        id<MTLSamplerState> smp = nil;
        uint32_t tic = h & 0xFFFFF, tsc = (uint32_t)(h >> 20) & 0xFFF;
        if (h && st.tpool && tic < (uint32_t)st.tpool->count) {
            NvnTexEntry *e = &((NvnTexEntry *)st.tpool->entries)[tic];
            if (e->tex) tex = sampled_texture(e->tex, &e->view, e->has_view, st_->type);
        }
        if (h && st.spool && tsc < (uint32_t)st.spool->count) smp = sampler_for(&((NvnSamplerDesc *)st.spool->entries)[tsc]);
        [ce setTexture:tex ? tex : dummy_texture(st_->type) atIndex:i];
        [ce setSamplerState:smp ? smp : default_sampler() atIndex:i];
    }
    CST("dispatch");
    [ce dispatchThreadgroups:MTLSizeMake(gx, gy, gz) threadsPerThreadgroup:MTLSizeMake(cp->local[0], cp->local[1], cp->local[2])];
    [ce endEncoding];
    CST("done");
    stat_dispatches++;
}

static MTLPrimitiveType prim_type(uint32_t mode, bool *ok) {
    *ok = true;
    switch (mode) {
    case 0: return MTLPrimitiveTypePoint;
    case 1: return MTLPrimitiveTypeLine;
    case 3: return MTLPrimitiveTypeLineStrip;
    case 4: return MTLPrimitiveTypeTriangle;
    case 5: return MTLPrimitiveTypeTriangleStrip;
    default: *ok = false; return MTLPrimitiveTypeTriangle;
    }
}

// Expand quads/fans/polygons into a triangle index list (32-bit) referencing the original vertices.
static id<MTLBuffer> expand_indices(uint32_t mode, uint32_t count, const void *indices, int itype, uint32_t first,
                                    uint32_t *out_count) {
    uint32_t tris = mode == 7 ? count / 4 * 2 : count >= 3 ? count - 2 : 0;
    uint32_t *out = malloc(tris * 3 * 4 + 4);
    uint32_t n = 0;
#define IDX(i) (indices ? (itype == 0 ? ((const uint8_t *)indices)[i] : itype == 1 ? ((const uint16_t *)indices)[i] : ((const uint32_t *)indices)[i]) : first + (i))
    if (mode == 7) {  // quads
        for (uint32_t q = 0; q + 3 < count; q += 4) {
            out[n++] = IDX(q); out[n++] = IDX(q + 1); out[n++] = IDX(q + 2);
            out[n++] = IDX(q); out[n++] = IDX(q + 2); out[n++] = IDX(q + 3);
        }
    } else {  // fan / polygon
        for (uint32_t i = 1; i + 1 < count; i++) { out[n++] = IDX(0); out[n++] = IDX(i); out[n++] = IDX(i + 1); }
    }
#undef IDX
    *out_count = n;
    id<MTLBuffer> b = [dev newBufferWithBytes:out length:n * 4 + 4 options:MTLResourceStorageModeShared];
    free(out);
    return b;
}

static void debug_draw(Prog *pr, CmdRec *r, bool indexed) {
    LOG("[draw] %s mode %llu count %llu prog vs=%llx fs=%llx | vs cb %#x fs cb %#x | ubufs:",
        indexed ? "elems" : "arrays", r->x[0], r->x[2], st.program->stages[0].code_addr, st.program->stages[1].code_addr,
        pr->vi->cbuf_mask, pr->fi->cbuf_mask);
    for (int s = 0; s < 2; s++)
        for (int i = 0; i < 18; i++)
            if (st.ubuf[s][i].addr) LOG(" %c%d(%llx,%llu)", s ? 'f' : 'v', i, st.ubuf[s][i].addr, st.ubuf[s][i].size);
    LOG(" | tex:");
    for (int i = 0; i < pr->fi->ntex; i++) LOG(" off%u", pr->fi->tex[i].handle_offset);
    LOG(" bound:");
    for (int i = 0; i < 32; i++) {
        if (!st.tex[1][i]) continue;
        uint32_t tic = st.tex[1][i] & 0xFFFFF;
        NvnTexture *t = st.tpool && tic < (uint32_t)st.tpool->count ? ((NvnTexEntry *)st.tpool->entries)[tic].tex : NULL;
        if (t) LOG(" %d=[%ux%u f%#x fl%#x %s]", i, t->width, t->height, t->format, t->flags, t->label);
        else LOG(" %d=%llx", i, st.tex[1][i]);
    }
    LOG(" | rt %d", st.rt.ncolor);
    for (int i = 0; i < st.rt.ncolor; i++) if (st.rt.color[i]) LOG(" %ux%u/f%#x", st.rt.color[i]->width, st.rt.color[i]->height, st.rt.color[i]->format);
    if (st.rt.depth) LOG(" d%#x", st.rt.depth->format);
    LOG(" | vp %.0f %.0f %.0f %.0f | attrs %#x streams:", st.viewport[0][0], st.viewport[0][1], st.viewport[0][2], st.viewport[0][3], pr->vi->attr_mask);
    for (int i = 0; i < st.nattrib; i++) LOG(" a%d(f%#x s%u o%u)", i, st.attrib[i] & 0xFF, (st.attrib[i] >> 8) & 0x1F, st.attrib[i] >> 13);
    for (int i = 0; i < 4; i++) if (st.vbuf[i].addr) LOG(" vb%d(%llx,%llu,stride %u)", i, st.vbuf[i].addr, st.vbuf[i].size, st.stream[i][0]);
    if (st.ubuf[0][0].addr && st.ubuf[0][0].size == 560) {
        const float *f = (const float *)(uintptr_t)st.ubuf[0][0].addr;
        LOG("\n  vs ubo0:");
        for (int i = 0; i < 36; i++) LOG("%s[%d] %g %g %g %g", i % 2 ? " " : "\n   ", i, f[i*4], f[i*4+1], f[i*4+2], f[i*4+3]);
    }
    LOG(" blend %#x ds %02x%02x%02x poly %02x%02x\n", st.color_state[0], st.ds[0], st.ds[1], st.ds[2], st.poly[0], st.poly[1]);
}

static void draw(CmdRec *r, bool indexed) {
    if (!st.program) { stat_skipped++; return; }
    static bool logged_modes;
    if (!logged_modes) {
        logged_modes = true;
        const char *cb = getenv("LARECOMP_CBUF_BASE"), *tb = getenv("LARECOMP_TEX_BASE");
        if (cb) cbuf_base = atoi(cb);
        if (tb) tex_base = atoi(tb);
    }
    ShaderKey vkey = {0}, fkey = {0};
    vkey.flip_y = fkey.flip_y = nvn_window_origin() == 0;
    vkey.depth_minus_one = nvn_depth_mode() == 0;
    for (int i = 0; i < st.nattrib; i++) vkey.attr_kind[i] = (uint8_t)attr_kind(st.attrib[i] & 0xFF);
    for (int i = 0; i < st.rt.ncolor; i++) if (st.rt.color[i]) fkey.rt_kind[i] = (uint8_t)rt_kind(st.rt.color[i]->format);
    Prog *pr = get_program(st.program, &vkey, &fkey);
    if (!pr) { stat_skipped++; return; }
    static int log_rt_w = -1, log_rt_h;
    if (log_rt_w < 0) { const char *e = getenv("LARECOMP_LOG_RT"); log_rt_w = 0; if (e) sscanf(e, "%dx%d", &log_rt_w, &log_rt_h); }
    static uint64_t log_rt_addr = 1;
    if (log_rt_addr == 1) { const char *e = getenv("LARECOMP_LOG_RT_ADDR"); log_rt_addr = e ? strtoull(e, NULL, 16) : 0; }
    bool addr_hit = false;
    for (int i = 0; log_rt_addr && i < st.rt.ncolor; i++)
        if (st.rt.color[i] && st.rt.color[i]->addr <= log_rt_addr + 0x40000 && st.rt.color[i]->addr + 0x40000 >= log_rt_addr) addr_hit = true;
    if (addr_hit) LOG("[rtaddr] rt0 addr %llx\n", st.rt.color[0] ? st.rt.color[0]->addr : 0);
    if (g_debug_frame || addr_hit || (log_rt_w && st.rt.ncolor && st.rt.color[0] && (int)st.rt.color[0]->width == log_rt_w &&
                          (int)st.rt.color[0]->height == log_rt_h))
        debug_draw(pr, r, indexed);
    begin_pass();

    // pipeline
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = pr->vs;
    pd.fragmentFunction = pr->fs;
    attachment_formats(pd);
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    uint32_t used_streams = 0;
    for (int i = 0; i < 32; i++) {
        if (!(pr->vi->attr_mask & (1u << i))) continue;
        uint32_t a = i < st.nattrib ? st.attrib[i] : 0x2E;
        uint32_t fmt = a & 0xFF, stream = (a >> 8) & 0x1F, off = a >> 13;
        if (i >= st.nattrib || fmt == 0) {
            // unbound attribute: read zeros from a constant stream
            vd.attributes[i].format = MTLVertexFormatFloat4;
            vd.attributes[i].offset = 0;
            vd.attributes[i].bufferIndex = 30;
            vd.layouts[30].stepFunction = MTLVertexStepFunctionConstant;
            vd.layouts[30].stepRate = 0;
            vd.layouts[30].stride = 16;
            used_streams |= 1u << 31;
            continue;
        }
        vd.attributes[i].format = vertex_format(fmt);
        vd.attributes[i].offset = off;
        vd.attributes[i].bufferIndex = 18 + stream;
        used_streams |= 1u << stream;
        (void)is_int_format;
    }
    for (int s = 0; s < 12; s++) {
        if (!(used_streams & (1u << s))) continue;
        uint32_t stride = s < st.nstream ? st.stream[s][0] : 0, div = s < st.nstream ? st.stream[s][1] : 0;
        if (stride == 0) { vd.layouts[18 + s].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[18 + s].stepRate = 0; vd.layouts[18 + s].stride = 16; }
        else {
            vd.layouts[18 + s].stride = (stride + 3) & ~3u;
            if (div) { vd.layouts[18 + s].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[18 + s].stepRate = div; }
        }
    }
    pd.vertexDescriptor = vd;
    for (int i = 0; i < st.rt.ncolor && i < 8; i++) {
        if (!st.rt.color[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
        uint32_t m = (st.channel_mask >> (i * 4)) & 0xF;
        ca.writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) |
                       (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        bool blend_on = (st.color_state[0] >> i) & 1;
        if (blend_on && !rt_kind(st.rt.color[i]->format)) {
            uint8_t *b = st.blend[i];
            ca.blendingEnabled = YES;
            ca.sourceRGBBlendFactor = blend_factor(b[1]);
            ca.destinationRGBBlendFactor = blend_factor(b[2]);
            ca.sourceAlphaBlendFactor = blend_factor(b[3]);
            ca.destinationAlphaBlendFactor = blend_factor(b[4]);
            ca.rgbBlendOperation = blend_op(b[5]);
            ca.alphaBlendOperation = blend_op(b[6]);
        }
    }
    pd.alphaToCoverageEnabled = st.ms[0xC] != 0;
    NSMutableString *pk = [NSMutableString stringWithFormat:@"%p %p %lu %lu", pr->vs, pr->fs,
                           (unsigned long)pd.depthAttachmentPixelFormat, (unsigned long)pd.stencilAttachmentPixelFormat];
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
        [pk appendFormat:@" %lu/%lu/%d/%lu/%lu/%lu/%lu/%lu/%lu", (unsigned long)ca.pixelFormat, (unsigned long)ca.writeMask,
                         ca.blendingEnabled, (unsigned long)ca.sourceRGBBlendFactor, (unsigned long)ca.destinationRGBBlendFactor,
                         (unsigned long)ca.sourceAlphaBlendFactor, (unsigned long)ca.destinationAlphaBlendFactor,
                         (unsigned long)ca.rgbBlendOperation, (unsigned long)ca.alphaBlendOperation];
    }
    for (int i = 0; i < 32; i++)
        if (pr->vi->attr_mask & (1u << i))
            [pk appendFormat:@" a%d:%lu/%lu/%lu", i, (unsigned long)vd.attributes[i].format, (unsigned long)vd.attributes[i].offset, (unsigned long)vd.attributes[i].bufferIndex];
    for (int s = 18; s < 31; s++)
        [pk appendFormat:@" l%lu/%lu/%lu", (unsigned long)vd.layouts[s].stride, (unsigned long)vd.layouts[s].stepFunction, (unsigned long)vd.layouts[s].stepRate];
    [pk appendFormat:@" s%lu a%d", (unsigned long)pd.rasterSampleCount, pd.alphaToCoverageEnabled];
    id<MTLRenderPipelineState> pipe = cache[pk];
    if (!pipe) {
        NSError *err;
        pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pipe) {
            static int n;
            if (n++ < 10) LOG("[metal] pipeline failed: %s\n", err.localizedDescription.UTF8String);
            stat_skipped++;
            return;
        }
        cache[pk] = pipe;
    }
    [enc setRenderPipelineState:pipe];

    // depth / stencil
    NSString *dk = [NSString stringWithFormat:@"ds %02x%02x%02x%02x%02x%02x%02x%02x %x %x", st.ds[0], st.ds[1], st.ds[2], st.ds[3],
                    st.ds[4], st.ds[5], st.ds[6], st.ds[7], st.stencil_mask[0], st.stencil_vmask[0]];
    id<MTLDepthStencilState> dss = cache[dk];
    if (!dss) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        if (st.ds[0]) { dd.depthCompareFunction = compare_fn(st.ds[2]); dd.depthWriteEnabled = st.ds[1] != 0; }
        else { dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = NO; }
        if (st.ds[3]) {
            uint32_t ops = st.ds[5] | st.ds[6] << 8 | st.ds[7] << 16;
            for (int f = 0; f < 2; f++) {
                MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
                sd.stencilCompareFunction = compare_fn(f ? st.ds[4] >> 4 : st.ds[4] & 0xF);
                uint32_t o = f ? ops >> 12 : ops;
                sd.stencilFailureOperation = stencil_op(o & 0xF);
                sd.depthFailureOperation = stencil_op((o >> 4) & 0xF);
                sd.depthStencilPassOperation = stencil_op((o >> 8) & 0xF);
                sd.readMask = st.stencil_vmask[f] ? st.stencil_vmask[f] : 0xFF;
                sd.writeMask = st.stencil_mask[f] ? st.stencil_mask[f] : 0xFF;
                if (f) dd.backFaceStencil = sd; else dd.frontFaceStencil = sd;
            }
        }
        dss = [dev newDepthStencilStateWithDescriptor:dd];
        cache[dk] = dss;
    }
    [enc setDepthStencilState:dss];
    [enc setStencilFrontReferenceValue:st.stencil_ref[0] backReferenceValue:st.stencil_ref[1]];
    [enc setBlendColorRed:st.blend_color[0] green:st.blend_color[1] blue:st.blend_color[2] alpha:st.blend_color[3]];

    // rasterizer
    uint8_t cull = st.poly[0];
    [enc setCullMode:cull == 1 ? MTLCullModeFront : cull == 2 ? MTLCullModeBack : MTLCullModeNone];
    bool ccw = st.poly[1] == 1;
    [enc setFrontFacingWinding:(ccw != vkey.flip_y) ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [enc setTriangleFillMode:st.poly[2] == 1 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    float *vp = st.viewport[0];
    float zn = st.depth_range[0][0], zf = st.depth_range[0][1];
    [enc setViewport:(MTLViewport){vp[0], vp[1], vp[2], vp[3], zn, zf}];
    apply_scissor();

    // resources
    bind_cbufs(0, pr->vi);
    bind_cbufs(1, pr->fi);
    if (pr->vi->uses_gmem) [enc setVertexBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    if (pr->fi->uses_gmem) [enc setFragmentBuffer:g_guest_buffer offset:0 atIndex:GMEM_BUFFER_INDEX];
    bind_textures(0, pr->vi);
    bind_textures(1, pr->fi);
    for (int s = 0; s < 12; s++) {
        if (!(used_streams & (1u << s))) continue;
        Range v = st.vbuf[s];
        if (v.addr) bind_guest(enc, true, v.addr, v.size ? v.size : 16, 18 + s);
        else { static const float zero[4]; [enc setVertexBytes:zero length:16 atIndex:18 + s]; }
    }
    if (used_streams & (1u << 31)) { static const float zero[4] = {0, 0, 0, 1}; [enc setVertexBytes:zero length:16 atIndex:30]; }

    // draw
    bool native;
    uint32_t mode = (uint32_t)r->x[0];
    MTLPrimitiveType pt = prim_type(mode, &native);
    if (!indexed) {
        uint32_t first = (uint32_t)r->x[1], count = (uint32_t)r->x[2], base_inst = (uint32_t)r->x[3], inst = (uint32_t)r->x[4];
        if (!inst) inst = 1;
        if (native) {
            [enc drawPrimitives:pt vertexStart:first vertexCount:count instanceCount:inst baseInstance:base_inst];
        } else if (mode == 6 || mode == 7 || mode == 9) {
            uint32_t n;
            id<MTLBuffer> ib = expand_indices(mode, count, NULL, 0, first, &n);
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib
                     indexBufferOffset:0 instanceCount:inst baseVertex:0 baseInstance:base_inst];
        } else { stat_skipped++; return; }
    } else {
        uint32_t itype = (uint32_t)r->x[1], count = (uint32_t)r->x[2];
        uint64_t iaddr = r->x[3];
        int32_t base_vertex = (int32_t)r->x[4];
        uint32_t base_inst = (uint32_t)r->x[5], inst = (uint32_t)r->x[6] ? (uint32_t)r->x[6] : 1;
        if (native && itype != 0) {
            MTLIndexType it = itype == 1 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
            uint32_t isz = itype == 1 ? 2 : 4;
            id<MTLBuffer> ib;
            uint64_t ioff;
            if (iaddr >= HEAP_BASE && iaddr + (uint64_t)count * isz <= HEAP_BASE + HEAP_MAX && (iaddr % isz) == 0) {
                ib = g_guest_buffer; ioff = iaddr - HEAP_BASE;
            } else {
                ioff = ring_alloc((void *)(uintptr_t)iaddr, (uint64_t)count * isz); ib = ring;
            }
            [enc drawIndexedPrimitives:pt indexCount:count indexType:it indexBuffer:ib indexBufferOffset:ioff
                         instanceCount:inst baseVertex:base_vertex baseInstance:base_inst];
        } else {
            uint32_t n;
            id<MTLBuffer> ib;
            if (native) {  // 8-bit indices: widen
                uint32_t *w = malloc(count * 4 + 4);
                for (uint32_t i = 0; i < count; i++) w[i] = ((const uint8_t *)(uintptr_t)iaddr)[i];
                ib = [dev newBufferWithBytes:w length:count * 4 + 4 options:MTLResourceStorageModeShared];
                free(w);
                n = count;
            } else {
                ib = expand_indices(mode, count, (const void *)(uintptr_t)iaddr, (int)itype, 0, &n);
                pt = MTLPrimitiveTypeTriangle;
            }
            [enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0
                         instanceCount:inst baseVertex:base_vertex baseInstance:base_inst];
        }
    }
    stat_draws++;
}

// ------------------------------------------------------------------ texture copies
typedef struct { uint64_t tex; NvnTextureView view; uint8_t has_view; int32_t region[6]; } TexRefRec;

static const char *copy_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V vs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);\n"
    "  o.uv = r.xy + p * r.zw; return o; }\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, in.uv); }\n";

// Bytes per block of the Metal texture backing an NVN format (RGB8 is expanded to RGBA8 on the host).
static uint64_t renderer_pixel_format_bytes(MTLPixelFormat pf, uint64_t nvn_bpb) {
    (void)pf;
    return nvn_bpb == 3 ? 4 : nvn_bpb;
}

// Linear guest memory <-> texture region. Row/image strides of 0 mean tightly packed.
static void copy_region_dims(NvnTexture *t, const TexRefRec *ref, const FormatInfo **fi, int32_t rg[6], int *level,
                             uint64_t *row, uint64_t *img) {
    *fi = nvn_format_info(t->format);
    memcpy(rg, ref->region, sizeof ref->region);
    if (!rg[3]) rg[3] = (int32_t)t->width;
    if (!rg[4]) rg[4] = (int32_t)t->height;
    if (!rg[5]) rg[5] = 1;
    *level = ref->has_view && (ref->view.setmask & 1) ? ref->view.base_level : 0;
    uint32_t wb = ((uint32_t)rg[3] + (*fi)->bw - 1) / (*fi)->bw, hb = ((uint32_t)rg[4] + (*fi)->bh - 1) / (*fi)->bh;
    *row = st.copy_row_stride ? st.copy_row_stride : (uint64_t)wb * (*fi)->bpb;
    *img = st.copy_image_stride ? st.copy_image_stride : *row * hb;
}

static void copy_buffer_to_texture(uint64_t src, const TexRefRec *dst) {
    NvnTexture *t = (NvnTexture *)(uintptr_t)dst->tex;
    if (!t || !src) return;
    end_pass();
    const FormatInfo *fi;
    int32_t rg[6];
    int level;
    uint64_t row, img;
    copy_region_dims(t, dst, &fi, rg, &level, &row, &img);
    if (!fi || !fi->bpb) return;
    static int nlog;
    if (nlog++ < 20) LOG("[copy] buf %llx -> tex %ux%u f%#x region %d,%d,%d %dx%dx%d row %llu lvl %d\n", src, t->width, t->height, t->format, rg[0], rg[1], rg[2], rg[3], rg[4], rg[5], row, level);
    id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
    id<MTLTexture> tex = renderer_texture(t, b, false);  // make sure prior CPU contents are uploaded first
    renderer_mark_gpu_owned(t);
    bool array = tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube;
    uint32_t hb = ((uint32_t)rg[4] + fi->bh - 1) / fi->bh, wb = ((uint32_t)rg[3] + fi->bw - 1) / fi->bw;
    uint64_t mtl_bpb = renderer_pixel_format_bytes(tex.pixelFormat, fi->bpb);
    for (int z = 0; z < (array ? rg[5] : 1); z++) {
        const uint8_t *s = (const uint8_t *)(uintptr_t)(src + (uint64_t)z * img);
        uint64_t out_row = (uint64_t)wb * mtl_bpb;
        uint8_t *data = malloc(out_row * hb * (array ? 1 : rg[5]));
        for (int d = 0; d < (array ? 1 : rg[5]); d++)
            for (uint32_t y = 0; y < hb; y++) {
                const uint8_t *sr = s + (uint64_t)d * img + (uint64_t)y * row;
                uint8_t *dr = data + ((uint64_t)d * hb + y) * out_row;
                if (mtl_bpb == fi->bpb) memcpy(dr, sr, out_row);
                else if (fi->bpb == 3 && mtl_bpb == 4)
                    for (uint32_t x = 0; x < wb; x++) { memcpy(dr + x * 4, sr + x * 3, 3); dr[x * 4 + 3] = 255; }
                else memset(dr, 0, out_row);
            }
        id<MTLBuffer> staging = [dev newBufferWithBytes:data length:out_row * hb * (array ? 1 : rg[5])
                                                options:MTLResourceStorageModeShared];
        free(data);
        [b copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:out_row sourceBytesPerImage:out_row * hb
               sourceSize:MTLSizeMake(rg[3], rg[4], array ? 1 : rg[5]) toTexture:tex
         destinationSlice:array ? rg[2] + z : 0 destinationLevel:level
        destinationOrigin:MTLOriginMake(rg[0], rg[1], array ? 0 : rg[2])];
    }
    [b endEncoding];
}

static void copy_texture_to_buffer(const TexRefRec *src, uint64_t dst) {
    NvnTexture *t = (NvnTexture *)(uintptr_t)src->tex;
    if (!t || !dst || dst < HEAP_BASE) return;
    end_pass();
    const FormatInfo *fi;
    int32_t rg[6];
    int level;
    uint64_t row, img;
    copy_region_dims(t, src, &fi, rg, &level, &row, &img);
    if (!fi || !fi->bpb) return;
    id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
    id<MTLTexture> tex = renderer_texture(t, b, false);
    if (renderer_pixel_format_bytes(tex.pixelFormat, fi->bpb) != fi->bpb) { [b endEncoding]; return; }
    bool array = tex.textureType == MTLTextureType2DArray || tex.textureType == MTLTextureTypeCube;
    for (int z = 0; z < (array ? rg[5] : 1); z++)
        [b copyFromTexture:tex sourceSlice:array ? rg[2] + z : 0 sourceLevel:level
              sourceOrigin:MTLOriginMake(rg[0], rg[1], array ? 0 : rg[2])
                sourceSize:MTLSizeMake(rg[3], rg[4], array ? 1 : rg[5]) toBuffer:g_guest_buffer
         destinationOffset:dst - HEAP_BASE + (uint64_t)z * img destinationBytesPerRow:row destinationBytesPerImage:img];
    [b endEncoding];
    renderer_flush();  // the CPU may read the result right after the fence
}

static void copy_texture(const TexRefRec *src, const TexRefRec *dst, uint64_t flags) {
    NvnTexture *st_ = (NvnTexture *)(uintptr_t)src->tex, *dt = (NvnTexture *)(uintptr_t)dst->tex;
    if (!st_ || !dt) return;
    end_pass();
    id<MTLTexture> s = sampled_texture(st_, &src->view, src->has_view, TEXTYPE_2D);
    renderer_mark_gpu_owned(dt);
    id<MTLTexture> d = view_texture(dt, &dst->view, dst->has_view, true, nil);
    const int32_t *sr = src->region, *dr = dst->region;
    if (g_debug_frame || (dt->width == 720 && dt->height == 41)) {
        static int nl;
        uint64_t total = tegra_total_size(&st_->layout), nz = 0;
        for (uint64_t k = 0; k < total && st_->addr; k++) nz += ((const uint8_t *)(uintptr_t)st_->addr)[k] != 0;
        if (nl < 40) LOG("[copytex] src addr %llx size %llu nonzero %llu tflags %#x stride %u bh %u\n", st_->addr, total, nz, st_->flags, st_->stride, st_->layout.block_height_log2);
        if (nl++ < 40) LOG("[copytex] %ux%u f%#x (%d,%d %dx%d) -> %ux%u f%#x (%d,%d %dx%d) flags %llx src_gpu %d\n", st_->width, st_->height, st_->format,
            sr[0], sr[1], sr[3], sr[4], dt->width, dt->height, dt->format, dr[0], dr[1], dr[3], dr[4], flags, renderer_is_gpu_owned(st_));
    }
    int sw = sr[3] ? sr[3] : (int)s.width, sh = sr[4] ? sr[4] : (int)s.height;
    int dw = dr[3] ? dr[3] : (int)d.width, dh = dr[4] ? dr[4] : (int)d.height;
    if (renderer_format_is_depth(dt->format) || (s.pixelFormat == d.pixelFormat && sw == dw && sh == dh && s.sampleCount == d.sampleCount)) {
        id<MTLBlitCommandEncoder> b = [cb() blitCommandEncoder];
        [b copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sr[0], sr[1], 0)
                sourceSize:MTLSizeMake(MIN(sw, dw), MIN(sh, dh), 1) toTexture:d destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(dr[0], dr[1], 0)];
        [b endEncoding];
        return;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb() renderCommandEncoderWithDescriptor:rp];
    NSString *key = [NSString stringWithFormat:@"copy %lu", (unsigned long)d.pixelFormat];
    id<MTLRenderPipelineState> pipe = cache[key];
    if (!pipe) {
        static id<MTLLibrary> lib;
        if (!lib) lib = [dev newLibraryWithSource:@(copy_src) options:nil error:nil];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = d.pixelFormat;
        pipe = [dev newRenderPipelineStateWithDescriptor:pd error:nil];
        cache[key] = pipe;
    }
    static id<MTLSamplerState> lin, near;
    if (!lin) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        near = [dev newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        lin = [dev newSamplerStateWithDescriptor:sd];
    }
    float r[4] = {(float)sr[0] / s.width, (float)sr[1] / s.height, (float)sw / s.width, (float)sh / s.height};
    [e setRenderPipelineState:pipe];
    [e setViewport:(MTLViewport){dr[0], dr[1], dw, dh, 0, 1}];
    [e setVertexBytes:r length:16 atIndex:0];
    [e setFragmentTexture:s atIndex:0];
    [e setFragmentSamplerState:(flags & 1) ? lin : near atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    stat_passes++;
}

// ------------------------------------------------------------------ executor
static void exec_list(uint64_t handle, int depth) {
    uint64_t p = handle;
    for (int guard = 0; guard < 10000000; guard++) {
        CmdRec *r = (CmdRec *)(uintptr_t)p;
        void *x = r->extra;
        if (r->op < CMD_COUNT) op_counts[r->op]++;
        switch (r->op) {
        case CMD_END: return;
        case CMD_JUMP: p = r->x[0]; continue;
        case CMD_CALL: {
            const uint64_t *h = x;
            for (uint64_t i = 0; i < r->x[0] && depth < 8; i++) exec_list(h[i], depth + 1);
            break;
        }
        case CMD_BIND_PROGRAM: st.program = (NvnProgram *)(uintptr_t)r->x[0]; break;
        case CMD_BIND_BLEND: { uint8_t *b = x; memcpy(st.blend[b[0] & 7], b, 8); break; }
        case CMD_BIND_CHANNEL_MASK: memcpy(&st.channel_mask, x, 4); break;
        case CMD_BIND_COLOR: memcpy(st.color_state, x, 4); break;
        case CMD_BIND_DEPTH_STENCIL: memcpy(st.ds, x, 8); break;
        case CMD_BIND_MULTISAMPLE: memcpy(st.ms, x, 0x18); break;
        case CMD_BIND_POLYGON: memcpy(st.poly, x, 4); break;
        case CMD_BIND_VERTEX_ATTRIB:
            st.nattrib = (int)r->x[0] > 16 ? 16 : (int)r->x[0];
            memcpy(st.attrib, x, st.nattrib * 4);
            break;
        case CMD_BIND_VERTEX_STREAM:
            st.nstream = (int)r->x[0] > 16 ? 16 : (int)r->x[0];
            memcpy(st.stream, x, st.nstream * 8);
            break;
        case CMD_BIND_VERTEX_BUFFERS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(&st.vbuf[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_UNIFORM_BUFFERS:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 18 && r->x[0] < 6; i++)
                memcpy(&st.ubuf[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_STORAGE_BUFFERS:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 16 && r->x[0] < 6; i++)
                memcpy(&st.sbuf[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_BIND_TEXTURES:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 32 && r->x[0] < 6; i++)
                memcpy(&st.tex[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_BIND_IMAGES:
            for (uint64_t i = 0; i < r->x[2] && r->x[1] + i < 8 && r->x[0] < 6; i++)
                memcpy(&st.img[r->x[0]][r->x[1] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_SET_TEXTURE_POOL: st.tpool = (NvnDescPool *)(uintptr_t)r->x[0]; break;
        case CMD_SET_SAMPLER_POOL: st.spool = (NvnDescPool *)(uintptr_t)r->x[0]; break;
        case CMD_SET_RENDER_TARGETS: {
            {
                const uint64_t *tx = x;
                for (int i = 0; i < (int)r->x[0] && i < 8; i++) {
                    NvnTexture *t = (NvnTexture *)(uintptr_t)tx[i];
                    static int nlog;
                    if (t && (t->flags & 2) && nlog++ < 5) LOG("[metal] video texture %p used as render target\n", t);
                }
            }
            const struct { uint64_t tex[8]; NvnTextureView views[8]; uint8_t has_view[8]; uint64_t depth;
                           NvnTextureView dview; uint8_t has_dview; } *rt = x;
            memset(&st.rt, 0, sizeof st.rt);
            st.rt.ncolor = (int)r->x[0];
            for (int i = 0; i < st.rt.ncolor; i++) {
                st.rt.color[i] = (NvnTexture *)(uintptr_t)rt->tex[i];
                st.rt.cview[i] = rt->views[i];
                st.rt.has_cview[i] = rt->has_view[i];
            }
            st.rt.depth = (NvnTexture *)(uintptr_t)rt->depth;
            st.rt.dview = rt->dview;
            st.rt.has_dview = rt->has_dview;
            st.rt_dirty = true;
            break;
        }
        case CMD_SET_VIEWPORTS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.viewport[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_SET_SCISSORS:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.scissor[r->x[0] + i], (uint8_t *)x + i * 16, 16);
            break;
        case CMD_SET_DEPTH_RANGES:
            for (uint64_t i = 0; i < r->x[1] && r->x[0] + i < 16; i++) memcpy(st.depth_range[r->x[0] + i], (uint8_t *)x + i * 8, 8);
            break;
        case CMD_SET_BLEND_COLOR: memcpy(st.blend_color, x, 16); break;
        case CMD_SET_STENCIL: {
            int face = (int)r->x[0];
            for (int f = 0; f < 2; f++) {
                if (!(face & (1 << f))) continue;
                if (r->x[6] == 0) st.stencil_ref[f] = (uint32_t)r->x[1];
                else if (r->x[6] == 1) st.stencil_mask[f] = (uint32_t)r->x[1];
                else st.stencil_vmask[f] = (uint32_t)r->x[1];
            }
            break;
        }
        case CMD_SET_PRIMITIVE_RESTART: st.prim_restart = r->x[0] != 0; st.restart_index = (uint32_t)r->x[1]; break;
        case CMD_SET_COPY_STRIDES: st.copy_row_stride = r->x[0]; st.copy_image_stride = r->x[1]; break;
        case CMD_CLEAR_COLOR: {
            int index = (int)r->x[0];
            if (index < st.rt.ncolor && st.rt.color[index]) clear(index, (int)r->x[5], x, (uint32_t)r->x[2], false, 0, false, 0, 0);
            break;
        }
        case CMD_CLEAR_DEPTH_STENCIL:
            if (st.rt.depth) {
                // (depth s0, depthMask x1, stencil x2, stencilMask x3)
                bool has_stencil = renderer_format_has_stencil(st.rt.depth->format);
                clear(-1, 0, NULL, 0, r->x[0] != 0, r->f[0], has_stencil && r->x[2] != 0, (uint32_t)r->x[1],
                      (uint32_t)r->x[2]);
            }
            break;
        case CMD_DISPATCH:
            dispatch_compute((uint32_t)r->x[0], (uint32_t)r->x[1], (uint32_t)r->x[2]);
            if (st.program) {
                static uint64_t seen[16];
                static int nseen;
                uint64_t cs = st.program->stages[5].code_addr;
                bool known = false;
                for (int i = 0; i < nseen; i++) known |= seen[i] == cs;
                if (!known && nseen < 16) {
                    seen[nseen++] = cs;
                    char path[64];
                    snprintf(path, sizeof path, "build/cs_%d.bin", nseen - 1);
                    FILE *f = fopen(path, "wb");
                    fwrite((void *)(uintptr_t)cs, 1, 0x4000, f);
                    fclose(f);
                    LOG("[dispatch] new compute program %d: cs %llx groups %llu %llu %llu images:", nseen - 1, cs, r->x[0], r->x[1], r->x[2]);
                    for (int i = 0; i < 8; i++) if (st.img[5][i]) LOG(" %d=%llx", i, st.img[5][i]);
                    LOG(" tex:");
                    for (int i = 0; i < 8; i++) if (st.tex[5][i]) LOG(" %d=%llx", i, st.tex[5][i]);
                    LOG(" ubuf:");
                    for (int i = 0; i < 8; i++) if (st.ubuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.ubuf[5][i].addr, st.ubuf[5][i].size);
                    LOG(" ssbo:");
                    for (int i = 0; i < 8; i++) if (st.sbuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.sbuf[5][i].addr, st.sbuf[5][i].size);
                    LOG("\n");
                }
            }
            if (g_debug_frame && st.program) {
                LOG("[dispatch] %llu %llu %llu prog %p cs %llx\n", r->x[0], r->x[1], r->x[2], st.program, st.program->stages[5].code_addr);
                FILE *f = fopen("build/cs_code.bin", "wb");
                fwrite((void *)(uintptr_t)st.program->stages[5].code_addr, 1, 0x4000, f);
                fclose(f);
                f = fopen("build/cs_ctrl.bin", "wb");
                fwrite(st.program->stages[5].control, 1, 0x900, f);
                fclose(f);
                LOG("[dispatch] images:");
                for (int i = 0; i < 8; i++) if (st.img[5][i]) LOG(" %d=%llx", i, st.img[5][i]);
                LOG(" tex:");
                for (int i = 0; i < 8; i++) if (st.tex[5][i]) LOG(" %d=%llx", i, st.tex[5][i]);
                LOG(" ubuf:");
                for (int i = 0; i < 8; i++) if (st.ubuf[5][i].addr) LOG(" %d=%llx/%llu", i, st.ubuf[5][i].addr, st.ubuf[5][i].size);
                LOG("\n");
            }
            break;
        case CMD_DRAW_ARRAYS: draw(r, false); break;
        case CMD_DRAW_ELEMENTS: draw(r, true); break;
        case CMD_UPDATE_UNIFORM_BUFFER:
            // (buffer, size, offset, dataSize, data): apply the update in command order
            memcpy((void *)(uintptr_t)(r->x[0] + r->x[2]), x, r->x[3]);
            break;
        case CMD_FENCE_SYNC: break;
        case CMD_REPORT_COUNTER: {
            uint64_t *out = (uint64_t *)(uintptr_t)r->x[1];
            if (out) { out[0] = 0; out[1] = SDL_GetTicksNS(); }
            break;
        }
        case CMD_COPY_TEXTURE_TO_TEXTURE: {
            const TexRefRec *t = x;
            copy_texture(&t[0], &t[1], r->x[6]);
            break;
        }
        case CMD_DOWNSAMPLE: {
            const TexRefRec *t = x;
            copy_texture(&t[0], &t[1], 1);
            break;
        }
        case CMD_COPY_BUFFER_TO_TEXTURE: copy_buffer_to_texture(r->x[0], x); break;
        case CMD_COPY_TEXTURE_TO_BUFFER: copy_texture_to_buffer(x, r->x[3]); break;
        case CMD_COPY_BUFFER_TO_BUFFER:
            renderer_flush();
            memmove((void *)(uintptr_t)r->x[1], (void *)(uintptr_t)r->x[0], r->x[2]);
            break;
        default: break;
        }
        p += r->size;
    }
}

void backend_execute(uint64_t handle) {
    @autoreleasepool {
        exec_list(handle, 0);
        renderer_flush();  // the guest may reuse memory as soon as the submit returns
    }
}
