// Chaos dungeon room shuffle: matching letters on the dungeon map (user 2026-10-08). Every doorway pair that leads
// somewhere else (rando/<seed>/door_jumps.tsv rows with a target, runtime/hle/doorjump.c) gets a letter, A-A, B-B...
// drawn at both doorways. A pair shows once Link has walked through either end, or all of them with the dungeon's
// Map.
//
// Placement: the dungeon map page (main+0xe78740 runs once per frame while it's shown; tools/patches.py
// DGN_MAP_SITE) holds its layout panes at page+0x8 -> +0x10: N_Map_00 (+0x70: zoom / scroll), N_MapPosition_00
// (+0x7a8: the dungeon's offset - Face Shrine -16, Tail Cave +48). The room grid P_Grid_00 is 652 x 518 layout
// units, 8 x 8 cells of 81.5 x 64.75 (1280 x 720 layout, origin at the centre, y up); found 2026-10-09 with
// LARECOMP_PANE_SCAN.
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../rando.h"
uint64_t renderer_present_count(void);
int doorjump_chaos_pairs(const char *level, int *ids, int max);
void doorjump_chaos_pair(int id, int *col, int *row, char *side, int *slot);
bool doorjump_chaos_seen(int id);
}

#define PLAYER_STATUS_PTR (MAIN_BASE + 0x1CC1368)  // PlayerStatus*: current level name at +0
#define DUNGEON_RECORDS (MAIN_BASE + 0x1CBB220 + 0xE0)  // live save: 0x10-byte records (+1 bit 1 = Map)

static volatile uint64_t g_dm_frame, g_dm_obj;

RT_ON_RESET(chaos_overlay_reset) { g_dm_frame = g_dm_obj = 0; }

extern "C" void rt_dgnmap_tick(Cpu *c) {
    g_dm_frame = renderer_present_count();
    g_dm_obj = c->x[0];
}

static const char *current_level(void) {
    uint64_t ps = LD64(PLAYER_STATUS_PTR);
    return ps ? (const char *)(uintptr_t)ps : "";
}

static bool have_map(const char *lv) {  // Lv01..Lv08 -> record 2(n-1), Lv10 (Color Dungeon) -> 18
    if (strncmp(lv, "Lv", 2)) return false;
    int n = (lv[2] - '0') * 10 + (lv[3] - '0');
    int rec = n == 10 ? 18 : 2 * (n - 1);
    if (n < 1 || n > 10 || n == 9) return false;
    return (LD8(DUNGEON_RECORDS + 0x10ull * rec + 1) >> 1) & 1;
}

static uint64_t pane(uint64_t p, const char *name) {  // the pane at p if it has that name
    if (!p) return 0;
    return strcmp((const char *)(uintptr_t)(p + 0xB0), name) ? 0 : p;
}

extern "C" bool chaos_overlay_wanted(void) {
    if (!rando_seed_dir() || renderer_present_count() - g_dm_frame > 2 || !g_dm_obj) return false;
    int ids[4];
    return doorjump_chaos_pairs(current_level(), ids, 4) > 0;
}

extern "C" void chaos_overlay_draw(ImVec2 display, ImFont *font) {
    uint64_t p1 = LD64(g_dm_obj + 0x8);
    uint64_t p2 = p1 ? LD64(p1 + 0x10) : 0;
    uint64_t map = p2 ? pane(LD64(p2 + 0x70), "N_Map_00") : 0;
    uint64_t pos = p2 ? pane(LD64(p2 + 0x7a8), "N_MapPosition_00") : 0;
    if (!map || !pos) return;
    const float *mf = (const float *)(uintptr_t)map, *pf = (const float *)(uintptr_t)pos;
    float mtx = mf[0x30 / 4], mty = mf[0x34 / 4], msc = mf[0x48 / 4];
    if (!(msc > 0.1f && msc < 20)) { mtx = mty = 0; msc = 1; }
    float ptx = pf[0x30 / 4], pty = pf[0x34 / 4];
    // the game's UI is a centred 16:9 box, laid out at 1280 x 720
    float bw = fminf(display.x, display.y * 16.0f / 9.0f), bh = bw * 9.0f / 16.0f;
    float ox = (display.x - bw) * 0.5f, oy = (display.y - bh) * 0.5f, u = bw / 1280.0f;
    const float CW = 81.5f, CH = 64.75f;
    auto to_screen = [&](float lx, float ly) {  // layout (centre origin, y up) inside the map -> screen
        float x = mtx + msc * (ptx + lx), y = mty + msc * (pty + ly);
        return ImVec2(ox + (640 + x) * u, oy + (360 - y) * u);
    };
    const char *lv = current_level();
    bool all = have_map(lv);
    int ids[296];
    int n = doorjump_chaos_pairs(lv, ids, 296);
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    float fs = 22 * u * (msc > 1 ? fminf(msc, 2.0f) : 1.0f);
    for (int i = 0; i < n; i++) {
        if (!all && !doorjump_chaos_seen(ids[i])) continue;
        char label[4];
        if (i < 26) snprintf(label, sizeof label, "%c", 'A' + i);
        else snprintf(label, sizeof label, "%c%c", 'A' + i / 26 - 1, 'A' + i % 26);
        int col[2], row[2], slot[2];
        char side[2];
        doorjump_chaos_pair(ids[i], col, row, side, slot);
        for (int e = 0; e < 2; e++) {
            // the doorway: on the cell's edge at its centre (slot in half tiles; a cell is 15 x 12 units), pulled
            // a little into the room so the letter sits on the room's map image
            float cx = -326 + (col[e] + 0.5f) * CW, cy = 259 - (row[e] - 0.5f) * CH;
            float ax = (slot[e] * 0.75f / 15.0f - 0.5f) * CW, az = (slot[e] * 0.75f / 12.0f - 0.5f) * CH;
            float lx = cx, ly = cy, in = 11;
            switch (side[e]) {
            case 'N': lx = cx + ax; ly = cy + CH / 2 - in; break;
            case 'S': lx = cx + ax; ly = cy - CH / 2 + in; break;
            case 'W': lx = cx - CW / 2 + in; ly = cy - az; break;
            default: lx = cx + CW / 2 - in; ly = cy - az; break;
            }
            ImVec2 p = to_screen(lx, ly);
            float r = fs * 0.62f;
            dl->AddCircleFilled(p, r, IM_COL32(40, 22, 10, 220));
            dl->AddCircle(p, r, IM_COL32(250, 215, 120, 255), 0, 1.5f * u);
            ImVec2 ts = font->CalcTextSizeA(fs, FLT_MAX, 0, label);
            dl->AddText(font, fs, ImVec2(p.x - ts.x * 0.5f, p.y - ts.y * 0.5f), IM_COL32(255, 240, 200, 255), label);
        }
    }
}
