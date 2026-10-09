// Boss souls (randomizer option "Boss souls", tools/rando/souls.py): a dungeon boss only appears once its soul has been
// found. Souls are items that set an event flag; rando/<seed>/souls.tsv has one line per boss: dungeon (0 = Color
// Dungeon), boss actor type, flag, name, reward actor key (the instrument / the Color Dungeon's fairy). No file: the
// option is off. The actor factory asks rt_actor_create_fn for a type's create function (tools/patches.py
// BOSS_SPAWN_SITE); for the boss or its reward while the flag is clear we hand back none - the factory's own path for a
// type without a class. The arena stays empty and open (its shutters follow the boss): nothing to fight, no Heart
// Container, no instrument, Link walks out. Rooms create their actors as they stream in, so a soul found inside the
// dungeon counts once the arena is loaded again.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0

bool flags_ext_get(int idx);

typedef struct { int dungeon; uint32_t type; int flag; char name[32]; unsigned long long reward; } Soul;
static Soul g_souls[16];
static int g_nsouls = -1;

static void load(void) {
    g_nsouls = 0;
    const char *dir = rando_seed_dir();
    if (!dir) return;
    char p[1024], line[128];
    snprintf(p, sizeof p, "%s/souls.tsv", dir);
    FILE *f = fopen(p, "r");
    if (!f) return;
    while (g_nsouls < 16 && fgets(line, sizeof line, f)) {
        Soul *s = &g_souls[g_nsouls];
        if (sscanf(line, "%d\t%i\t%d\t%31[^\t]\t%llx", &s->dungeon, (int *)&s->type, &s->flag, s->name, &s->reward) == 5)
            g_nsouls++;
    }
    fclose(f);
    LOG("[souls] %d boss souls in this seed\n", g_nsouls);
}

uint64_t rt_actor_create_fn(uint64_t fn, uint32_t type, uint64_t info) {
    extern bool rt_digs_skip_plant(uint32_t type, uint64_t info);  // digsanity: no grass / bush on a dug tile
    if (rt_digs_skip_plant(type, info)) return 0;
    if (g_nsouls < 0) load();
    if (ENV("LARECOMP_LOG_SPAWN"))
        LOG("[spawn] type %#x info %llx: %016llx %016llx %016llx %016llx\n", type, (unsigned long long)info,
            (unsigned long long)LD64(info), (unsigned long long)LD64(info + 8), (unsigned long long)LD64(info + 16),
            (unsigned long long)LD64(info + 24));
    for (int i = 0; i < g_nsouls; i++) {
        Soul *s = &g_souls[i];
        bool reward = LD64(info) == s->reward;  // (spawn info +0: the level actor's key)
        if (s->type != type && !reward) continue;
        uint64_t ps = LD64(PLAYER_STATUS_PTR);  // only in the dungeons (Dampe's chambers reuse boss rooms)
        if (!ps || strncmp((const char *)(uintptr_t)ps, "Lv", 2) || flags_ext_get(s->flag)) return fn;
        LOG("[souls] %s's soul not found: %s held back\n", s->name, reward ? "reward" : "boss");
        return 0;
    }
    return fn;
}

// for the inventory overlay: -1 = the seed has no boss souls, else whether dungeon n's (0 = Color Dungeon) is found
int souls_owned(int dungeon) {
    if (g_nsouls < 0) load();
    for (int i = 0; i < g_nsouls; i++)
        if (g_souls[i].dungeon == dungeon) return flags_ext_get(g_souls[i].flag);
    return -1;
}

RT_ON_RESET(souls_reset) { g_nsouls = -1; }  // (seed switch: reload rando/<seed>/souls.tsv)
