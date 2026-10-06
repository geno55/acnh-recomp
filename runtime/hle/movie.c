// movie:: (nnMedia video playback). Not implemented yet: extractors and decoders fail cleanly,
// so the game treats videos as unplayable instead of crashing.
#include "../hle.h"

static void movie_fail(Cpu *c) {
    static int n;
    if (n++ < 8) LOG("[movie] virtual call from %llx -> failing\n", c->x[30]);
    c->x[0] = 1;
}

static uint64_t failing_vtable(void) {
    static uint64_t vt;
    if (!vt) {
        uint64_t *t = hle_alloc(64 * 8);
        uint64_t f = hle_register("<movie vfunc>", movie_fail);
        for (int i = 0; i < 64; i++) t[i] = f;
        vt = (uint64_t)t;
    }
    return vt;
}

HLE_FUNC("_ZN5movie9ExtractorC1ENS_13ContainerTypeE", movie_extractor_ctor) {
    uint64_t *self = (uint64_t *)(uintptr_t)c->x[0];
    self[0] = failing_vtable();
    self[1] = 0;
}

HLE_FUNC("_ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", movie_set_allocator) { (void)c; }
HLE_FUNC("_ZN5movie17SetThreadPriorityEi", movie_set_thread_priority) { (void)c; }
HLE_FUNC("_ZN5movie17GetThreadPriorityEv", movie_get_thread_priority) { c->x[0] = 16; }

HLE_FUNC("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", movie_decoder_ctor) {
    uint64_t *self = (uint64_t *)(uintptr_t)c->x[0];
    self[0] = failing_vtable();
    self[1] = 0;
}
