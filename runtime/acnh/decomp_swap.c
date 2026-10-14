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

// obj->vtable[slot](x1, x2) returning u64
static uint64_t vcall2(Cpu *c, uint64_t obj, int slot, uint64_t x1, uint64_t x2) {
    c->x[0] = obj, c->x[1] = x1, c->x[2] = x2;
    guest_call(c, LD64(LD64(obj) + 8 * slot));
    return c->x[0];
}

// void* operator new(size_t size, sead::Heap* heap, s32 alignment)  0x7101d70230
// (lib/sead/modules/src/basis/seadNew.cpp: sead::system::NewImpl(heap, size, alignment, true), inlined.) Native so a
// failed allocation says which heap ran out: the game itself just gets nullptr and crashes further on.
void hle__ZnwmPN4sead4HeapEi(Cpu *c) {
    uint64_t size = c->x[0], heap = c->x[1], align = (uint32_t)c->x[2];
    uint64_t mgr = LD64(LD64(MAIN_BASE + 0x38b1660));  // sead::HeapMgr::sInstancePtr (via the GOT)
    if (!mgr) {  // no heap manager yet: malloc
        guest_call(c, DECOMP(0x7101cebe60));
        if (!c->x[0]) LOG("[decomp] operator new(%#llx): malloc fallback failed, lr %llx\n", size, c->x[30]);
        return;
    }
    if (!heap) {
        uint64_t lr = c->x[30];
        c->x[0] = mgr;
        guest_call(c, DECOMP(0x7101d920b0));  // sead::HeapMgr::getCurrentHeap()
        if (!(heap = c->x[0])) {
            // getCurrentHeap: the current sead::Thread (TLS slot ThreadMgr+0x68) -> its heap (+0xa8), else HeapMgr+8
            uint64_t tmgr = LD64(LD64(MAIN_BASE + 0x38b32b8));  // sead::ThreadMgr::sInstance (via the GOT)
            uint32_t slot = tmgr ? LD32(tmgr + 0x68) : 0;
            c->x[0] = slot;
            if (tmgr) guest_call(c, MAIN_BASE + 0x262e2b0);  // nn::os::GetTlsValue (import stub)
            uint64_t th = tmgr ? c->x[0] : 0;
            LOG("[decomp] operator new(%#llx): no heap given and no current heap (ThreadMgr %llx, TLS slot %u -> "
                "thread %llx, its heap %llx; HeapMgr %llx +8 = %llx), lr %llx\n", size, tmgr, slot, th,
                th ? LD64(th + 0xa8) : 0, mgr, LD64(mgr + 8), lr);
            uint64_t ht = LD64(DECOMP(0x710414b8f0));  // Lp::Sys::HeapTable::sInstance: heaps at +0x100
            for (int i = 0; ht && i < 7; i++) {
                uint64_t h = LD64(ht + 0x100 + 8 * i);
                LOG("[decomp]   HeapTable heap %d: %llx \"%s\" size %#llx free %#llx\n", i, h,
                    h ? (const char *)(uintptr_t)LD64(h + 0x28) : "-", h ? vcall2(c, h, 15, 0, 0) : 0,
                    h ? vcall2(c, h, 16, 0, 0) : 0);
            }
            c->x[0] = 0;
            return;
        }
    }
    uint64_t p = vcall2(c, heap, 6, size, align);  // tryAlloc
    if (!p) {
        static int nlog;
        if (nlog++ < 20) {
            const char *name = (const char *)(uintptr_t)LD64(heap + 0x28);  // INamable (+0x20): SafeString's string
            uint64_t total = vcall2(c, heap, 15, 0, 0), free = vcall2(c, heap, 16, 0, 0);  // getSize, getFreeSize
            LOG("[decomp] operator new(%#llx, align %llu) failed in heap \"%s\" (%llx: size %#llx, free %#llx), lr %llx\n",
                size, align, name ? name : "?", heap, total, free, c->x[30]);
        }
    }
    c->x[0] = p;
}

static const char *heap_name(uint64_t h) {
    const char *n = h ? (const char *)(uintptr_t)LD64(h + 0x28) : NULL;  // INamable (+0x20): SafeString's string
    return n ? n : "-";
}

// sead::ExpHeap::create(size_t size, const SafeString& name, Heap* parent, s32 align, HeapDirection, bool lock)
// 0x7101d8f970: a thunk (lock &= 1) into 0x7101d8f980. Native to say which heaps can't be made, and why.
void hle_exp_heap_create(Cpu *c) {
    uint64_t size = c->x[0], name = LD64(c->x[1] + 8), parent = c->x[2], lr = c->x[30];
    c->x[5] &= 1;
    guest_call(c, DECOMP(0x7101d8f980));
    if (!c->x[0]) {
        uint64_t r = c->x[0];
        LOG("[decomp] ExpHeap::create(\"%s\", size %#llx) failed: parent %llx \"%s\" (slots 15/16/17: %#llx %#llx %#llx), "
            "lr %llx\n", name ? (const char *)(uintptr_t)name : "?", size, parent, heap_name(parent),
            parent ? vcall2(c, parent, 15, 0, 0) : 0, parent ? vcall2(c, parent, 16, 0, 0) : 0,
            parent ? vcall2(c, parent, 17, 8, 0) : 0, lr);
        c->x[0] = r;
    }
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
