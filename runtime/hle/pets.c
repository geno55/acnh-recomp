// Pets (tools/rando/pets.py): the Flying Rooster, Marin and the Ghost found as items. A pet item reaches the game's
// AddItem (keysanity.c rt_add_item) with index PET_INDEX + n; the Rooster / Marin become the companion following
// Link (live save +0x555D: 0 none, 1 BowWow, 2 Marin, 3 Ghost, 4 Flying Rooster - the game spawns it at the next
// screen / room load) and are remembered in an event flag so the pause menu's companion slot (runtime/ui/
// inventory_overlay.mm) and the in-game menu can call any found pet back (Link has one companion at a time). A
// companion a pet sends away (also BowWow, or a rooster revived the vanilla way) is marked found too.
// The Ghost is an Items-page item, not a follower (seeds with settings.json "ghost-item"; older seeds: he follows):
// found, he skips his house visit (Ghost2/3 flags) and the grave takes him without the companion slot (its trigger
// reads his found flag, pets.py); laid to rest (Ghost4_Clear) his Owl gives the ghost-reward check (EighthClear).
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

static int g_nflags = -1;  // flags.tsv entries read (per seed: read again after an in-place reboot)
static int g_ghost_item = -1;  // settings.json "ghost-item" (per seed)
static int flag_index(const char *name) {
    static char names[64][32];
    static int idx[64];
    if (g_nflags < 0) {
        g_nflags = 0;
        char p[600], line[128];
        snprintf(p, sizeof p, "%s/flags.tsv", rando_seed_dir() ? rando_seed_dir() : ".");
        FILE *f = rando_seed_dir() ? fopen(p, "r") : NULL;
        while (f && g_nflags < 64 && fgets(line, sizeof line, f)) {
            char nm[64];
            int i;
            if (sscanf(line, "%63s %d", nm, &i) == 2) {
                strlcpy(names[g_nflags], nm, sizeof names[g_nflags]);
                idx[g_nflags++] = i;
            }
        }
        if (f) fclose(f);
    }
    for (int i = 0; name && i < g_nflags; i++)
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

static bool ghost_item(void) {
    if (g_ghost_item >= 0) return g_ghost_item;
    g_ghost_item = 0;
    char p[600], buf[16384];
    snprintf(p, sizeof p, "%s/settings.json", rando_seed_dir() ? rando_seed_dir() : ".");
    FILE *f = rando_seed_dir() ? fopen(p, "r") : NULL;
    if (!f) return false;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    return g_ghost_item = strstr(buf, "\"ghost-item\": true") != NULL;
}

// Items-page Ghost slot: -1 none (not an item in this seed / not found), 0 found, 1 laid to rest and his Owl's
// check collected (EighthClear: the Owl's flow sets it as it gives the item)
int pets_ghost_state(void) {
    if (!ghost_item() || !flag_get(kComp[C_GHOST].found)) return -1;
    return flag_get("Ghost4_Clear") && flag_get("EighthClear");
}

// Companions the menu can call (found, story not past them), current one included: count, values in out[]
int pets_callable(int out[5]) {
    int n = 0;
    for (int c = C_BOWWOW; c <= C_ROOSTER; c++)
        if (pets_current() == c || (flag_get(kComp[c].found) && !(c == C_GHOST && ghost_item()) &&
                                    !(kComp[c].gone && flag_get(kComp[c].gone))))
            out[n++] = c;
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

// Pause menu companion slot (runtime/ui/inventory_overlay.mm): the choices are "no companion" then every callable
// one; out[0] = 0. Fewer than 2 = nothing to switch (no slot drawn).
int pets_menu_options(int out[6]) {
    out[0] = C_NONE;
    return 1 + pets_callable(out + 1);
}

// Pause menu companion slot (runtime/ui/inventory_overlay.mm), game thread, each pad read (input.c fill_state, b =
// the buttons with the stick directions as bits 16-23, st = the sticks). The slot extends the Items page's own
// cursor: LEFT from the grid's left column moves onto it (the game's cursor stays where it was), UP / DOWN pick a
// choice, A makes it follow, RIGHT goes back to the grid. While on the slot the game sees no directions, sticks or
// A / X / Y; a direction that moved onto / off the slot stays hidden from it until released (else the game would
// take it as a fresh press). B (close) and L / R (other pages) reach the game and leave the slot.
static int g_slot = -1;  // highlighted choice while the cursor is on the slot, -1 = on the game's grid
int pets_menu_slot(void) { return g_slot; }

uint64_t pets_menu_input(uint64_t b, int32_t st[4]) {
    extern int inventory_items_cursor(void);
    enum { A = 1, X = 4, Y = 8, LEFT = 1 << 12, UP = 1 << 13, RIGHT = 1 << 14, DOWN = 1 << 15 };
    const uint64_t dirs = 0xfull << 12 | 0xffull << 16;
    static uint64_t prev, hide;
    uint64_t press = b & ~prev;
    prev = b;
    hide &= b;  // (released: the game may see it again)
    if (!rando_seed_dir()) return b;
    static int ghost = -2;  // (log the Ghost's steps: found, laid to rest, Owl's check)
    int gs = ghost_item() ? flag_get(kComp[C_GHOST].found) + flag_get("Ghost4_Clear") + pets_ghost_state() : -2;
    if (gs != ghost) LOG("[pets] ghost item state %d -> %d\n", ghost, gs), ghost = gs;
    int o[6], n = pets_menu_options(o), cur = inventory_items_cursor();
    if (hide) st[0] = st[1] = st[2] = st[3] = 0;  // (a direction may be a stick, or the d-pad walking setting's)
    if (cur < 0 || n < 2) return g_slot = -1, b & ~hide;
    bool left = press & (LEFT | 1 << 16), right = press & (RIGHT | 1 << 18);
    bool up = press & (UP | 1 << 17), down = press & (DOWN | 1 << 19);
    if (g_slot < 0) {
        if (!left || cur % 4) return b & ~hide;
        for (g_slot = 0; g_slot < n - 1 && o[g_slot] != pets_current(); g_slot++) {}
        hide |= b & dirs;
        LOG("[pets] menu: on the companion slot (grid cursor %d)\n", cur);
    } else if (right) {
        g_slot = -1;
        hide |= b & dirs;
        st[0] = st[1] = st[2] = st[3] = 0;
        return b & ~hide;
    } else if (up || down) {
        g_slot = (g_slot + (up ? n - 1 : 1)) % n;
    } else if (press & A) {
        pets_call(o[g_slot]);
    }
    if (g_slot >= n) g_slot = n - 1;
    st[0] = st[1] = st[2] = st[3] = 0;
    return b & ~(dirs | A | X | Y);
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
    if (c != C_GHOST || !ghost_item()) pets_call(c);  // (the Ghost item leaves the follower alone)
    // (no custom pop-up: the user wants item text in the game's own message box - a pet message is still open)
    LOG("[pets] found pet %d (companion %d: %s)\n", n, c, kComp[c].name);
    return 1;
}

RT_ON_RESET(pets_reset) { g_nflags = -1, g_ghost_item = -1; }  // (seed switch: the next seed's flags.tsv)
