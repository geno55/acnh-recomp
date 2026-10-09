// Inventory overlay for randomizer seeds: while the pause menu's Items page is shown, a panel along its bottom
// lists every dungeon's small keys (count) plus Nightmare Key / Map / Compass / Stone Beak, read live from the
// game's per-dungeon records, and the trade sequence (found / in hand / traded away). (Randomized keys can be found anywhere, and the game only shows the current
// dungeon's keys.) The Items page is detected by tools/patches.py ITEMS_PAGE_SITE.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../rando.h"
#include "../settings.h"
uint64_t renderer_present_count(void);
}

#define DUNGEON_RECORDS (MAIN_BASE + 0x1CBB220 + 0xE0)  // live save: 0x10-byte records (+0 keys, +1 item bits)

static volatile uint64_t g_items_frame;

#define EVENT_FLAGS (MAIN_BASE + 0x1CBB220 + 0x5DC0)  // live save: GlobalFlags bitfield
#define TRADE_SLOT (MAIN_BASE + 0x1CBB220 + 0x555A)   // live save: current trade item (1..14, 0 = none)

// Trade sequence (save TRADE_SLOT values 1..14), the LAS flag set when each one is obtained, and the flag the trade
// NPC's flow sets when it takes the item (its "...Drop" = what it hands over; tools/rando/seed_tables.py exports them).
// Trade quest shuffle lets Link carry several at once, so the row tells which he still has.
static const struct { const char *name, *flag, *done; } kTrade[] = {
    {"Doll", "TradeYoshiDollGet", "RibbonDrop"}, {"Ribbon", "TradeRibbonGet", "DogfoodDrop"},
    {"Dog Food", "TradeDogFoodGet", "BananaDrop"}, {"Bananas", "TradeBananasGet", "StickDrop"},
    {"Stick", "TradeStickGet", "HoneycombDrop"}, {"Honey", "TradeHoneycombGet", "PineappleGet"},
    {"Pineapple", "TradePineappleGet", "HibiscusDrop"}, {"Hibiscus", "TradeHibiscusGet", "LetterDrop"},
    {"Letter", "TradeLetterGet", "BroomDrop"}, {"Broom", "TradeBroomGet", "FishhookDrop"},
    {"Hook", "TradeFishingHookGet", "BrassiereDrop"}, {"Necklace", "TradeNecklaceGet", "ScaleDrop"},
    {"Scale", "TradeMermaidsScaleGet", "MarthaStatueOpened"}, {"Lens", NULL, NULL}};
static int g_trade_flag[14], g_trade_done[14];  // -1 = not in the seed's flags.tsv (older seeds: no "done" flags)
static int g_trade_loaded;

static void load_trade_flags(void) {
    g_trade_loaded = 1;
    for (int i = 0; i < 14; i++) g_trade_flag[i] = g_trade_done[i] = -1;
    char path[512];
    snprintf(path, sizeof path, "%s/flags.tsv", rando_seed_dir());
    FILE *f = fopen(path, "r");
    if (!f) return;
    char name[96];
    int idx;
    while (fscanf(f, "%95s %d", name, &idx) == 2)
        for (int i = 0; i < 14; i++) {
            if (kTrade[i].flag && !strcmp(kTrade[i].flag, name)) g_trade_flag[i] = idx;
            if (kTrade[i].done && !strcmp(kTrade[i].done, name)) g_trade_done[i] = idx;
        }
    fclose(f);
}

static bool flag_set(int i) { return i >= 0 && i < 2048 && (LD8(EVENT_FLAGS + (i >> 3)) >> (i & 7)) & 1; }

extern "C" void rt_items_page_tick(void) { g_items_frame = renderer_present_count(); }

static bool items_page_shown(void) {
    uint64_t f = g_items_frame;
    return f && renderer_present_count() - f <= 2;
}

extern "C" bool inventory_overlay_wanted(void) {
    return g_settings.inv_keys && rando_seed_dir() && items_page_shown();
}

struct Dungeon { const char *label; int index; };
// record = 2 x (dungeon number - 1); the Color Dungeon is record 18 (verified from the in-dungeon key HUD)
static const Dungeon kDungeons[] = {{"D1", 0}, {"D2", 2}, {"D3", 4}, {"D4", 6}, {"D5", 8},
                                    {"D6", 10}, {"D7", 12}, {"D8", 14}, {"D0", 18}};

static bool record(int i, int *keys, int *bits) {
    uint64_t p = DUNGEON_RECORDS + 0x10ull * i;
    *keys = LD8(p);
    *bits = LD8(p + 1);
    return true;
}

// A small key glyph: ring + shaft + teeth.
static void key_icon(ImDrawList *dl, ImVec2 c, float s, ImU32 col) {
    dl->AddCircle(ImVec2(c.x, c.y - s * 0.45f), s * 0.28f, col, 16, s * 0.14f);
    dl->AddRectFilled(ImVec2(c.x - s * 0.07f, c.y - s * 0.2f), ImVec2(c.x + s * 0.07f, c.y + s * 0.6f), col);
    dl->AddRectFilled(ImVec2(c.x + s * 0.07f, c.y + s * 0.3f), ImVec2(c.x + s * 0.28f, c.y + s * 0.4f), col);
    dl->AddRectFilled(ImVec2(c.x + s * 0.07f, c.y + s * 0.48f), ImVec2(c.x + s * 0.22f, c.y + s * 0.58f), col);
}

