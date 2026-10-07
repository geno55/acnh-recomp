// nn::vi (display/layer) and nv:: (graphics driver init), implemented on the host.
#include <stdlib.h>
#include <time.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>

#include "../hle.h"
#include "../kernel.h"

static uint32_t vsync_r, vsync_w;
static KEvent *vsync_event;

// Real-time (time-constraint) thread: exempt from the timer coalescing macOS applies to
// ordinary threads when the app isn't frontmost, which otherwise stretches 16ms waits to ~100ms.
static void make_realtime(uint64_t period_ns) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t period = period_ns * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t pol = {
        .period = (uint32_t)period,
        .computation = (uint32_t)(period / 20),
        .constraint = (uint32_t)(period / 4),
        .preemptible = 1,
    };
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void *vsync_thread(void *arg) {
    (void)arg;
    make_realtime(16666667);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t period = 16666667ull * tb.denom / tb.numer;
    uint64_t next = mach_absolute_time();
    for (;;) {
        next += period;
        mach_wait_until(next);
        uint64_t now = mach_absolute_time();
        if (now > next + period * 3) {
            static int warned;
            if (warned++ < 20) LOG("[vi] vsync timer late by %llums (host throttling?)\n", (unsigned long long)((now - next) * tb.numer / tb.denom / 1000000));
            next = now;  // don't burst-signal to catch up
        }
        pthread_mutex_lock(&g_klock);
        kernel_signal(vsync_event);
        pthread_mutex_unlock(&g_klock);
    }
    return NULL;
}

HLE_FUNC("_ZN2nn2vi10InitializeEv", vi_initialize) { (void)c; }
HLE_FUNC("_ZN2nn2vi8FinalizeEv", vi_finalize) { (void)c; }

HLE_FUNC("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", vi_open_default_display) {
    *(uint64_t *)(uintptr_t)c->x[0] = (uint64_t)hle_alloc(0x100);
    c->x[0] = 0;
}

HLE_FUNC("_ZN2nn2vi12CloseDisplayEPNS0_7DisplayE", vi_close_display) { (void)c; }

HLE_FUNC("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", vi_create_layer) {
    *(uint64_t *)(uintptr_t)c->x[0] = (uint64_t)hle_alloc(0x100);
    c->x[0] = 0;
}

HLE_FUNC("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE", vi_destroy_layer) { (void)c; }
HLE_FUNC("_ZN2nn2vi12SetLayerCropEPNS0_5LayerEiiii", vi_set_layer_crop) { c->x[0] = 0; }

uint64_t g_native_window;

HLE_FUNC("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", vi_get_native_window) {
    if (!g_native_window) g_native_window = (uint64_t)hle_alloc(0x100);
    *(uint64_t *)(uintptr_t)c->x[0] = g_native_window;
    c->x[0] = 0;
}

HLE_FUNC("_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE", vi_get_vsync_event) {
    if (!vsync_event) {
        vsync_event = kernel_create_event_pair(&vsync_w, &vsync_r);
        pthread_t t;
        pthread_create(&t, NULL, vsync_thread, NULL);
    }
    // nn::os::AttachReadableHandleToSystemEvent(event, handle, managed=false, clear_mode=AutoClear)
    c->x[1] = vsync_r;
    c->x[2] = 0;
    c->x[3] = 1;
    guest_call(c, guest_sym("_ZN2nn2os33AttachReadableHandleToSystemEventEPNS0_15SystemEventTypeEjbNS0_14EventClearModeE"));
    c->x[0] = 0;
}

HLE_FUNC("_ZN2nv18InitializeGraphicsEPvm", nv_initialize_graphics) { (void)c; }
HLE_FUNC("_ZN2nv16FinalizeGraphicsEv", nv_finalize_graphics) { (void)c; }
HLE_FUNC("_ZN2nv20SetGraphicsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", nv_set_allocator) { (void)c; }
HLE_FUNC("_ZN2nv28SetGraphicsDevtoolsAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", nv_set_dt_allocator) { (void)c; }
