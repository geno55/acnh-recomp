// Digsanity: every diggable tile of the overworld is a check, and dug holes stay open for good.
//
// The Field is 16 x 16 screens of 15 x 12 units; each screen's .leb grid has 10 x 8 tiles of 1.5 units, and the
// shovel snaps its hole to a tile centre (f_7000ddafc0). Tile ids: g = ((row - 1) * 16 + column) * 80 + tile, and
// tile g is dug once event flag DIG_FLAG_BASE + g is set (the flag bitfield is extended to 24576 flags and kept in
// the save's sidecar: runtime/hle/flags_ext.c).
//
// rando/<seed>/digs.tsv (tools/rando/digs.py) lists every dig tile: screen, tile, ground height, item name, and the
// item's give program (what LAS's flow would do: AddItem / SetFlag / progressive switch / trade item), "-" for none.
//
// Dig: the patch after the hole's spawn in the shovel's dig commit (tools/patches.py DIG_HOLE_SITE) calls
// rt_dig_hole: the first dig of a tile sets its flag and queues its item (given on the next game-thread tick).
// Holes: the game fills in its oldest holes beyond 80 (f_7000d22d10); with digsanity the limit is HOLE_CAP
// (tools/patches.py HOLE_CAP_SITES). ObjHolesDug actors (type 0x1cd) belong to the Field's loaded scene and are gone
// once Link leaves the Field. Every few frames the screens around Link are checked: a dug tile without a live hole
// gets one spawned the way the shovel does (f_7000d228d0). Holes are tracked by a weak reference to their shared_ptr control block
// (libc++: shared count at +8 is -1 once the actor is gone; the block stays while we hold the weak count).
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../hle.h"
#include "../rando.h"

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0
#define GAME_MGR (MAIN_BASE + 0x1C97188)           // +0x4a8: the current scene (weak), scene +0x228 -> +0x1b8 room sp
#define SCENE_LOCK (MAIN_BASE + 0x1b730)           // (out shared_ptr, scene handle): what the dig commit calls
#define SPAWN_HOLE (MAIN_BASE + 0xd228d0)          // (out, transform, zone, &room, w4, s0): ObjHolesDug
#define HOLE_LIST_INIT (MAIN_BASE + 0xd22860)      // first-use init of the game's hole list (the shovel calls it first)
#define SP_RELEASE (MAIN_BASE + 0xbae080)          // shared_ptr release (x0 = control block)
#define WEAK_RELEASE (MAIN_BASE + 0x14311f0)       // std::__shared_weak_count::__release_weak
#define ADD_ITEM (MAIN_BASE + 0x7e18b0)            // AddItem(itemId, count, index, autoEquip)
#define LIVE_SAVE (MAIN_BASE + 0x1CBB220)
#define DIG_FLAG_BASE 4096
#define NTILES (256 * 80)
#define HOLE_CAP 600  // holes alive at once (all within the Field; the 3 x 3 screens around Link hold at most 720)

bool flags_ext_get(int idx);
void flags_ext_set(int idx);
void flags_ext_clear(int idx);
uint64_t doorjump_player(uint64_t frame);
extern void ui_toast(const char *text);

typedef struct { bool dig, hole; float y; char *name, *ops; } Tile;  // hole: reopen it (no plant grows there)
static Tile *g_tiles;       // NTILES
static int g_on = -1;
static uint64_t g_alive[NTILES];  // control block of the tile's hole (weak ref held), 0 = none known
static uint32_t g_zone = 1;       // zone id the shovel passes (1 on the Field; refreshed by every real dig)
static int g_queue[64], g_nq;     // dug tiles whose item is still to be given
static FILE *g_test_out;          // (dig test: LARECOMP_DIG_TEST)
static uint8_t g_spawns[NTILES];  // holes reopened per tile since the Field loaded (3 that didn't stay: give up)

