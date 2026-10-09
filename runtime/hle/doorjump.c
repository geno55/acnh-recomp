// Generated dungeons: doorways that don't line up across a room edge (Face Shrine 05A's one-tile opening next to
// Catfish's Maw 07E's two-tile one, half a tile apart). Walls are part of the room models, so Link stops in his
// doorway against the neighbour's wall. When he walks into such a doorway, he is moved just past the room edge in
// front of the partner doorway; the game sees him in the next room and plays its normal scroll.
//
// rando/<seed>/door_jumps.tsv (tools/rando/dungeon_gen.py): level, cell (e.g. 08C), side (N/S/W/E), doorway centre
// on that side and the partner's centre on the facing side, in half tiles (x 0.75 units) from the cell's corner.
// Optional (Chaos dungeon room shuffle): target cell and target side - Link comes out of that room's doorway on that
// side (any room of the level); without them, the neighbour across the edge, facing side.
//
// Link's position: the "PlayerCollision" component (vtable main+0x1c501f0, name inline at +0x18), vec3 at +0x80
// (a second copy at +0xb0); writing it moves Link, every other copy follows (found 2026-10-08 with
// LARECOMP_ADDF_MATCH bisection, notes/PLAN.md). It's re-found by a heap scan after each level load.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0
#define PLAYER_COLLISION_VT (MAIN_BASE + 0x1c501f0)

typedef struct { char level[40]; int col, row; char side; int own, partner, still; int tcol, trow; char tside; } Jump;
static Jump *g_jumps;
static int g_njumps = -1;

