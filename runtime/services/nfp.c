// nfp:user (amiibo), offline: the service initializes and reports no NFC devices, so games see amiibo as
// unavailable. Without it, the logging stub's empty replies left nn::nfp::Initialize with no IUser object (ACNH
// crashed there at boot).
#include "../hle.h"
#include "../ipc.h"

#define NFP_DEVICE_NOT_FOUND MAKE_RESULT(115, 64)

typedef struct { uint32_t state; } NfpUser;  // 0 NonInitialized, 1 Initialized

static uint32_t new_event_handle(void) {
    uint32_t w, r;
    kernel_create_event_pair(&w, &r);
    return r;
}

static void nfp_user(Service *s, IpcReq *req, IpcResp *resp) {
    NfpUser *u = s->state;
    switch (req->cmd) {
    case 0:  // Initialize(aruid, pid, version info)
        u->state = 1;
        LOG("[nfp] Initialize (offline: no NFC devices)\n");
        break;
    case 1: u->state = 0; break;  // Finalize
    case 2: OUT(uint32_t, 0) = 0; resp_size(resp, 4); break;  // ListDevices: none
    case 19: OUT(uint32_t, 0) = u->state; resp_size(resp, 4); break;  // GetState
    case 23: resp->copy_handles[resp->ncopy++] = new_event_handle(); break;  // AttachAvailabilityChangeEvent
    case 17: case 18:  // AttachActivateEvent / AttachDeactivateEvent(device): there is none
    case 3: case 4: case 5: case 6: case 7: case 8: case 9: case 10: case 11: case 12: case 13: case 14: case 15:
    case 16: case 20: case 21: case 22: case 24:  // detection, mount, application area, tag info, device state...
        resp->result = NFP_DEVICE_NOT_FOUND;
        break;
    default: LOG("[nfp] IUser cmd %u (ok)\n", req->cmd);
    }
}

static void nfp_user_close(Service *s) { free(s->state); }

SERVICE("nfp:user", nfp_user_manager) {
    (void)s;
    if (req->cmd == 0) {  // CreateUserInterface
        Service *user = service_new("nfp::IUser", nfp_user, calloc(1, sizeof(NfpUser)));
        user->on_close = nfp_user_close;
        ipc_return_object(resp, user);
    } else {
        LOG("[nfp] IUserManager cmd %u (ok)\n", req->cmd);
    }
}
