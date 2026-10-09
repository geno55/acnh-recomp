// Pets (tools/rando/pets.py): the Flying Rooster, Marin and the Ghost found as items. A pet item reaches the game's
// AddItem (keysanity.c rt_add_item) with index PET_INDEX + n; it becomes the companion following Link (live save
// +0x555D: 0 none, 1 BowWow, 2 Marin, 3 Ghost, 4 Flying Rooster - the game spawns it at the next screen / room
// load) and is remembered in an event flag so the in-game menu can call any found pet back (runtime/ui/pets_ui.mm;
// Link has one companion at a time). A companion a pet sends away (also BowWow, or a rooster revived the vanilla
// way) is marked found too. The Ghost skips his house visit (Ghost2/3 flags): he asks for his grave, whose Owl
// gives the ghost-reward check once he is laid to rest (Ghost4_Clear).
// Flag indices come from rando/<seed>/flags.tsv (tools/rando/seed_tables.py).
#include <stdio.h>
#include <string.h>

#include "../hle.h"
#include "../rando.h"

#define LIVE_SAVE 0x7001CBB220ull
#define COMPANION (LIVE_SAVE + 0x555D)
#define FLAGS (LIVE_SAVE + 0x5DC0)
enum { PET_INDEX = 90, NPETS = 3 };
enum { C_NONE, C_BOWWOW, C_MARIN, C_GHOST, C_ROOSTER };

// by companion value: name, "found" flag (pets.py FLAGS), story flag after which it can't be called back
static const struct { const char *name, *found, *gone; } kComp[5] = {
    {"None", NULL, NULL}, {"BowWow", "unused0430", NULL}, {"Marin", "unused0428", "WalrusAwaked"},
    {"The Ghost", "unused0429", "Ghost4_Clear"}, {"The Flying Rooster", "unused0427", NULL},
};
static const int kPetComp[NPETS] = {C_ROOSTER, C_MARIN, C_GHOST};  // pets.py ORDER

static int flag_index(const char *name) {
    static char names[64][32];
    static int idx[64], n = -1;
    if (n < 0) {
        n = 0;
        char p[600], line[128];
        snprintf(p, sizeof p, "%s/flags.tsv", rando_seed_dir() ? rando_seed_dir() : ".");
        FILE *f = rando_seed_dir() ? fopen(p, "r") : NULL;
        while (f && n < 64 && fgets(line, sizeof line, f)) {
            char nm[64];
            int i;
            if (sscanf(line, "%63s %d", nm, &i) == 2) {
                strlcpy(names[n], nm, sizeof names[n]);
                idx[n++] = i;
            }
        }
        if (f) fclose(f);
    }
    for (int i = 0; name && i < n; i++)
        if (!strcmp(names[i], name)) return idx[i];
    return -1;
}

static bool flag_get(const char *name) {
    int i = flag_index(name);
    return i >= 0 && i < 2048 && (*(volatile uint8_t *)(uintptr_t)(FLAGS + (i >> 3)) >> (i & 7)) & 1;
}

static void flag_put(const char *name, bool on) {
    int i = flag_index(name);
    if (i < 0 || i >= 2048) return;
    volatile uint8_t *b = (volatile uint8_t *)(uintptr_t)(FLAGS + (i >> 3));
    *b = on ? (uint8_t)(*b | 1u << (i & 7)) : (uint8_t)(*b & ~(1u << (i & 7)));
}

int pets_current(void) { return *(volatile uint8_t *)(uintptr_t)COMPANION; }

// Companions the menu can call (found, story not past them), current one included: count, values in out[]
int pets_callable(int out[5]) {
    int n = 0;
    for (int c = C_BOWWOW; c <= C_ROOSTER; c++)
        if ((flag_get(kComp[c].found) || pets_current() == c) && !(kComp[c].gone && flag_get(kComp[c].gone))) out[n++] = c;
    return n;
}

const char *pets_name(int c) { return c >= 0 && c < 5 ? kComp[c].name : "?"; }

// Make companion c follow Link (from the next screen); the one it replaces stays callable
void pets_call(int c) {
    int cur = pets_current();
    if (cur == c || c < 0 || c > C_ROOSTER) return;
    if (cur > C_NONE && cur <= C_ROOSTER) flag_put(kComp[cur].found, true);
    if (c == C_BOWWOW) flag_put(kComp[C_BOWWOW].found, false);  // (back with Link: Madam MeowMeow may take him)
    *(volatile uint8_t *)(uintptr_t)COMPANION = (uint8_t)c;
    LOG("[pets] companion %d -> %d\n", cur, c);
}

// rt_add_item (keysanity.c): x2 index PET_INDEX + n. Returns 1 (handled: nothing is added to the inventory)
int rt_pet_item(int n) {
    if (n < 0 || n >= NPETS) return 0;
    int c = kPetComp[n];
    flag_put(kComp[c].found, true);
    if (c == C_GHOST) {  // straight to "take me to my grave"
        flag_put("GhostClear1", true);
        flag_put("Ghost2_Clear", true);
        flag_put("Ghost3_Clear", true);
    }
    pets_call(c);
    char t[96];
    snprintf(t, sizeof t, "%s joins you!", kComp[c].name);
    extern void ui_toast(const char *text);
    ui_toast(t);
    LOG("[pets] found pet %d (companion %d)\n", n, c);
    return 1;
}
