// BCAT (nn::bcat: the game's downloaded "delivery cache" data, e.g. event data), offline: as on a console that
// never downloaded any. The delivery cache storage mounts but is empty, and a sync finishes right away with nothing
// downloaded. Replaced at the library level: with only the bcat:u logging stub, the SDK's state didn't add up and
// UnmountDeliveryCacheStorage aborted (ACNH at boot).
#include <string.h>

#include "../hle.h"

#define BCAT_NOT_FOUND MAKE_RESULT(122, 2)

HLE_FUNC("_ZN2nn4bcat10InitializeEv", bcat_initialize) { (void)c; LOG("[bcat] Initialize (offline: empty delivery cache)\n"); }
HLE_FUNC("_ZN2nn4bcat25MountDeliveryCacheStorageEv", bcat_mount) { c->x[0] = 0; }
HLE_FUNC("_ZN2nn4bcat27UnmountDeliveryCacheStorageEv", bcat_unmount) { (void)c; }

// The directory / file / progress objects carry no state here: constructors and destructors do nothing.
HLE_FUNC("_ZN2nn4bcat22DeliveryCacheDirectoryC1Ev", bcat_dir_ctor) { (void)c; }
HLE_FUNC("_ZN2nn4bcat22DeliveryCacheDirectoryD1Ev", bcat_dir_dtor) { (void)c; }
HLE_FUNC("_ZN2nn4bcat17DeliveryCacheFileC1Ev", bcat_file_ctor) { (void)c; }
HLE_FUNC("_ZN2nn4bcat17DeliveryCacheFileD1Ev", bcat_file_dtor) { (void)c; }
HLE_FUNC("_ZN2nn4bcat21DeliveryCacheProgressC1Ev", bcat_progress_ctor) { (void)c; }
HLE_FUNC("_ZN2nn4bcat21DeliveryCacheProgressD1Ev", bcat_progress_dtor) { (void)c; }

// Result DeliveryCacheDirectory::Open(const DirectoryName&): there are no directories
HLE_FUNC("_ZN2nn4bcat22DeliveryCacheDirectory4OpenERKNS0_13DirectoryNameE", bcat_dir_open) { c->x[0] = BCAT_NOT_FOUND; }
// Result DeliveryCacheDirectory::Read(int *out_count, DeliveryCacheDirectoryEntry *entries, int max)
HLE_FUNC("_ZN2nn4bcat22DeliveryCacheDirectory4ReadEPiPNS0_27DeliveryCacheDirectoryEntryEi", bcat_dir_read) {
    if (c->x[1]) *(int32_t *)(uintptr_t)c->x[1] = 0;
    c->x[0] = 0;
}
// Result DeliveryCacheFile::Open(const DirectoryName&, const FileName&): no files either
HLE_FUNC("_ZN2nn4bcat17DeliveryCacheFile4OpenERKNS0_13DirectoryNameERKNS0_8FileNameE", bcat_file_open) {
    c->x[0] = BCAT_NOT_FOUND;
}
// Result DeliveryCacheFile::Read(size_t *out_size, int64_t offset, void *buffer, size_t size)
HLE_FUNC("_ZN2nn4bcat17DeliveryCacheFile4ReadEPmlPvm", bcat_file_read) {
    if (c->x[1]) *(uint64_t *)(uintptr_t)c->x[1] = 0;
    c->x[0] = 0;
}
// Digest DeliveryCacheFile::GetDigest() (16 bytes, returned in x0:x1)
HLE_FUNC("_ZN2nn4bcat17DeliveryCacheFile9GetDigestEv", bcat_file_digest) { c->x[0] = 0, c->x[1] = 0; }

// Result RequestSyncDeliveryCache(DeliveryCacheProgress*): done at once, nothing downloaded
HLE_FUNC("_ZN2nn4bcat24RequestSyncDeliveryCacheEPNS0_21DeliveryCacheProgressE", bcat_request_sync) {
    LOG("[bcat] RequestSyncDeliveryCache (offline: done, nothing downloaded)\n");
    c->x[0] = 0;
}
HLE_FUNC("_ZN2nn4bcat21DeliveryCacheProgress6UpdateEv", bcat_progress_update) { (void)c; }
// DeliveryCacheProgressStatus: None 0, Queued 1, Connecting 2, ProcessingDataList 3, Downloading 4, Committing 5,
// Done 9
HLE_FUNC("_ZNK2nn4bcat21DeliveryCacheProgress9GetStatusEv", bcat_progress_status) { c->x[0] = 9; }
HLE_FUNC("_ZNK2nn4bcat21DeliveryCacheProgress9GetResultEv", bcat_progress_result) { c->x[0] = 0; }
HLE_FUNC("_ZNK2nn4bcat21DeliveryCacheProgress18GetWholeDownloadedEv", bcat_progress_downloaded) { c->x[0] = 0; }