extern "C" void inventory_overlay_draw(ImVec2 display, ImFont *font) {
    // the game's UI is drawn in a centred 16:9 box; place the panel in its free strip above the bottom rule
    float bw = fminf(display.x, display.y * 16.0f / 9.0f), bh = bw * 9.0f / 16.0f;
    float ox = (display.x - bw) * 0.5f, oy = (display.y - bh) * 0.5f;
    float u = bw / 1280.0f;  // game layout units (1280x720)
    ImVec2 p0(ox + 150 * u, oy + 512 * u), p1(ox + 1130 * u, oy + 630 * u);
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    dl->AddRectFilled(p0, p1, IM_COL32(52, 38, 20, 205), 14 * u);
    dl->AddRect(p0, p1, IM_COL32(214, 176, 92, 230), 14 * u, 0, 2.5f * u);
    int n = (int)(sizeof kDungeons / sizeof kDungeons[0]);
    float cw = (p1.x - p0.x) / n;
    float fs = 30 * u;
    for (int k = 0; k < n; k++) {
        int keys = 0, bits = 0;
        bool ok = record(kDungeons[k].index, &keys, &bits);
        float cx = p0.x + cw * (k + 0.5f);
        ImU32 gold = IM_COL32(240, 206, 110, 255), dim = IM_COL32(150, 128, 90, 255);
        const char *lbl = kDungeons[k].label;
        ImVec2 ts = font->CalcTextSizeA(fs, FLT_MAX, 0, lbl);
        dl->AddText(font, fs, ImVec2(cx - ts.x * 0.5f, p0.y + 4 * u), IM_COL32(255, 245, 225, 255), lbl);
        // small keys
        key_icon(dl, ImVec2(cx - 16 * u, p0.y + 50 * u), 26 * u, ok && keys ? gold : dim);
        char cnt[8];
        snprintf(cnt, sizeof cnt, "%d", ok ? keys : 0);
        dl->AddText(font, fs * 0.95f, ImVec2(cx - 2 * u, p0.y + 36 * u), ok && keys ? gold : dim, cnt);
        // Nightmare Key (bit3), map (bit1), compass (bit0), stone beak (bit2): little pips
        static const struct { int bit; ImU32 col; } pips[] = {{3, IM_COL32(230, 80, 70, 255)}, {1, IM_COL32(120, 190, 240, 255)},
                                                              {0, IM_COL32(150, 230, 140, 255)}, {2, IM_COL32(230, 230, 230, 255)}};
        for (int q = 0; q < 4; q++) {
            ImVec2 pc(cx + (q - 1.5f) * 12 * u + 24 * u, p0.y + 64 * u);
            if (ok && (bits >> pips[q].bit) & 1) dl->AddCircleFilled(pc, 4.5f * u, pips[q].col);
            else dl->AddCircle(pc, 4.5f * u, IM_COL32(120, 100, 70, 200), 12, 1.2f * u);
        }
    }
    // trade sequence: items Link has lit, the one in the trade slot outlined, traded-away ones dark with a tick
    if (!g_trade_loaded) load_trade_flags();
    int held = LD8(TRADE_SLOT);
    float tw = (p1.x - p0.x - 16 * u) / 14, ty = p0.y + 84 * u, th = 26 * u, tfs = 17 * u;
    for (int i = 0; i < 14; i++) {
        bool done = flag_set(g_trade_done[i]) && held != i + 1;
        bool got = !done && (flag_set(g_trade_flag[i]) || held == i + 1);
        ImVec2 a(p0.x + 8 * u + tw * i + 2 * u, ty), b(a.x + tw - 4 * u, ty + th);
        dl->AddRectFilled(a, b, got ? IM_COL32(120, 92, 40, 235) : done ? IM_COL32(48, 40, 28, 200) : IM_COL32(70, 54, 30, 160),
                          6 * u);
        if (held == i + 1) dl->AddRect(a, b, IM_COL32(255, 220, 120, 255), 6 * u, 0, 2.2f * u);
        ImVec2 ts = font->CalcTextSizeA(tfs, FLT_MAX, 0, kTrade[i].name);
        ImU32 tc = got ? IM_COL32(255, 240, 200, 255) : done ? IM_COL32(120, 160, 100, 220) : IM_COL32(150, 130, 100, 200);
        dl->AddText(font, tfs, ImVec2((a.x + b.x - ts.x) * 0.5f, (a.y + b.y - ts.y) * 0.5f), tc, kTrade[i].name);
        if (done) {  // a small tick in the corner: given to its NPC
            ImVec2 k(b.x - 9 * u, a.y + 3 * u);
            ImVec2 pts[3] = {ImVec2(k.x, k.y + 4 * u), ImVec2(k.x + 2.5f * u, k.y + 6.5f * u), ImVec2(k.x + 7 * u, k.y)};
            dl->AddPolyline(pts, 3, IM_COL32(140, 210, 110, 255), 0, 1.8f * u);
        }
    }
}
