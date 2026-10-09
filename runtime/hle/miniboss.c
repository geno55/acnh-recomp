// Mini-bosses on the overworld (enemy randomizer, "Mini-bosses among overworld enemies"). A mini-boss waits for its
// <Name>Start event, which the dungeon's zone manager sends when Link enters the mini-boss's camera zone
// (f_7000836270 -> listeners -> f_7000833a80 -> f_7000029520(actor) -> actor vfunc +0x100 = f_70003bf770). The Field
// never sends it, so they stay dormant. Here: the actors are seen through a per-frame type check (tools/patches.py
// MB_SEEN_SITE) and on the Field we call f_7000029520(actor) ourselves, once per actor.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"

void guest_call(Cpu *c, uint64_t addr);

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0
#define MB_VTABLE (MAIN_BASE + 0x1b80e90)         // vtable of the actors f_7000029520 starts (+0x100 = f_70003bf770)
#define ZONE_ENTER (MAIN_BASE + 0x29520)

typedef struct { uint64_t obj, first, last; int woken; } Seen;
static Seen g_seen[32];
extern uint64_t renderer_present_count(void);

void rt_mb_seen(Cpu *c) {
    uint64_t o = c->x[0];
    if (!o || LD64(o) != MB_VTABLE) return;
    uint64_t f = renderer_present_count();
    int free_i = -1;
    for (int i = 0; i < 32; i++) {
        if (g_seen[i].obj == o) { g_seen[i].last = f; return; }
        if (free_i < 0 && (!g_seen[i].obj || f - g_seen[i].last > 120)) free_i = i;
    }
    if (free_i >= 0) g_seen[free_i] = (Seen){o, f, f, 0};
}

void miniboss_tick(Cpu *c, uint64_t frame) {
    static int on = -1;
    if (on < 0) on = ENV("LARECOMP_MB_WAKE") != NULL;
    if (!on) return;
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    if (!ps || strcmp((const char *)(uintptr_t)ps, "Field")) return;
    for (int i = 0; i < 32; i++) {
        Seen *s = &g_seen[i];
        if (!s->obj || s->woken || frame - s->last > 2 || frame - s->first < 60 || LD64(s->obj) != MB_VTABLE) continue;
        s->woken = 1;
        uint64_t saved[31], sp = c->sp;
        memcpy(saved, c->x, sizeof saved);
        c->x[0] = s->obj;
        guest_call(c, ZONE_ENTER);
        memcpy(c->x, saved, sizeof saved);
        c->sp = sp;
        LOG("[miniboss] f%llu start sent to actor %llx\n", (unsigned long long)frame, (unsigned long long)s->obj);
    }
}
