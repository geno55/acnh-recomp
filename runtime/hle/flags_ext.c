// More event flags. The game's GlobalFlags bitfield holds 2048 flags (256 bytes at save +0x5DC0); vanilla uses
// <= 1118, LAS ~100, potsanity ~415 - bushsanity's ~900 don't fit. The flag object reaches the bitfield through a
// pointer (main+0x1CC1388) and a byte capacity (main+0x1CC1390, bounds-checked by every flag get / set): we point it
// at a 512-byte buffer of ours (4096 flags).
//   bits 0-2047     mirrored into the save every frame both ways (whatever writes the save copy directly - loads,
//                   the save editor, LARECOMP_SET_FLAGS - is taken over; the game saves the save copy as before)
//   bits 2048-4095  kept in a sidecar file next to each save slot (savedataN.bin -> savedataN.bin.flagsx)
// The file-select screen reads every slot, so a slot's extra bits are matched to the save the game puts in play by
// the body CRC (save +0x5EC4) of the data read from its file.
// Only on when the seed needs it (rando/<seed>/flags_ext exists) or LARECOMP_FLAGS_EXT=1.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "../hle.h"
#include "../rando.h"

#define FLAG_PTR (MAIN_BASE + 0x1CC1388)
#define FLAG_CAP (MAIN_BASE + 0x1CC1390)
#define LIVE_SAVE (MAIN_BASE + 0x1CBB220)
#define LIVE_FLAGS (LIVE_SAVE + 0x5DC0)
#define BODY_CRC 0x5EC4

static uint8_t g_buf[512] __attribute__((aligned(16)));
static uint8_t g_shadow[256];   // the save copy as of our last sync
static int g_on = -1;

// extra bits per slot file, with the body CRC of what was read from it
typedef struct { char path[1024]; uint32_t crc; uint8_t ext[256]; } Slot;
static Slot g_slots[8];
static int g_nslots;
static char g_current[1024];    // slot file of the save in play ("" = unknown / new game)
static uint32_t g_live_crc;     // body CRC of the save in play when we last matched it

static bool enabled(void) {
    if (g_on < 0) {
        const char *e = ENV("LARECOMP_FLAGS_EXT");
        g_on = e ? atoi(e) != 0 : 0;
        if (!e && rando_seed_dir()) {  // (LARECOMP_FLAGS_EXT=0 forces it off)
            char p[512];
            struct stat sb;
            snprintf(p, sizeof p, "%s/flags_ext", rando_seed_dir());
            g_on = stat(p, &sb) == 0;
        }
        if (g_on) LOG("[flags] extended event flags: 4096 (bits 2048+ in savedataN.bin.flagsx)\n");
    }
    return g_on;
}

static void sidecar_path(const char *save, char *out, size_t n) { snprintf(out, n, "%s.flagsx", save); }

static Slot *slot_for(const char *path) {
    for (int i = 0; i < g_nslots; i++)
        if (!strcmp(g_slots[i].path, path)) return &g_slots[i];
    if (g_nslots == 8) return NULL;
    Slot *s = &g_slots[g_nslots++];
    memset(s, 0, sizeof *s);
    strlcpy(s->path, path, sizeof s->path);
    return s;
}

// fs.c: a save file was read into guest memory
void flags_ext_save_read(const char *path, uint64_t addr, int64_t off, int64_t size) {
    if (!enabled() || off != 0 || size < BODY_CRC + 4) return;
    Slot *s = slot_for(path);
    if (!s) return;
    s->crc = *(const uint32_t *)(uintptr_t)(addr + BODY_CRC);
    memset(s->ext, 0, sizeof s->ext);
    char sc[1100];
    sidecar_path(path, sc, sizeof sc);
    FILE *f = fopen(sc, "rb");
    if (f) {
        size_t n = fread(s->ext, 1, sizeof s->ext, f);
        (void)n;
        fclose(f);
    }
}

