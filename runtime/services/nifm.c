// nifm:u (network interface), offline: like a console with no network. Requests are accepted for submission and
// end at once with "no internet connection"; the connection queries all say there is none. Without it, the logging
// stub returned no IGeneralService / IRequest objects and nn::nifm crashed on them (ACNH, after the title's
// controller check).
#include <stdlib.h>

#include "../hle.h"
#include "../ipc.h"
#include "../kernel.h"

#define NIFM_NO_INTERNET MAKE_RESULT(110, 300)
enum { REQUEST_INVALID = 0, REQUEST_FREE = 1, REQUEST_ON_HOLD = 2, REQUEST_ACCEPTED = 3, REQUEST_BLOCKING = 4 };

typedef struct {
    uint32_t state;
    KEvent *ev[2];      // the two events GetSystemEventReadableHandles hands out
    uint32_t ev_r[2];
} NifmRequest;

static void request_done(NifmRequest *r) {  // (offline: a submitted request is over right away)
    r->state = REQUEST_FREE;
    pthread_mutex_lock(&g_klock);
    for (int i = 0; i < 2; i++) kernel_signal(r->ev[i]);
    pthread_mutex_unlock(&g_klock);
}

static void nifm_request(Service *s, IpcReq *req, IpcResp *resp) {
    NifmRequest *r = s->state;
    switch (req->cmd) {
    case 0: OUT(uint32_t, 0) = r->state; resp_size(resp, 4); break;               // GetRequestState
    case 1: resp->result = r->state == REQUEST_ACCEPTED ? 0 : NIFM_NO_INTERNET; break;  // GetResult
    case 2:                                                                       // GetSystemEventReadableHandles
        resp->copy_handles[resp->ncopy++] = r->ev_r[0];
        resp->copy_handles[resp->ncopy++] = r->ev_r[1];
        break;
    case 3: request_done(r); break;  // Cancel
    case 4:                          // Submit
        LOG("[nifm] request submitted (offline: no internet connection)\n");
        request_done(r);
        break;
    default: break;  // SetRequirement / SetRequirementPreset / SetPriority / ... : accepted, nothing to do
    }
}

static void nifm_request_close(Service *s) { free(s->state); }

static void nifm_general(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 1: {  // GetClientId (out buffer: u32)
        IpcBuf *b = out_buf(req, 0);
        if (b && b->size >= 4) *(uint32_t *)(uintptr_t)b->addr = 1;
        break;
    }
    case 4: {  // CreateRequest(requirement preset) -> IRequest
        NifmRequest *r = calloc(1, sizeof *r);
        uint32_t w;
        r->state = REQUEST_FREE;
        for (int i = 0; i < 2; i++) r->ev[i] = kernel_create_event_pair(&w, &r->ev_r[i]);
        Service *rs = service_new("nifm::IRequest", nifm_request, r);
        rs->on_close = nifm_request_close;
        ipc_return_object(resp, rs);
        break;
    }
    case 21: case 22:  // IsAnyInternetRequestAccepted / IsAnyForegroundRequestAccepted
        OUT(uint8_t, 0) = 0;
        resp_size(resp, 1);
        break;
    case 5: case 12: case 15: case 18:  // GetCurrentNetworkProfile / GetCurrentIpAddress / IpConfigInfo / Status
        resp->result = NIFM_NO_INTERNET;
        break;
    default: LOG("[nifm] IGeneralService cmd %u (ok)\n", req->cmd);
    }
}

static void nifm_static(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    if (req->cmd == 4 || req->cmd == 5)  // CreateGeneralServiceOld / CreateGeneralService
        ipc_return_object(resp, service_new("nifm::IGeneralService", nifm_general, NULL));
    else
        LOG("[nifm] IStaticService cmd %u (ok)\n", req->cmd);
}
SERVICE("nifm:u", nifm_u) { nifm_static(s, req, resp); }
SERVICE("nifm:a", nifm_a) { nifm_static(s, req, resp); }
SERVICE("nifm:s", nifm_s) { nifm_static(s, req, resp); }
