// Golden unchecked pots (pots randomizer): pots whose hidden item hasn't been collected are drawn tinted gold.
//
// rando/<seed>/pots.tsv (written by tools/rando/pots.py) lists every item pot: level, x, y, z, flag index.
// The renderer asks pot_tint() for each draw whose shader supports the tint (runtime/nvn/maxwell/translate.c);
// a draw is a pot when its model matrix (vertex UBO 2, 3x4 row-major) is unscaled and sits exactly on a pot
// of the current level. The pot stays gold until its item's GlobalFlags bit is set.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0
#define EVENT_FLAGS (MAIN_BASE + 0x1CBB220 + 0x5DC0)  // live save: GlobalFlags bitfield (2048 bits)

typedef struct { char level[40]; float x, y, z; int flag; } Pot;
static Pot *g_pots;
static int g_npots = -1;

static void load(void) {
    g_npots = 0;
    const char *dir = rando_seed_dir();
    if (!dir) return;
    char path[512];
    snprintf(path, sizeof path, "%s/pots.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return;
    int cap = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        Pot p;
        if (sscanf(line, "%39s %f %f %f %d", p.level, &p.x, &p.y, &p.z, &p.flag) != 5) continue;
        if (g_npots == cap) g_pots = realloc(g_pots, sizeof(Pot) * (cap = cap ? cap * 2 : 256));
        g_pots[g_npots++] = p;
    }
    fclose(f);
    LOG("[pots] %d item pots from %s\n", g_npots, path);
}

static const char *current_level(void) {
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    return ps ? (const char *)(uintptr_t)ps : "";
}

// Tint: rgb = mix(rgb, t0.rgb * lum^t1.w + t1.rgb * lum, t0.w)  (runtime/nvn/maxwell/translate.c).
// m: the draw's model matrix (3x4 row-major). Fills tint (float4[2]) and returns true for an unchecked pot.
// Pots of the current level, rebuilt once per presented frame (draws only scan these).
static int g_lv_idx[512], g_nlv = 0;
static uint64_t g_lv_frame = ~0ull;
static void level_pots(void) {
    extern uint64_t renderer_present_count(void);
    uint64_t f = renderer_present_count();
    if (f == g_lv_frame) return;
    g_lv_frame = f;
    g_nlv = 0;
    const char *lv = current_level();
    for (int i = 0; i < g_npots && g_nlv < 512; i++)
        if (!strcmp(g_pots[i].level, lv)) g_lv_idx[g_nlv++] = i;
    if (getenv("LARECOMP_LOG_POTS") && f % 120 == 0) LOG("[pots] frame %llu level '%s': %d item pots\n", (unsigned long long)f, lv, g_nlv);
}

// Cheap per-draw gate for the renderer: false when no item pot can be on screen.
bool pot_glow_active(void) {
    if (g_npots < 0) load();
    if (!g_npots) return false;
    level_pots();
    return g_nlv > 0;
}

// Carried pots: a gold pot that Link lifts leaves its spot, so it's followed from frame to frame: an unscaled
// draw (rotation allowed) within a short step of where a tracked gold pot was drawn in the last couple of frames
// with the same mesh (vertex buffer) is that pot. Pots stand a tile apart, so a step this small can't jump to a
// neighbour, and the mesh check keeps other draws (full-screen passes, Link) out.
typedef struct { int pot; float x, y, z; uint64_t seen, mesh; } Track;
static Track g_track[8];

static bool unchecked(const Pot *p) { return !(LD8(EVENT_FLAGS + (p->flag >> 3)) & (1 << (p->flag & 7))); }

static void track(int pot, float x, float y, float z, uint64_t f, uint64_t mesh) {
    int slot = 0;
    for (int i = 0; i < 8; i++) {
        if (g_track[i].pot == pot && g_track[i].seen) { slot = i; break; }
        if (g_track[i].seen < g_track[slot].seen) slot = i;
    }
    g_track[slot] = (Track){pot, x, y, z, f, mesh};
}

bool pot_tint(const float *m, float tint[8], uint64_t mesh) {
    if (!pot_glow_active()) return false;
    extern uint64_t renderer_present_count(void);
    uint64_t now = renderer_present_count();
    // unit scale on every axis (the hidden item inside is scaled down)
    float sx = m[0] * m[0] + m[4] * m[4] + m[8] * m[8], sy = m[1] * m[1] + m[5] * m[5] + m[9] * m[9],
          sz = m[2] * m[2] + m[6] * m[6] + m[10] * m[10];
    if (fabsf(sx - 1) > 0.02f || fabsf(sy - 1) > 0.02f || fabsf(sz - 1) > 0.02f) return false;
    bool upright = fabsf(m[0] - 1) <= 0.01f && fabsf(m[5] - 1) <= 0.01f && fabsf(m[10] - 1) <= 0.01f;
    float x = m[3], y = m[7], z = m[11];
    const Pot *hit = NULL;
    for (int k = 0; k < g_nlv && upright; k++) {  // standing on its spot: pots are placed without rotation
        const Pot *p = &g_pots[g_lv_idx[k]];
        if (fabsf(p->x - x) > 0.02f || fabsf(p->z - z) > 0.02f || fabsf(p->y - y) > 0.05f) continue;
        if (!unchecked(p)) return false;  // already checked
        hit = p;
        track(g_lv_idx[k], x, y, z, now, mesh);
        break;
    }
    for (int i = 0; i < 8 && !hit; i++) {  // being carried / thrown
        Track *t = &g_track[i];
        if (!t->seen || now - t->seen > 2 || !mesh || t->mesh != mesh || !unchecked(&g_pots[t->pot])) continue;
        if (strcmp(g_pots[t->pot].level, current_level())) { t->seen = 0; continue; }
        float dx = t->x - x, dy = t->y - y, dz = t->z - z;
        if (dx * dx + dy * dy + dz * dz > 0.25f * 0.25f) continue;
        hit = &g_pots[t->pot];
        t->x = x; t->y = y; t->z = z; t->seen = now;
    }
    if (hit) {
        float t = (float)now / 60.0f;
        float pulse = 0.5f + 0.5f * sinf(t * 2.5f);
        // gold = luminance remapped onto a gold ramp (keeps the pot's shading), plus a slow shimmer
        // (colour target is linear HDR: lum ~0.05-0.3 on a pot, so the curve lifts it)
        static float v[7] = {1.85f, 1.06f, 0.09f, 1.0f, 0.50f, 0.34f, 0.03f};  // warm gold (tuned 2026-10-08)
        static int env = -1;  // LARECOMP_POT_TINT=r,g,b,mix,pulse_r,pulse_g,pulse_b (tuning)
        if (env < 0) {
            env = 0;
            const char *e = getenv("LARECOMP_POT_TINT");
            if (e) sscanf(e, "%f,%f,%f,%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6]);
        }
        tint[0] = v[0]; tint[1] = v[1]; tint[2] = v[2]; tint[3] = v[3];
        tint[4] = v[4] * pulse; tint[5] = v[5] * pulse; tint[6] = v[6] * pulse; tint[7] = 0.8f;
        return true;
    }
    return false;
}

// True when the current level has item pots: their hidden item actors' 2D twinkle is drawn at a bogus spot
// (it projects a bone the swapped-in item models don't have), so the renderer drops it in these levels.
bool pot_level_active(void) {
    if (g_npots < 0) load();
    if (!g_npots) return false;
    static uint64_t frame = ~0ull;
    static bool active;
    extern uint64_t renderer_present_count(void);
    if (renderer_present_count() == frame) return active;
    frame = renderer_present_count();
    level_pots();
    active = g_nlv > 0;
    return active;
}
