// Shader preparation tour (first-launch shader compile, user 2026-10-08): LARECOMP_SHADER_TOUR=<frames per spot>
// warps through every warp spot of the game (runtime/ui/warp_data.h), letting each scene render for a moment so
// its shaders get translated and compiled - they land in cache/shaders/ and Metal's disk cache, which the boot
// warm-up (runtime/nvn/renderer.m shader_cache_warm) loads every later start: no first-use pop-in. Nothing derived
// from the game ships: the cache is built on the player's machine from their own copy. Exits when done.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "warp_data.h"

extern "C" {
#include "../hle.h"
int game_in_play(void);
void warp_request(const char *level, const char *locator);
int warp_busy(void);
}

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0

extern "C" void shader_tour_tick(uint64_t frame) {
    static int per = -1, i, waiting;
    static uint64_t since, started;
    if (per < 0) { const char *e = ENV("LARECOMP_SHADER_TOUR"); per = e ? atoi(e) : 0; if (e && per < 120) per = 240; }
    if (!per || !game_in_play()) return;
    const int n = (int)(sizeof kWarpSpots / sizeof kWarpSpots[0]);
    if (!started) { started = frame; LOG("[tour] %d spots, %d frames each\n", n, per); }
    if (i >= n) {
        LOG("[tour] done: %d spots in %.0f s\n", n, (frame - started) / 60.0);
        exit(0);
    }
    const WarpSpot &w = kWarpSpots[i];
    if (!waiting) {
        warp_request(w.level, w.locator);
        waiting = 1;
        since = frame;
        return;
    }
    // the warp applied (warping again while the last one still loads threw in the game: Field -> Field warps look
    // "arrived" at once), back in play, then `per` frames of rendering - or give up after 30 s
    static uint64_t applied;
    if (warp_busy() || !game_in_play()) { applied = 0; if (frame - since <= 1800) return; }
    if (!applied) applied = frame;
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    bool there = ps && !strcmp((const char *)(uintptr_t)ps, w.level);
    if ((there && frame - applied >= (uint64_t)per) || frame - since > 1800) {
        if (!there) LOG("[tour] %s / %s: not reached\n", w.level, w.locator);
        i++;
        waiting = 0;
        if (i % 20 == 0) LOG("[tour] %d / %d\n", i, n);
    }
}
