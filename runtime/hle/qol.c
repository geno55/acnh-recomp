// Quality-of-life options re-implemented from community GameBanana mods (credits in README.md; none of their files
// are used): 360-degree movement and blur removal ("360 Controls (And More!)"). Button prompts are
// runtime/nvn/texpatch.c, the Hero Mode icon is hidden there too.
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../settings.h"

#define MAIN_BASE 0x7000000000ull

// 360-degree movement: main+0xded9f0 (tools/patches.py SNAP_DIR_SITE) turns the stick vector (s1 = x, s2 = y) into
// one of 8 directions, returned in w0 as an angle (full turn = 2^32, 0 = down, 2^30 = right). With the setting on
// it returns the stick's own angle (returns 1: the original function is skipped).
int rt_snap_dir(Cpu *c) {
    static int env = -1, logn;  // LARECOMP_MOVE_360=0/1: test override; LARECOMP_LOG_SNAP: log some calls
    if (env < 0) { const char *e = getenv("LARECOMP_MOVE_360"); env = e ? atoi(e) != 0 : 2; logn = ENV("LARECOMP_LOG_SNAP") ? 0 : -1; }
    float x, y;
    memcpy(&x, &c->v[1], 4);
    memcpy(&y, &c->v[2], 4);
    bool on = env == 2 ? g_settings.move_360 : env;
    static bool inner;
    if (inner) return 0;
    double turns = atan2(y, x) / (2 * M_PI) + 0.25;  // (the mod: floor(degrees) + 90)
    uint32_t a = (uint32_t)(int64_t)llround(turns * 4294967296.0);
    if (logn >= 0 && logn++ % 30 == 0) {  // (with the game's own 8-way answer for comparison)
        extern void f_7000ded9f0(Cpu *);
        static Cpu tmp;
        tmp = *c;
        inner = true;
        f_7000ded9f0(&tmp);
        inner = false;
        LOG("[qol] snap (%.3f, %.3f): 8-way %#x, 360 %#x (%s)\n", x, y, (uint32_t)tmp.x[0], a, on ? "360" : "8-way");
    }
    if (!on) return 0;
    c->x[0] = a;
    return 1;
}

// Blur removal: the post-process looks its tilt-shift parameters up in postprocess.bfsha by the name at
// main+0x16cbd73 ("PFXTiltShiftParam"); renaming it to one the shader doesn't have turns the blur off (LAS-Randomizer
// 'blur-removal', patch by theboy181). Swapped back and forth here as the setting changes.
#define TILT_NAME (MAIN_BASE + 0x16cbd73)
static char g_tilt_orig[18];

static void set_tilt_name(bool removed) {
    char *p = (char *)(uintptr_t)TILT_NAME;
    if (!g_tilt_orig[0]) {
        if (memcmp(p, "PFXTiltShift", 12)) { LOG("[qol] tilt-shift name not found: blur removal off\n"); g_tilt_orig[0] = 1; return; }
        memcpy(g_tilt_orig, p, sizeof g_tilt_orig);
    }
    if (g_tilt_orig[0] == 1) return;
    uintptr_t page = (uintptr_t)p & ~0x3FFFull;
    plat_protect(page, ((uintptr_t)p + sizeof g_tilt_orig - page + 0x3FFF) & ~0x3FFFull, PLAT_PROT_RW);
    if (removed) memcpy(p, "NoTiltShift", 12);
    else memcpy(p, g_tilt_orig, sizeof g_tilt_orig);
}

static int g_tilt_applied = -1;  // blur removal as last applied to the module (-1: not yet)
RT_ON_RESET(qol_reset) { g_tilt_applied = -1; }  // (reboot: the module is loaded again with the original name)

// Game thread, once per frame (runtime/hle/input.c) and at boot (before the post-process is set up).
void qol_tick(void) {
    static int env = -1;  // LARECOMP_BLUR_REMOVAL=0/1: test override
    if (env < 0) { const char *e = getenv("LARECOMP_BLUR_REMOVAL"); env = e ? atoi(e) != 0 : 2; }
    int want = env == 2 ? g_settings.blur_removal : env;
    if (want != g_tilt_applied) {
        set_tilt_name(want);
        if (g_tilt_applied >= 0 || want) LOG("[qol] blur removal %s\n", want ? "on" : "off");
        g_tilt_applied = want;
    }
}