static bool enabled(void) {
    if (g_on >= 0) return g_on;
    g_on = 0;
    const char *dir = rando_seed_dir();
    if (!dir && ENV("LARECOMP_DIG_TEST")) { g_tiles = calloc(NTILES, sizeof(Tile)); return g_on = 1; }  // (no items)
    if (!dir) return false;
    char path[512];
    snprintf(path, sizeof path, "%s/digs.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return false;
    g_tiles = calloc(NTILES, sizeof(Tile));
    char line[512];
    int n = 0, items = 0;
    while (fgets(line, sizeof line, f)) {
        char scr[8], name[128], ops[256], blocker[16] = "-";
        int tile;
        float y;
        if (line[0] == '#' || sscanf(line, "%7s %d %f %127[^\t] %255s %15s", scr, &tile, &y, name, ops, blocker) < 5)
            continue;
        int row = atoi(scr), col = scr[2] - 'A';
        if (row < 1 || row > 16 || col < 0 || col > 15 || tile < 0 || tile >= 80) continue;
        Tile *t = &g_tiles[((row - 1) * 16 + col) * 80 + tile];
        t->dig = true, t->y = y;
        t->hole = strcmp(blocker, "grass") && strcmp(blocker, "bush");
        if (strcmp(ops, "-")) { t->name = strdup(name); t->ops = strdup(ops); items++; }
        n++;
    }
    fclose(f);
    g_on = n > 0;
    LOG("[digs] %d dig tiles, %d with items (%s)\n", n, items, path);
    return g_on;
}

uint64_t rt_hole_cap(void) { return enabled() ? HOLE_CAP : 0x51; }

static bool on_field(void) {
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    return ps && !strcmp((const char *)(uintptr_t)ps, "Field");
}

static int tile_at(float x, float z) {
    int col = (int)floorf(x / 15.0f), row0 = (int)floorf(z / 12.0f);
    if (col < 0 || col > 15 || row0 < 0 || row0 > 15) return -1;
    int tx = (int)floorf((x - col * 15.0f) / 1.5f), tz = (int)floorf((z - row0 * 12.0f) / 1.5f);
    if (tx < 0 || tx > 9 || tz < 0 || tz > 7) return -1;
    return (row0 * 16 + col) * 80 + tz * 10 + tx;
}

static void hold_weak(int g, uint64_t ctrl) {
    if (!ctrl || g_alive[g] == ctrl) return;
    __atomic_fetch_add((int64_t *)(uintptr_t)(ctrl + 0x10), 1, __ATOMIC_ACQ_REL);
    g_alive[g] = ctrl;  // (callers drop an older ref of the tile first)
}

// shovel dig commit, right after the hole's spawn: [sp+0x10] the hole (actor, control block), x21 its transform
// (+0 position, +0x30 ground point on the tile centre), x20 +0xb0 the zone id
void rt_dig_hole(Cpu *c) {
    if (!enabled() || !on_field()) return;
    const float *t = (const float *)(uintptr_t)c->x[21];
    int g = tile_at(t[12], t[14]);
    if (g < 0) return;
    if (g_test_out) { fprintf(g_test_out, "DUG %d\n", g); fflush(g_test_out); }
    g_zone = LD32(c->x[20] + 0xb0);
    uint64_t ctrl = LD64(c->sp + 0x18);
    if (g_alive[g] && g_alive[g] != ctrl) {  // a dead hole's ref (replaced)
        uint64_t old = g_alive[g];
        g_alive[g] = 0;
        uint64_t saved[31], sp = c->sp;
        memcpy(saved, c->x, sizeof saved);
        c->x[0] = old;
        guest_call(c, WEAK_RELEASE);
        memcpy(c->x, saved, sizeof saved);
        c->sp = sp;
    }
    hold_weak(g, ctrl);
    if (flags_ext_get(DIG_FLAG_BASE + g)) return;
    flags_ext_set(DIG_FLAG_BASE + g);
    LOG("[digs] dug %02d%c tile %d (flag %d)%s%s\n", g / 80 / 16 + 1, 'A' + g / 80 % 16, g % 80, DIG_FLAG_BASE + g,
        g_tiles[g].ops ? ": " : "", g_tiles[g].ops ? g_tiles[g].name : "");
    if (g_tiles[g].ops && g_nq < 64) g_queue[g_nq++] = g;
}

static void add_item(Cpu *c, int id, int count, int index) {
    c->x[0] = (uint64_t)id; c->x[1] = (uint64_t)count; c->x[2] = (uint64_t)(int64_t)index; c->x[3] = 0;
    guest_call(c, ADD_ITEM);
}

// give program: ';'-separated  a:<id>:<count>:<index>  f:<flag>:<0|1>  p:<flag>:<id1>:<id2> (progressive: id2 once
// the flag is set, else id1 + set it)  w:<n> (trade item slot)
static void give(Cpu *c, int g) {
    const Tile *t = &g_tiles[g];
    char buf[256];
    strlcpy(buf, t->ops, sizeof buf);
    for (char *op = strtok(buf, ";"); op; op = strtok(NULL, ";")) {
        int a = 0, b = 0, d = 0;
        switch (op[0]) {
        case 'a':
            if (sscanf(op + 2, "%d:%d:%d", &a, &b, &d) == 3) add_item(c, a, b, d);
            break;
        case 'f':
            if (sscanf(op + 2, "%d:%d", &a, &b) == 2) { if (b) flags_ext_set(a); else flags_ext_clear(a); }
            break;
        case 'p':
            if (sscanf(op + 2, "%d:%d:%d", &a, &b, &d) == 3) {
                if (flags_ext_get(a)) add_item(c, d, 1, -1);
                else { flags_ext_set(a); add_item(c, b, 1, -1); }
            }
            break;
        case 'w':
            if (sscanf(op + 2, "%d", &a) == 1) *(uint8_t *)(uintptr_t)(LIVE_SAVE + 0x555A) = (uint8_t)a;
            break;
        }
    }
    char msg[160];
    snprintf(msg, sizeof msg, "Dug up: %s", t->name);
    ui_toast(msg);
    LOG("[digs] gave %s (%s)\n", t->name, t->ops);
}

static void spawn_hole(Cpu *c, int g) {
    static uint64_t scratch;
    if (!scratch) scratch = (uint64_t)(uintptr_t)hle_alloc(0x100);
    uint64_t mgr = LD64(GAME_MGR);
    if (!mgr) return;
    uint8_t *s = (uint8_t *)(uintptr_t)scratch;
    memset(s, 0, 0x100);
    guest_call(c, HOLE_LIST_INIT);
    c->x[0] = scratch + 0x20;  // scene shared_ptr
    c->x[1] = LD64(mgr + 0x4a8);
    guest_call(c, SCENE_LOCK);
    uint64_t scene = LD64(scratch + 0x20), sctrl = LD64(scratch + 0x28);
    uint64_t holder = scene ? LD64(scene + 0x228) : 0;
    if (holder && LD64(holder + 0x1b8)) {
        ST64(scratch + 0x10, LD64(holder + 0x1b8));  // room (ptr, control block): borrowed, as the shovel does
        ST64(scratch + 0x18, LD64(holder + 0x1c0));
        int row0 = g / 80 / 16, col = g / 80 % 16, tile = g % 80;
        float x = col * 15.0f + (tile % 10) * 1.5f + 0.75f, z = row0 * 12.0f + (tile / 10) * 1.5f + 0.75f;
        float y = g_tiles[g].y;
        float *tr = (float *)(s + 0x40);  // the shovel's transform: position, rotation, scale, ground point, normal
        tr[0] = x, tr[1] = y + 0.01f, tr[2] = z;
        tr[7] = 1.0f;
        tr[8] = tr[9] = tr[10] = 1.0f;
        tr[12] = x, tr[13] = y, tr[14] = z;
        tr[17] = 1.0f;
        c->x[0] = scratch;
        c->x[1] = scratch + 0x40;
        c->x[2] = g_zone;
        c->x[3] = scratch + 0x10;
        c->x[4] = 0;
        float one = 1.0f;
        c->v[0] = 0;
        memcpy(&c->v[0], &one, 4);
        guest_call(c, SPAWN_HOLE);
        uint64_t hctrl = LD64(scratch + 8);
        if (LD64(scratch) && hctrl) {
            hold_weak(g, hctrl);
            c->x[0] = hctrl;
            guest_call(c, SP_RELEASE);
        }
    }
    if (sctrl) { c->x[0] = sctrl; guest_call(c, SP_RELEASE); }
}

static bool hole_alive(int g) { return g_alive[g] && (int64_t)LD64(g_alive[g] + 8) >= 0; }

// LARECOMP_DIG_TEST=<frame>:<list>[:<first>:<count>] (test): from <frame> on (shovel on Y, sword on B), digs every
// tile of <list> (tools/rando/digs.py --test-list: tile id, C = cut grass / a bush first, nearest Field locator, then
// the walkable neighbours Link can dig it from as x,z,direction). The test warps to the locator when it changes, puts
// Link on a stand tile, turns him toward the tile, cuts (B) when needed and digs (Y); no hole -> the next stand.
// Every hole dug is logged ("DUG <tile>", runtime/hle/digs.c rt_dig_hole) to build/digtest[_<SHOT_ID>].txt, then
// "OK <tile>" / "MISS <tile>" per list entry: the DUG lines are the tiles proven diggable.
static void dig_test(uint64_t frame) {
    enum { MAXS = 4 };
    typedef struct { int g, ns; char cut; char warp[40]; float x[MAXS], z[MAXS]; char dir[MAXS]; } Entry;
    static int state = -1, n, cur, stand, first, count, prev_screen = -1;
    static Entry *list;
    static long at;
    static uint64_t t0, warp_at;
    static char warped[40];
    if (state == -1) {
        state = -2;
        const char *e = ENV("LARECOMP_DIG_TEST");
        char path[256];
        first = 0, count = 1 << 30;
        if (!e || sscanf(e, "%ld:%255[^:]:%d:%d", &at, path, &first, &count) < 2) return;
        FILE *f = fopen(path, "r");
        if (!f) return;
        char line[512];
        list = calloc(8192, sizeof *list);
        for (int i = 0; fgets(line, sizeof line, f) && n < 8192; i++) {
            if (i < first || i >= first + count) continue;
            Entry *en = &list[n];
            char cut[4], *tok, *save = NULL;
            if (sscanf(line, "%d %3s %39s", &en->g, cut, en->warp) != 3) continue;
            en->cut = cut[0] == 'C';
            strtok_r(line, " \n", &save), strtok_r(NULL, " \n", &save), strtok_r(NULL, " \n", &save);
            while ((tok = strtok_r(NULL, " \n", &save)) && en->ns < MAXS) {
                char d;
                if (sscanf(tok, "%f,%f,%c", &en->x[en->ns], &en->z[en->ns], &d) == 3) en->dir[en->ns++] = d;
            }
            n++;
        }
        fclose(f);
        char op[256];
        snprintf(op, sizeof op, "build/digtest%s%s.txt", ENV("SHOT_ID") ? "_" : "", ENV("SHOT_ID") ? ENV("SHOT_ID") : "");
        g_test_out = fopen(op, "w");
        state = 0;
        LOG("[digtest] %d tiles -> %s\n", n, op);
    }
    if (state < 0 || (long)frame < at) return;
    while (cur < n && (!list[cur].ns || flags_ext_get(DIG_FLAG_BASE + list[cur].g))) {  // nowhere to stand / dug
        fprintf(g_test_out, "%s %d\n", list[cur].ns ? "OK" : "NOSTAND", list[cur].g);
        cur++, stand = 0;
    }
    if (cur >= n) {
        LOG("[digtest] done\n");
        if (g_test_out) fclose(g_test_out);
        g_test_out = NULL;
        _exit(0);
    }
    const Entry *en = &list[cur];
    if (strcmp(warped, en->warp)) {  // far away: warp to the nearest locator first
        extern void warp_request(const char *level, const char *locator);
        warp_request("Field", en->warp);
        strlcpy(warped, en->warp, sizeof warped);
        warp_at = frame;
        prev_screen = -1;
        state = 0;
        return;
    }
    if (frame < warp_at + 200 || !on_field()) return;
    if (frame == warp_at + 200) { void doorjump_player_rescan(void); doorjump_player_rescan(); }
    uint64_t pc = doorjump_player(frame);
    if (!pc) return;
    float *pos = (float *)(uintptr_t)(pc + 0x80), *pos2 = (float *)(uintptr_t)(pc + 0xb0);
    extern int32_t g_test_lx, g_test_ly;
    extern uint64_t g_test_stick_until, g_test_buttons, g_test_buttons_until;
    if (state == 0) { t0 = frame; state = 1; }
    long t = (long)(frame - t0), settle = en->g / 80 != prev_screen ? 90 : 12, dig = settle + (en->cut ? 40 : 6);
    if (t <= settle) {  // hold Link on the stand tile while the area streams in, then turn him
        pos[0] = pos2[0] = en->x[stand];
        pos[2] = pos2[2] = en->z[stand];
        if (t == settle) {
            char d = en->dir[stand];
            g_test_lx = d == 'W' ? -32767 : d == 'E' ? 32767 : 0;
            g_test_ly = d == 'N' ? 32767 : d == 'S' ? -32767 : 0;
            g_test_stick_until = frame + 2;
        }
    } else if (en->cut && t == settle + 6) {  // cut the grass / bush (sword)
        g_test_buttons = 2;
        g_test_buttons_until = frame + 6;
    } else if (t == dig) {
        g_test_buttons = 8;  // Y: shovel
        g_test_buttons_until = frame + 6;
    } else if (t >= dig + 40) {
        prev_screen = en->g / 80;
        state = 0;
        if (flags_ext_get(DIG_FLAG_BASE + en->g)) return;  // (the loop above reports it)
        if (++stand < en->ns && stand < 2) return;  // (two stands: a third rarely helps)
        fprintf(g_test_out, "MISS %d\n", en->g);
        fflush(g_test_out);
        cur++, stand = 0;
    }
}

// game main thread, once per frame (runtime/hle/input.c)
void digs_game_tick(Cpu *c, uint64_t frame) {
    if (!enabled()) return;
    extern int game_in_play(void);
    if (!game_in_play()) return;
    dig_test(frame);
    uint64_t saved[31], sp = c->sp, pc = c->pc;
    __uint128_t v0 = c->v[0];
    memcpy(saved, c->x, sizeof saved);
    for (int i = 0; i < g_nq; i++) give(c, g_queue[i]);
    g_nq = 0;
    static int field_was;
    int field = on_field();
    static uint64_t scene_was;
    uint64_t mgr = LD64(GAME_MGR), scene = mgr ? LD64(mgr + 0x4a8) : 0;
    if (field != field_was || scene != scene_was) {  // left / (re)loaded the Field: drop the refs of holes gone
        for (int g = 0; g < NTILES; g++)
            if (g_alive[g] && !hole_alive(g)) { c->x[0] = g_alive[g]; g_alive[g] = 0; guest_call(c, WEAK_RELEASE); }
        memset(g_spawns, 0, sizeof g_spawns);
        field_was = field, scene_was = scene;
    }
    if (field && frame % 8 == 0) {
        uint64_t pc0 = doorjump_player(frame);
        if (pc0) {
            const float *p = (const float *)(uintptr_t)(pc0 + 0x80);
            int here = tile_at(p[0], p[2]), spawned = 0;
            if (here >= 0) {
                int row0 = here / 80 / 16, col = here / 80 % 16;
                for (int r = row0 - 1; r <= row0 + 1; r++)
                    for (int k = col - 1; k <= col + 1; k++) {
                        if (r < 0 || r > 15 || k < 0 || k > 15) continue;
                        for (int t = 0; t < 80 && spawned < 12; t++) {
                            int g = (r * 16 + k) * 80 + t;
                            if (!g_tiles[g].hole || g_spawns[g] >= 3 || !flags_ext_get(DIG_FLAG_BASE + g) || hole_alive(g)) continue;
                            if (g_alive[g]) { c->x[0] = g_alive[g]; g_alive[g] = 0; guest_call(c, WEAK_RELEASE); }
                            spawn_hole(c, g);
                            g_spawns[g]++;
                            spawned++;
                        }
                    }
            }
            if (spawned) LOG("[digs] f%llu: %d holes reopened around %02d%c\n", (unsigned long long)frame, spawned,
                             here / 80 / 16 + 1, 'A' + here / 80 % 16);
        }
    }
    memcpy(c->x, saved, sizeof saved);
    c->v[0] = v0;
    c->sp = sp;
    c->pc = pc;
}