// fs.c: a save file was written from guest memory
void flags_ext_save_written(const char *path, uint64_t addr, int64_t off, int64_t size) {
    if (!enabled() || off != 0 || size < BODY_CRC + 4) return;
    strlcpy(g_current, path, sizeof g_current);
    g_live_crc = *(const uint32_t *)(uintptr_t)(addr + BODY_CRC);
    Slot *s = slot_for(path);
    if (s) { s->crc = g_live_crc; memcpy(s->ext, g_buf + 256, 256); }
    char sc[1100];
    sidecar_path(path, sc, sizeof sc);
    bool any = false;
    for (int i = 256; i < 512; i++) any |= g_buf[i] != 0;
    struct stat sb;
    if (!any && stat(sc, &sb)) return;  // nothing to keep and no file yet
    FILE *f = fopen(sc, "wb");
    if (f) {
        fwrite(g_buf + 256, 1, 256, f);
        fclose(f);
    }
}

void flags_ext_tick(void) {
    if (!enabled()) return;
    uint8_t *live = (uint8_t *)(uintptr_t)LIVE_FLAGS;
    uint64_t p = LD64(FLAG_PTR);
    if (p != LIVE_FLAGS && p != (uint64_t)(uintptr_t)g_buf) return;  // not set up yet (or not what we expect)
    // a save read from a slot came into play: that slot's extra bits (an unknown CRC - e.g. the game updating it
    // while saving - keeps what we have)
    uint32_t crc = *(const uint32_t *)(uintptr_t)(LIVE_SAVE + BODY_CRC);
    if (crc != g_live_crc) {
        g_live_crc = crc;
        for (int i = 0; i < g_nslots; i++)
            if (g_slots[i].crc == crc && strcmp(g_current, g_slots[i].path)) {
                memcpy(g_buf + 256, g_slots[i].ext, 256);
                strlcpy(g_current, g_slots[i].path, sizeof g_current);
                LOG("[flags] save in play: %s (extra flags loaded)\n", g_current);
            }
    }
    // a new game: the save's flags start all clear -> so do the extra ones
    static bool was_blank = true;
    bool blank = true;
    for (int i = 0; i < 256 && blank; i++) blank = live[i] == 0;
    if (blank && !was_blank) { memset(g_buf + 256, 0, 256); g_current[0] = 0; LOG("[flags] new game: extra flags cleared\n"); }
    was_blank = blank;
    if (p == LIVE_FLAGS) {  // take over the bitfield
        memcpy(g_buf, live, 256);
        memcpy(g_shadow, live, 256);
        *(uint64_t *)(uintptr_t)FLAG_PTR = (uint64_t)(uintptr_t)g_buf;
        *(uint32_t *)(uintptr_t)FLAG_CAP = 512;
        LOG("[flags] event flag bitfield moved to our 512-byte buffer\n");
        return;
    }
    // bits changed in the save copy since the last sync win, then the save copy follows the buffer
    for (int i = 0; i < 256; i++) {
        uint8_t d = live[i] ^ g_shadow[i];
        if (d) g_buf[i] = (uint8_t)((g_buf[i] & ~d) | (live[i] & d));
    }
    memcpy(live, g_buf, 256);
    memcpy(g_shadow, g_buf, 256);
    static uint8_t prev_ext[256];  // (log extended flags set by the game)
    for (int i = 0; i < 256; i++)
        if (g_buf[256 + i] != prev_ext[i]) {
            for (int b = 0; b < 8; b++)
                if ((g_buf[256 + i] ^ prev_ext[i]) >> b & 1)
                    LOG("[flags] flag %d -> %d\n", 2048 + i * 8 + b, (g_buf[256 + i] >> b) & 1);
            prev_ext[i] = g_buf[256 + i];
        }
}

// event flag `idx` (0..4095) as the game sees it: our buffer once it has taken over, else the save's own bitfield
bool flags_ext_get(int idx) {
    if (idx < 0 || idx >= 4096) return false;
    if (LD64(FLAG_PTR) == (uint64_t)(uintptr_t)g_buf) return (g_buf[idx >> 3] >> (idx & 7)) & 1;
    if (idx >= 2048) return false;
    return (LD8(LIVE_FLAGS + (idx >> 3)) >> (idx & 7)) & 1;
}

// set event flag `idx` (runtime features: Chaos map letters) - only once the bitfield is ours
void flags_ext_set(int idx) {
    if (idx < 0 || idx >= 4096 || LD64(FLAG_PTR) != (uint64_t)(uintptr_t)g_buf) return;
    g_buf[idx >> 3] |= (uint8_t)(1 << (idx & 7));
}
