// Boss souls / mini-boss souls (randomizer options "Boss souls" / "Mini-boss souls", tools/rando/souls.py): a dungeon
// boss or mini-boss only appears once its soul has been found. Souls are items that set an event flag;
// rando/<seed>/souls.tsv (no file: both options off) lists
//   <dungeon> <type> <flag> <name> <reward key>   a boss (0 = Color Dungeon) and its reward actor (instrument / fairy)
//   mini <type> <flag> <name>                     a mini-boss kind (every encounter of it)
//   room <level> <soul flag> <defeat flag> <cells>  a room whose shutters stay open without its enemy
// The actor factory asks rt_actor_create_fn for a type's create function (tools/patches.py BOSS_SPAWN_SITE); for a
// held-back boss / mini-boss / reward we hand back none - the factory's own path for a type without a class. Rooms
// create their actors as they stream in, so a soul found inside the dungeon counts once the room is loaded again.
//
// An empty room's shutters stay open (they follow the enemy), so the way on would be free: souls_tick keeps Link in
// such a room unless he leaves into the cell he came from, until the room's defeat flag is set (vanilla: the shutters
// open on that same flag) or the soul is found (then the enemy is there and the game's own shutters take over).
// Entered by falling / stairs (no neighbouring cell before): no wall (he can't go back the way he came).
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0

bool flags_ext_get(int idx);
uint64_t doorjump_player(uint64_t frame);  // PlayerCollision component: position at +0x80 (and +0xb0)

typedef struct { int kind, dungeon; uint32_t type; int flag; char name[32]; unsigned long long reward; } Soul;  // kind 0 boss, 1 mini
typedef struct { char level[32]; int soul_flag, defeat_flag, ncells; int8_t cells[8][2]; } Wall;
static Soul g_souls[32];
static int g_nsouls = -1;
static Wall g_walls[48];
static int g_nwalls;

static void load(void) {
    g_nsouls = g_nwalls = 0;
    const char *dir = rando_seed_dir();
    if (!dir) return;
    char p[1024], line[256];
    snprintf(p, sizeof p, "%s/souls.tsv", dir);
    FILE *f = fopen(p, "r");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        Soul *s = &g_souls[g_nsouls];
        Wall *w = &g_walls[g_nwalls];
        char cells[160];
        if (!strncmp(line, "room\t", 5)) {
            if (g_nwalls < 48 && sscanf(line + 5, "%31[^\t]\t%d\t%d\t%159s", w->level, &w->soul_flag, &w->defeat_flag, cells) == 4) {
                w->ncells = 0;
                for (char *c = strtok(cells, ";"); c && w->ncells < 8; c = strtok(NULL, ";")) {
                    int x, y;
                    if (sscanf(c, "%d,%d", &x, &y) == 2) w->cells[w->ncells][0] = (int8_t)x, w->cells[w->ncells++][1] = (int8_t)y;
                }
                g_nwalls++;
            }
        } else if (g_nsouls >= 32) {
            continue;
        } else if (!strncmp(line, "mini\t", 5)) {
            if (sscanf(line + 5, "%i\t%d\t%31[^\t\n]", (int *)&s->type, &s->flag, s->name) == 3) {
                s->kind = 1, s->dungeon = -1, s->reward = 0;
                g_nsouls++;
            }
        } else if (sscanf(line, "%d\t%i\t%d\t%31[^\t]\t%llx", &s->dungeon, (int *)&s->type, &s->flag, s->name, &s->reward) == 5) {
            s->kind = 0;
            g_nsouls++;
        }
    }
    fclose(f);
    LOG("[souls] %d souls, %d walled rooms in this seed\n", g_nsouls, g_nwalls);
}

static const char *level_name(void) {
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    return ps ? (const char *)(uintptr_t)ps : "";
}

uint64_t rt_actor_create_fn(uint64_t fn, uint32_t type, uint64_t info) {
    extern bool rt_digs_skip_plant(uint32_t type, uint64_t info);  // digsanity: no grass / bush on a dug tile
    if (rt_digs_skip_plant(type, info)) return 0;
    if (g_nsouls < 0) load();
    if (ENV("LARECOMP_LOG_SPAWN")) {  // (debug: every actor the factory makes; spawn info words)
        LOG("[spawn] type %#x:", type);
        for (int w = 0; w < 24; w++) LOG(" %llx", (unsigned long long)LD64(info + 8 * w));
        LOG("\n");
    }
    for (int i = 0; i < g_nsouls; i++) {
        Soul *s = &g_souls[i];
        bool reward = s->reward && LD64(info) == s->reward;  // (spawn info +0: the level actor's key)
        if (s->type != type && !reward) continue;
        // only in the dungeons: Dampe's chambers reuse boss rooms; overworld mini-bosses (enemy randomizer) stay
        if (strncmp(level_name(), "Lv", 2) || flags_ext_get(s->flag)) return fn;
        LOG("[souls] %s's soul not found: %s held back\n", s->name, reward ? "reward" : s->kind ? "mini-boss" : "boss");
        return 0;
    }
    return fn;
}

