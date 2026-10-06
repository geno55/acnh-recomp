// Temporary renderer backend: walks command lists without drawing.
#include "nvn.h"

static uint64_t frames, draws;

void backend_init(void) {}
void backend_texture_destroyed(NvnTexture *tex) { (void)tex; }
void backend_pool_written(uint64_t addr, uint64_t size) { (void)addr; (void)size; }

void backend_execute(uint64_t handle) {
    uint64_t p = handle;
    for (int guard = 0; guard < 1000000; guard++) {
        CmdRec *r = (CmdRec *)(uintptr_t)p;
        switch (r->op) {
        case CMD_END: return;
        case CMD_JUMP: p = r->x[0]; continue;
        case CMD_CALL: {
            const uint64_t *h = (const uint64_t *)r->extra;
            for (uint64_t i = 0; i < r->x[0]; i++) backend_execute(h[i]);
            break;
        }
        case CMD_DRAW_ARRAYS: case CMD_DRAW_ELEMENTS: draws++; break;
        }
        p += r->size;
    }
}

void backend_present(NvnTexture *tex) {
    if (++frames % 60 == 0) LOG("[nvn] frame %llu (%llu draws so far), present %ux%u\n", frames, draws, tex->width, tex->height);
}
