// Functions from the matching decomp (E:\games\acnh, src/lp/RootTask.cpp) running natively in place of their
// generated versions (PLAN.md Phase 0, step 4). `gen.py --hle runtime/acnh/hle_main.txt` makes each listed function's
// generated body call hle_<mangled name> here instead, for direct (bl) and indirect (vtable) calls alike.
//
// The adapter: guest arguments and results are in c->x[] (AArch64 ABI), and guest addresses are host addresses, so
// the decomp's structs are read and written in place. Calls out to guest code (still generated) go through
// guest_call; a native function only has to leave x19-x29 and sp as it found them, which it does by not touching them.
#include "hle.h"

#define DECOMP(a) (MAIN_BASE + ((a) - 0x7100000000ull))  // decomp address (main at 0x71_0000_0000) -> guest address

// obj->vtable[slot]() for a method with no arguments returning s32
static int32_t vcall_s32(Cpu *c, uint64_t obj, int slot) {
    c->x[0] = obj;
    guest_call(c, LD64(LD64(obj) + 8 * slot));
    return (int32_t)c->x[0];
}

// The decomp's RootTask (src/app/RootTask.h), only up to the member used here; layout_checks.cpp pins the offset.
typedef struct RootTask {
    uint8_t _0[0x1b0];
    int32_t mCalcCount;  // +0x1b0
} RootTask;

// void RootTask::calc()  0x710207dd10
void hle__ZN8RootTask4calcEv(Cpu *c) {
    RootTask *self = (RootTask *)(uintptr_t)c->x[0];
    if (self->mCalcCount == 0) LOG("[decomp] RootTask::calc (native) first call, this=%llx\n", c->x[0]);
    self->mCalcCount++;
}

// void RootTask::enter()  0x710207dcb0
void hle__ZN8RootTask5enterEv(Cpu *c) {
    uint64_t hooks = LD64(DECOMP(0x710414cd88));  // SceneMgrHooks::sInstance
    // hooks->unk13() >= 0 ? hooks->unk13() : hooks->unk14()  (SEAD_RTTI_BASE takes slots 0-1)
    int32_t scene = vcall_s32(c, hooks, 13) >= 0 ? vcall_s32(c, hooks, 13) : vcall_s32(c, hooks, 14);
    LOG("[decomp] RootTask::enter (native): first scene %d\n", scene);
    c->x[0] = (uint32_t)scene;
    c->x[1] = 0;
    guest_call(c, DECOMP(0x710230e4f0));  // Lp::Utl::changeScene(scene, nullptr)
}