// ---- the wall: Link leaves a room with a held-back enemy only into the cell he came from
static bool in_wall(const Wall *w, int c, int r) {
    for (int i = 0; i < w->ncells; i++)
        if (w->cells[i][0] == c && w->cells[i][1] == r) return true;
    return false;
}

static struct { int wall; int from_c, from_r; bool way_back; } g_in = {-1};
static float g_last[3];
static int g_last_c = -999, g_last_r = -999;
static char g_last_level[32];

void souls_tick(uint64_t frame) {
    if (g_nsouls < 0) load();
    if (!g_nwalls) return;
    const char *lv = level_name();
    if (strncmp(lv, "Lv", 2)) return;
    uint64_t pc = doorjump_player(frame);
    if (!pc) return;
    float *pos = (float *)(uintptr_t)(pc + 0x80), *pos2 = (float *)(uintptr_t)(pc + 0xb0);
    if (strncmp(g_last_level, lv, sizeof g_last_level - 1)) {  // new level: no history
        strlcpy(g_last_level, lv, sizeof g_last_level);
        g_in.wall = -1;
        g_last_c = -999;
    }
    int c = (int)floorf(pos[0] / 15.0f), r = (int)floorf(pos[2] / 12.0f);
    int now = -1;
    for (int i = 0; i < g_nwalls && now < 0; i++)
        if (!strcmp(g_walls[i].level, lv) && in_wall(&g_walls[i], c, r)) now = i;
    if (g_in.wall >= 0 && now != g_in.wall) g_in.wall = -1;  // left (the way back, a fall, a warp)
    if (now >= 0 && g_in.wall != now) {  // entering: remember the cell he came from (a neighbour of the room)
        g_in.wall = now;
        g_in.from_c = g_last_c, g_in.from_r = g_last_r;
        g_in.way_back = abs(c - g_last_c) + abs(r - g_last_r) == 1;
        const Wall *w = &g_walls[now];
        if (!flags_ext_get(w->defeat_flag) && !flags_ext_get(w->soul_flag))
            LOG("[souls] f%llu entered a walled room (%d,%d) from (%d,%d)%s\n", (unsigned long long)frame, c, r, g_last_c,
                g_last_r, g_in.way_back ? "" : ": not from a neighbour, no wall");
    }
    if (g_in.wall >= 0 && g_in.way_back) {  // inside: keep him off every wall but the one toward where he came from
        const Wall *w = &g_walls[g_in.wall];
        if (!flags_ext_get(w->defeat_flag) && !flags_ext_get(w->soul_flag)) {
            // (a margin short of the doorway: once he steps into it the game takes him through to the next room)
            const float M = 1.6f;
            float x = pos[0], z = pos[2];
            for (int i = 0; i < w->ncells; i++) {
                if (w->cells[i][0] != c || w->cells[i][1] != r) continue;
                float x0 = c * 15.0f, z0 = r * 12.0f;
                static const int8_t step[4][2] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};  // N S W E
                for (int sd = 0; sd < 4; sd++) {
                    int nc = c + step[sd][0], nr = r + step[sd][1];
                    if (in_wall(w, nc, nr) || (nc == g_in.from_c && nr == g_in.from_r)) continue;
                    if (sd == 0 && z < z0 + M) z = z0 + M;
                    if (sd == 1 && z > z0 + 12.0f - M) z = z0 + 12.0f - M;
                    if (sd == 2 && x < x0 + M) x = x0 + M;
                    if (sd == 3 && x > x0 + 15.0f - M) x = x0 + 15.0f - M;
                }
            }
            if (x != pos[0] || z != pos[2]) {
                pos[0] = pos2[0] = x;
                pos[2] = pos2[2] = z;
                if (ENV("LARECOMP_LOG_SOULS")) LOG("[souls] f%llu wall at (%.2f, %.2f)\n", (unsigned long long)frame, x, z);
            }
        }
    }
    g_last[0] = pos[0], g_last[1] = pos[1], g_last[2] = pos[2];
    g_last_c = c, g_last_r = r;
}

// for the inventory overlay: -1 = the seed has no boss souls, else whether dungeon n's (0 = Color Dungeon) is found
int souls_owned(int dungeon) {
    if (g_nsouls < 0) load();
    for (int i = 0; i < g_nsouls; i++)
        if (!g_souls[i].kind && g_souls[i].dungeon == dungeon) return flags_ext_get(g_souls[i].flag);
    return -1;
}

// every soul of the seed (overlay, tracker): name of soul i (NULL past the end), *kind 0 boss / 1 mini-boss, *owned
const char *souls_at(int i, int *kind, bool *owned) {
    if (g_nsouls < 0) load();
    if (i < 0 || i >= g_nsouls) return NULL;
    *kind = g_souls[i].kind;
    *owned = flags_ext_get(g_souls[i].flag);
    return g_souls[i].name;
}

RT_ON_RESET(souls_reset) {  // (seed switch: reload rando/<seed>/souls.tsv)
    g_nsouls = -1;
    g_nwalls = 0;
    g_in.wall = -1;
    g_last_c = g_last_r = -999;
    g_last_level[0] = 0;
}