static void load(void) {
    g_njumps = 0;
    const char *dir = rando_seed_dir();
    if (!dir) return;
    char path[512];
    snprintf(path, sizeof path, "%s/door_jumps.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    int cap = 0;
    while (fgets(line, sizeof line, f)) {
        Jump j;
        char cell[8], side[4], tcell[8], tside[4];
        int n = sscanf(line, "%39s %7s %3s %d %d %7s %3s", j.level, cell, side, &j.own, &j.partner, tcell, tside);
        if (n != 5 && n != 7) continue;
        j.row = atoi(cell);  // "08C" -> row 8, column C
        j.col = cell[2] - 'A';
        j.side = side[0];
        if (n == 7) {
            j.trow = atoi(tcell), j.tcol = tcell[2] - 'A', j.tside = tside[0];
        } else {  // the neighbour across the edge, its facing side
            j.trow = j.row + (j.side == 'N' ? -1 : j.side == 'S' ? 1 : 0);
            j.tcol = j.col + (j.side == 'W' ? -1 : j.side == 'E' ? 1 : 0);
            j.tside = j.side == 'N' ? 'S' : j.side == 'S' ? 'N' : j.side == 'W' ? 'E' : 'W';
        }
        j.still = 0;
        if (g_njumps == cap) g_jumps = realloc(g_jumps, sizeof(Jump) * (cap = cap ? cap * 2 : 64));
        g_jumps[g_njumps++] = j;
    }
    fclose(f);
    LOG("[doorjump] %d mismatched doorways from %s\n", g_njumps, path);
}

static int is_player_collision(uint64_t p) {
    return LD64(p) == PLAYER_COLLISION_VT && LD64(p + 8) == p &&
           !memcmp((const void *)(uintptr_t)(p + 0x18), "PlayerCollision", 16);
}

// The component lives on the heap (16-byte aligned); scan for it after each level change (the previous level's
// player can stay in freed memory looking valid) and when the cached pointer goes stale. Several candidates:
// log them all (LARECOMP_DOORJUMP_LOG) and take the last one found (newest allocation is the live one - checked).
static uint64_t find_player(uint64_t frame) {
    static uint64_t cached, last_scan;
    static char level[64];
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    const char *lv = ps ? (const char *)(uintptr_t)ps : "";
    if (strncmp(level, lv, sizeof level - 1)) {  // new level: rescan once it has settled
        strlcpy(level, lv, sizeof level);
        cached = 0;
        last_scan = frame;
        return 0;
    }
    if (cached && is_player_collision(cached)) return cached;
    cached = 0;
    if (frame - last_scan < 30) return 0;
    last_scan = frame;
    extern int kernel_data_regions(uint64_t *addr, uint64_t *size, int max);
    uint64_t ra[64], rs[64];
    int nr = kernel_data_regions(ra, rs, 64), n = 0;
    for (int r = 0; r < nr; r++)
        for (uint64_t k = 0; k + 0x100 <= rs[r]; k += 16)
            if (LD64(ra[r] + k) == PLAYER_COLLISION_VT && is_player_collision(ra[r] + k)) {
                const float *p = (const float *)(uintptr_t)(ra[r] + k + 0x80);
                if (ENV("LARECOMP_DOORJUMP_LOG"))
                    LOG("[doorjump] candidate %llx (%.2f, %.2f, %.2f) parent %llx\n", (unsigned long long)(ra[r] + k),
                        p[0], p[1], p[2], (unsigned long long)LD64(ra[r] + k + 0x10));
                cached = ra[r] + k;
                n++;
            }
    LOG("[doorjump] %s: PlayerCollision %s %llx (%d candidates)\n", lv, cached ? "at" : "not found",
        (unsigned long long)cached, n);
    return cached;
}

// LARECOMP_DOORJUMP_TEST=<frame>:<cell>:<side> (test): from <frame> on, once the level with jumps has been loaded
// for 60 frames (warp into the cell first, LARECOMP_WARP_AT), put Link 1.2 inside that doorway; the test holds the
// stick outward (tools/doorjump_test.sh, LARECOMP_INPUT); 300 frames later log the cell he is in
uint64_t g_stick_freeze_until;
static int g_jumps_fired;  // (test result: a jump that fired and then he ended elsewhere = pushed back by an enemy)  // runtime/hle/input.c releases the stick until this frame
int32_t g_test_lx, g_test_ly;  // stick held by the test (runtime/hle/input.c)
uint64_t g_test_stick_until;

static void test_tick(uint64_t frame, uint64_t pc, const char *lv) {
    static long at = -2, placed = -1;
    static char cell[8], side;
    static int er = -1, ec = -1;  // expected cell (the tested jump's target)
    static uint64_t in_level_since;
    static int was_in;
    if (at == -2) {
        at = -1;
        const char *e = ENV("LARECOMP_DOORJUMP_TEST");
        char sd[4];
        if (e && sscanf(e, "%ld:%7[^:]:%3s", &at, cell, sd) == 3) side = sd[0]; else at = -1;
    }
    if (at < 0 || !pc) return;
    // wait until the warp into the dungeon has finished: in a level with jumps, settled for 60 frames
    int in = 0;
    for (int i = 0; i < g_njumps && !in; i++) in = !strcmp(g_jumps[i].level, lv);
    if (in && !was_in) in_level_since = frame;
    was_in = in;
    float *pos = (float *)(uintptr_t)(pc + 0x80), *pos2 = (float *)(uintptr_t)(pc + 0xb0);
    int row = atoi(cell), col = cell[2] - 'A';
    if (placed < 0 && (long)frame >= at && in && frame - in_level_since >= 300) {  // (5 s: under load the dungeon entry walk-in still runs after 1 s and overwrites the placement)
        for (int i = 0; i < g_njumps; i++) {
            const Jump *j = &g_jumps[i];
            if (j->row != row || j->col != col || j->side != side) continue;
            float x0 = 15.0f * col, z0 = 12.0f * (row - 1), x = 0, z = 0;
            switch (side) {
            case 'W': x = x0 + 1.2f; z = z0 + j->own * 0.75f; break;
            case 'E': x = x0 + 15.0f - 1.2f; z = z0 + j->own * 0.75f; break;
            case 'N': z = z0 + 1.2f; x = x0 + j->own * 0.75f; break;
            default: z = z0 + 12.0f - 1.2f; x = x0 + j->own * 0.75f; break;
            }
            pos[0] = pos2[0] = x;
            pos[2] = pos2[2] = z;
            er = j->trow, ec = j->tcol;
            g_test_lx = side == 'W' ? -32767 : side == 'E' ? 32767 : 0;  // walk out
            g_test_ly = side == 'N' ? 32767 : side == 'S' ? -32767 : 0;
            g_test_stick_until = frame + 180;  // cut to 40 frames after the jump (doorjump_tick)
            LOG("[doorjump-test] f%llu placed at (%.2f, %.2f) in %s %c\n", (unsigned long long)frame, x, z, cell, side);
        }
        placed = (long)frame;
    } else if (placed >= 0 && (long)frame == placed + 300) {
        float x = pos[0], z = pos[2];
        int c = (int)floorf(x / 15.0f), r = (int)floorf(z / 12.0f) + 1;
        LOG("[doorjump-test] %s %c -> now in %02d%c (%.2f, %.2f), expected %02d%c: %s (%d jumps fired)\n", cell, side, r,
            'A' + c, x, z, er, 'A' + ec, (r == er && c == ec) ? "PASS" : g_jumps_fired ? "FAIL-after-jump" : "FAIL",
            g_jumps_fired);
        at = -1;
    }
}

uint64_t g_test_buttons, g_test_buttons_until;

// LARECOMP_PLACE=<frame>:<x>:<z>[:<script>] (test): put Link at x, z (any level) once the level has been loaded 60
// frames, then run <script> relative to that moment: steps "<delay>:<L|R|U|D|A|B>:<frames>" separated by '/', e.g.
// "10:L:8/40:A:6/90:A:6/130:L:30" = face west, lift, throw, walk west (pot tests)
static long trace_until = -1;  // LARECOMP_DOORJUMP_TRACE: Link's position for 90 frames after each jump / placement

static void place_tick(uint64_t frame) {
    static long at = -2, done, placed_at = -1;
    static char script[256];
    static float px, pz;
    static uint64_t since;
    static char level[64];
    if (at == -2) {
        at = -1;
        const char *e = getenv("LARECOMP_PLACE");
        if (e && sscanf(e, "%ld:%f:%f:%255s", &at, &px, &pz, script) < 3) at = -1;
    }
    if (placed_at >= 0 && script[0]) {  // action script
        long t = (long)frame - placed_at;
        char buf[256];
        strlcpy(buf, script, sizeof buf);
        for (char *st = strtok(buf, "/"); st; st = strtok(NULL, "/")) {
            long d, n;
            char k;
            if (sscanf(st, "%ld:%c:%ld", &d, &k, &n) != 3 || t != d) continue;
            extern int32_t g_test_lx, g_test_ly;
            extern uint64_t g_test_stick_until;
            if (strchr("LRUD", k)) {
                g_test_lx = k == 'L' ? -32767 : k == 'R' ? 32767 : 0;
                g_test_ly = k == 'U' ? 32767 : k == 'D' ? -32767 : 0;
                g_test_stick_until = frame + n;
            } else {
                g_test_buttons = k == 'A' ? 1 : 2;  // bit 0 A, bit 1 B
                g_test_buttons_until = frame + n;
            }
            LOG("[place] f%llu script %c for %ld\n", (unsigned long long)frame, k, n);
        }
    }
    if (at < 0 || done || (long)frame < at) return;
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    const char *lv = ps ? (const char *)(uintptr_t)ps : "";
    if (strncmp(level, lv, sizeof level - 1)) { strlcpy(level, lv, sizeof level); since = frame; return; }
    if (frame - since < 60) return;
    uint64_t pc = find_player(frame);
    if (!pc) return;
    float *pos = (float *)(uintptr_t)(pc + 0x80), *pos2 = (float *)(uintptr_t)(pc + 0xb0);
    pos[0] = pos2[0] = px;
    pos[2] = pos2[2] = pz;
    LOG("[place] f%llu Link -> (%.2f, %.2f) in %s\n", (unsigned long long)frame, px, pz, lv);
    done = 1;
    placed_at = (long)frame;
    if (ENV("LARECOMP_DOORJUMP_TRACE")) trace_until = (long)frame + 240;
}

void doorjump_tick(uint64_t frame) {
    place_tick(frame);
    if (g_njumps < 0) load();
    if ((long)frame <= trace_until && !g_njumps) {  // (trace without a jump table: vanilla tests)
        uint64_t pc0 = find_player(frame);
        if (pc0) {
            float *p0 = (float *)(uintptr_t)(pc0 + 0x80);
            LOG("[doorjump-trace] f%llu (%.2f, %.2f, %.2f)\n", (unsigned long long)frame, p0[0], p0[1], p0[2]);
        }
    }
    if (!g_njumps) return;
    if (ENV("LARECOMP_DOORJUMP_TEST")) {
        uint64_t ps0 = LD64(PLAYER_STATUS_PTR);
        if (ps0) test_tick(frame, find_player(frame), (const char *)(uintptr_t)ps0);
    }
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    const char *lv = ps ? (const char *)(uintptr_t)ps : "";
    int any = 0;
    for (int i = 0; i < g_njumps && !any; i++) any = !strcmp(g_jumps[i].level, lv);
    if (!any) return;
    uint64_t pc = find_player(frame);
    if (!pc) return;
    float *pos = (float *)(uintptr_t)(pc + 0x80), *pos2 = (float *)(uintptr_t)(pc + 0xb0);
    float x = pos[0], z = pos[2];
    if ((long)frame <= trace_until) {
        LOG("[doorjump-trace] f%llu (%.2f, %.2f, %.2f)\n", (unsigned long long)frame, x, pos[1], z);
        if (ENV("LARECOMP_DOORJUMP_DUMP")) {  // every float of the PlayerCollision object that looks like x or z
            const float *o = (const float *)(uintptr_t)pc;
            for (int k = 0; k < 0x400 / 4; k++)
                if ((fabsf(o[k] - x) < 0.6f || fabsf(o[k] - z) < 0.6f) && fabsf(o[k]) > 1.0f)
                    LOG("[doorjump-dump]   +%#x = %.3f\n", k * 4, o[k]);
        }
    }
    static float px, pz;  // last frame (only moving INTO a doorway jumps)
    float dx = x - px, dz = z - pz;
    px = x, pz = z;
    int col = (int)floorf(x / 15.0f), row = (int)floorf(z / 12.0f) + 1;
    float lx = x - 15.0f * col, lz = z - 12.0f * (row - 1);
    for (int i = 0; i < g_njumps; i++) {
        Jump *j = &g_jumps[i];
        if (j->col != col || j->row != row || strcmp(j->level, lv)) continue;
        float depth, lateral, out;  // distance to the edge, position along it, movement towards it
        switch (j->side) {
        case 'W': depth = lx; lateral = lz; out = -dx; break;
        case 'E': depth = 15.0f - lx; lateral = lz; out = dx; break;
        case 'N': depth = lz; lateral = lx; out = -dz; break;
        default: depth = 12.0f - lz; lateral = lx; out = dz; break;
        }
        if (ENV("LARECOMP_DOORJUMP_LOG") && depth < 1.5f)
            LOG("[doorjump] f%llu %c depth %.3f lateral %.3f out %.4f still %d\n", (unsigned long long)frame, j->side, depth, lateral, out, j->still);
        // (pressed against the wall he bounces between two positions each frame, ~0.3 from the edge)
        if (depth > 0.7f || fabsf(lateral - j->own * 0.75f) > 1.2f) { j->still = 0; continue; }  // per doorway: a cell's other doorways mustn't reset it
        if (depth > 0.55f) continue;
        if (!j->still && out <= 0.01f) continue;  // armed only by walking in (not by landing here)
        // in the doorway's last half tile: release the stick for a moment (moving him while he walks gets undone by
        // that frame's movement, and where the neighbour has no wall he'd walk on into its void), jump at rest
        g_stick_freeze_until = frame + 3;
        ++j->still;
        // jump only after ~0.4 s at rest: while Link is in the game's push-against-a-wall state (it outlasts the
        // push) position writes are undone (Angler's 03G -> 02G: 12 frames failed, 20 passed). LARECOMP_DJ_REST: frames
        static int rest = -1;
        if (rest < 0) rest = getenv("LARECOMP_DJ_REST") ? atoi(getenv("LARECOMP_DJ_REST")) : 24;
        if (j->still < rest || (fabsf(out) > 0.02f && j->still < rest + 8)) continue;
        j->still = 0;
        float nx = x, nz = z, across = 0.9f;  // just past the edge, in front of the partner doorway
        // just inside the target room's doorway on its side (for a neighbour: just past the shared edge)
        float tx0 = 15.0f * j->tcol, tz0 = 12.0f * (j->trow - 1);
        switch (j->tside) {
        case 'E': nx = tx0 + 15.0f - across; nz = tz0 + j->partner * 0.75f; break;
        case 'W': nx = tx0 + across; nz = tz0 + j->partner * 0.75f; break;
        case 'S': nz = tz0 + 12.0f - across; nx = tx0 + j->partner * 0.75f; break;
        default: nz = tz0 + across; nx = tx0 + j->partner * 0.75f; break;
        }
        LOG("[doorjump] %s %02d%c %c: (%.2f, %.2f) -> %02d%c %c (%.2f, %.2f)\n", lv, row, 'A' + col, j->side, x, z,
            j->trow, 'A' + j->tcol, j->tside, nx, nz);
        pos[0] = pos2[0] = nx;
        pos[2] = pos2[2] = nz;
        px = nx, pz = nz;
        g_jumps_fired++;
        if (ENV("LARECOMP_DOORJUMP_TRACE")) trace_until = (long)frame + 90;
        if (g_test_stick_until > frame + 40) g_test_stick_until = frame + 40;  // (test: walk on a little, then stop)
        break;
    }
}
