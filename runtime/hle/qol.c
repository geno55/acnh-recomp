// Quality-of-life options re-implemented from community GameBanana mods (credits in README.md; none of their files
// are used): 360-degree movement and blur removal ("360 Controls (And More!)"). Button prompts are
// runtime/nvn/texpatch.c, the Hero Mode icon is hidden there too.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"
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

// No Guardian Acorns / Pieces of Power (randomizer option no-buff-drops). Enemy kills count up two bytes of PlayerStatus
// (+0xa4, +0xa5, saturating at 255; shared death code main+0x7c6950). The drop roll main+0x89b960 takes the dropper's
// ItemDrop row; a row with mAllowBuffReplace (+0x38: NormalLow / NormalMid / RupeeMid...) first checks the
// kill counters in PlayerStatus (+0xa5 >= 14: "DefenceUp" = Guardian Acorn; +0xa4 past a threshold: "PowerUp" =
// Piece of Power; the counter is then wrapped) and drops that item symbol directly - the ItemDrop rows GuardianAcorn /
// PowerPiece (emptied by LAS-Randomizer item_drops.py) aren't involved, which is why the option alone didn't work.
// tools/patches.py BUFF_REPLACE_SITE reads the flag as false here: the counters are never consumed (they stay at 255) and
// the row's own lot table is rolled as usual. Anything else that would make one (ItemPowerPiece 0xb2 / ItemGuardianAcorn 0xb3) is
// held back at the actor factory (souls.c).
static int g_no_buff = -1;  // (per seed: read again after an in-place reboot)
static bool no_buff(void) {
    if (g_no_buff < 0) {
        g_no_buff = 0;
        const char *dir = rando_seed_dir();
        char p[512];
        if (dir) {
            snprintf(p, sizeof p, "%s/settings.json", dir);
            FILE *f = fopen(p, "rb");
            if (f) {
                static char buf[1 << 16];
                size_t n = fread(buf, 1, sizeof buf - 1, f);
                buf[n] = 0;
                fclose(f);
                g_no_buff = strstr(buf, "\"no-buff-drops\": true") != NULL;
            }
        }
        const char *e = getenv("LARECOMP_NO_BUFF");  // test: 1 / 0 forces it
        if (e) g_no_buff = atoi(e) != 0;
        LOG("[qol] no Guardian Acorns / Pieces of Power: %s\n", g_no_buff ? "ON" : "off");
    }
    return g_no_buff;
}
RT_ON_RESET(no_buff_reset) { g_no_buff = -1; }  // (seed switch)

int rt_buff_replace(int allow) {
    // LARECOMP_BUFF_PRIME=1 (test): every roll finds the Guardian Acorn counter full; =2: and every row allows buffs
    // (grass then drops Acorns unless the option is on)
    static int test = -1;
    if (test < 0) test = ENV("LARECOMP_BUFF_PRIME") ? atoi(ENV("LARECOMP_BUFF_PRIME")) : 0;
    if (test) {
        uint64_t ps = LD64(MAIN_BASE + 0x1CC1368);  // PlayerStatus*
        if (ps) ST8(ps + 0xa5, 14);
        if (test == 2) allow = 1;
        { extern uint64_t renderer_present_count(void); LOG("[qol] f%llu drop roll: buff replace %d -> %d\n", (unsigned long long)renderer_present_count(), allow, allow && !no_buff()); }
    }
    return allow && !no_buff();
}

bool rt_no_buff_actor(uint32_t type) {
    if ((type != 0xb2 && type != 0xb3) || !no_buff()) return false;
    LOG("[qol] %s held back (no-buff-drops)\n", type == 0xb2 ? "Piece of Power" : "Guardian Acorn");
    return true;
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

// LARECOMP_SETTING_AT="frame:key=value,..." (test): flip an in-game menu toggle at that presented frame, as the menu
// would (move_360, blur_removal, dpad_move).
static void setting_at_tick(void) {
    static const char *spec;
    static int init;
    static uint64_t last;
    if (!init) { init = 1; spec = getenv("LARECOMP_SETTING_AT"); }
    if (!spec) return;
    extern uint64_t renderer_present_count(void);
    uint64_t now = renderer_present_count();
    if (now == last) return;
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *save = NULL, *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        unsigned long f;
        char key[32];
        int v;
        if (sscanf(tok, "%lu:%31[a-z_0-9]=%d", &f, key, &v) != 3 || f <= last || f > now) continue;
        bool *b = !strcmp(key, "move_360") ? &g_settings.move_360 : !strcmp(key, "blur_removal") ? &g_settings.blur_removal :
                  !strcmp(key, "dpad_move") ? &g_settings.dpad_move : NULL;
        if (b) { *b = v != 0; LOG("[qol] test: f%llu %s = %d\n", (unsigned long long)now, key, v); }
    }
    last = now;
}

// Game thread, once per frame (runtime/hle/input.c) and at boot (before the post-process is set up).
void qol_tick(void) {
    setting_at_tick();
    static int env = -1;  // LARECOMP_BLUR_REMOVAL=0/1: test override
    if (env < 0) { const char *e = getenv("LARECOMP_BLUR_REMOVAL"); env = e ? atoi(e) != 0 : 2; }
    int want = env == 2 ? g_settings.blur_removal : env;
    if (want != g_tilt_applied) {
        set_tilt_name(want);
        if (g_tilt_applied >= 0 || want) LOG("[qol] blur removal %s\n", want ? "on" : "off");
        g_tilt_applied = want;
    }
}
