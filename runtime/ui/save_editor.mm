// Save editor tab: edits the game's live save buffer (main+0x1CBB220, an exact image of savedataN.bin),
// so changes apply immediately and are written out (with fresh checksums) the next time the game saves.
// Layout: notes/save_format.md.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"
#include "osk.h"
#include "item_names.h"

extern "C" void give_item_request(int id, int count, int index);

extern "C" {
#include "../hle.h"
}

#define LIVE_SAVE 0x7001CBB220ull  // main + 0x1CBB220
static uint8_t *S(void) { return (uint8_t *)(uintptr_t)LIVE_SAVE; }
template <typename T> static T &F(uint32_t off) { return *(T *)(S() + off); }

enum : uint32_t {
    H_NAME = 0x20, H_CUR_HP = 0x32, H_MAX_HP = 0x34, H_KEYS = 0x78, H_RUPEES = 0x7C, H_SHELLS = 0x80,
    NAME = 0x5388, RUPEES = 0x5540, HP = 0x5544, SHELLS = 0x5548, PIECES = 0x5550, CONTAINERS = 0x5558,
    TRADE = 0x555A, SONGS = 0x555B, UPGRADES = 0x555C, BOMBS = 0x555E, ARROWS = 0x555F, POWDER = 0x5560,
    ITEMS = 0x5568, KEYITEMS = 0x556C, SENSOR = 0x556E, FAIRIES = 0x5580, LEAVES = 0x5582,
};

static bool loaded(void) { return F<uint32_t>(0) == 0xE && F<uint16_t>(NAME) != 0; }

static int max_hp(void) {  // quarter-hearts, as GetMaxHealth() computes it
    return 12 + 4 * (__builtin_popcount(F<uint16_t>(CONTAINERS) & 0x1FF) + __builtin_popcountll(F<uint64_t>(PIECES)) / 4);
}

static uint64_t low_bits(int n) { return n >= 64 ? ~0ull : ((1ull << n) - 1); }

// Keep the file-select summary in step (the game also rebuilds it when it saves).
static void sync_header(void) {
    memcpy(S() + H_NAME, S() + NAME, 0x12);
    F<uint16_t>(H_CUR_HP) = (uint16_t)F<int16_t>(HP);
    F<uint16_t>(H_MAX_HP) = (uint16_t)max_hp();
    F<uint32_t>(H_KEYS) = F<uint32_t>(KEYITEMS) & 0x1FFFF;
    F<uint32_t>(H_RUPEES) = F<uint32_t>(RUPEES);
    F<uint64_t>(H_SHELLS) = F<uint64_t>(SHELLS);
}

static char g_name[32];
static bool g_name_dirty;

extern "C" void save_editor_on_open(void) {
    g_name_dirty = false;
    if (!loaded()) return;
    const uint16_t *u = (const uint16_t *)(S() + NAME);
    int n = 0;
    for (int i = 0; i < 8 && u[i]; i++) {  // UTF-16 -> UTF-8 (BMP)
        uint16_t c = u[i];
        if (c < 0x80) g_name[n++] = (char)c;
        else if (c < 0x800) { g_name[n++] = (char)(0xC0 | c >> 6); g_name[n++] = (char)(0x80 | (c & 0x3F)); }
        else { g_name[n++] = (char)(0xE0 | c >> 12); g_name[n++] = (char)(0x80 | ((c >> 6) & 0x3F)); g_name[n++] = (char)(0x80 | (c & 0x3F)); }
    }
    g_name[n] = 0;
}

static void write_name(const char *s) {
    uint16_t out[9] = {0};
    int n = 0;
    const unsigned char *p = (const unsigned char *)s;
    while (*p && n < 8) {
        uint32_t c = *p++;
        if (c >= 0xE0 && p[0] && p[1]) { c = ((c & 0xF) << 12) | ((p[0] & 0x3F) << 6) | (p[1] & 0x3F); p += 2; }
        else if (c >= 0xC0 && p[0]) { c = ((c & 0x1F) << 6) | (p[0] & 0x3F); p += 1; }
        out[n++] = (uint16_t)c;
    }
    memcpy(S() + NAME, out, sizeof out);
}

// ---- small widgets (label column + control column, controller friendly)
static float g_col;
static void label(const char *t) {
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(t);
    ImGui::SameLine(g_col);
    ImGui::SetNextItemWidth(-1);
}

static bool slider(const char *t, int *v, int lo, int hi, const char *fmt = "%d") {
    ImGui::PushID(t);
    label(t);
    bool ch = ImGui::SliderInt("##s", v, lo, hi, fmt, ImGuiSliderFlags_AlwaysClamp);
    ImGui::PopID();
    return ch;
}

static bool bitbox(const char *t, uint32_t off, int bit, int width = 32) {
    bool v;
    if (width == 8) v = (F<uint8_t>(off) >> bit) & 1;
    else if (width == 16) v = (F<uint16_t>(off) >> bit) & 1;
    else v = (F<uint32_t>(off) >> bit) & 1;
    if (!ImGui::Checkbox(t, &v)) return false;
    if (width == 8) F<uint8_t>(off) = (uint8_t)((F<uint8_t>(off) & ~(1u << bit)) | ((uint32_t)v << bit));
    else if (width == 16) F<uint16_t>(off) = (uint16_t)((F<uint16_t>(off) & ~(1u << bit)) | ((uint32_t)v << bit));
    else F<uint32_t>(off) = (F<uint32_t>(off) & ~(1u << bit)) | ((uint32_t)v << bit);
    return true;
}

// Level item: "owned" bit in ITEMS plus an upgrade bit in UPGRADES.
static bool level(const char *t, int item_bit, int up_bit, const char *const names[3]) {
    int lv = !((F<uint32_t>(ITEMS) >> item_bit) & 1) ? 0 : ((F<uint8_t>(UPGRADES) >> up_bit) & 1) ? 2 : 1;
    ImGui::PushID(t);
    label(t);
    bool ch = false;
    if (ImGui::BeginCombo("##l", names[lv])) {
        for (int i = 0; i < 3; i++)
            if (ImGui::Selectable(names[i], i == lv)) { lv = i; ch = true; }
        ImGui::EndCombo();
    }
    if (ImGui::IsItemFocused()) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow)) { lv = (lv + 1) % 3; ch = true; }
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) { lv = (lv + 2) % 3; ch = true; }
    }
    if (ch) {
        F<uint32_t>(ITEMS) = (F<uint32_t>(ITEMS) & ~(1u << item_bit)) | ((uint32_t)(lv > 0) << item_bit);
        F<uint8_t>(UPGRADES) = (uint8_t)((F<uint8_t>(UPGRADES) & ~(1u << up_bit)) | ((uint32_t)(lv == 2) << up_bit));
    }
    ImGui::PopID();
    return ch;
}

static void section(const char *t) {
    ImGui::Spacing();
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", t);
    ImGui::Separator();
}

// Grid of checkboxes, `cols` per row.
struct Bit { const char *name; uint32_t off; int bit; int width; };
static void bit_grid(const Bit *b, int n, int cols) {
    if (ImGui::BeginTable("##g", cols)) {
        for (int i = 0; i < n; i++) {
            ImGui::TableNextColumn();
            bitbox(b[i].name, b[i].off, b[i].bit, b[i].width);
        }
        ImGui::EndTable();
    }
}

static void capacity(const char *t, uint32_t count_off, int up_bit, int base_cap) {
    int cap = ((F<uint8_t>(UPGRADES) >> up_bit) & 1) ? base_cap * 2 : base_cap;
    int v = F<uint8_t>(count_off);
    char lbl[64];
    snprintf(lbl, sizeof lbl, "%s", t);
    if (slider(lbl, &v, 0, cap)) F<uint8_t>(count_off) = (uint8_t)v;
}

extern "C" void save_editor_draw(float scale) {
    if (!loaded()) {
        ImGui::TextDisabled("Load a save file first: the editor changes the save that's currently being played.");
        return;
    }
    g_col = ImGui::GetContentRegionAvail().x * 0.38f;
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("Changes apply immediately and are kept the next time the game saves. The heart row on the HUD "
                        "updates after the next screen transition.");
    ImGui::PopTextWrapPos();

    if (ImGui::Button("Max out everything")) {
        F<uint16_t>(CONTAINERS) = 0x1FF;
        F<uint64_t>(PIECES) = 0xFFFFFFFFull;
        F<uint32_t>(RUPEES) = 999;
        F<uint64_t>(SHELLS) = low_bits(50);
        F<uint8_t>(LEAVES) = 0x1F;
        F<uint32_t>(ITEMS) |= 0xFFFF;
        F<uint8_t>(UPGRADES) |= 0x3F;
        F<uint8_t>(BOMBS) = 60; F<uint8_t>(ARROWS) = 60; F<uint8_t>(POWDER) = 40;
        F<uint8_t>(SONGS) = 7;
        F<uint32_t>(KEYITEMS) |= 0x7FFF;
        F<uint8_t>(SENSOR) |= 1;
        F<int16_t>(HP) = (int16_t)max_hp();
    }
    ImGui::SameLine();
    if (ImGui::Button("Refill hearts & ammo")) {
        F<int16_t>(HP) = (int16_t)max_hp();
        if (F<uint32_t>(ITEMS) & (1u << 2)) F<uint8_t>(BOMBS) = (F<uint8_t>(UPGRADES) & 0x10) ? 60 : 30;
        if (F<uint32_t>(ITEMS) & (1u << 3)) F<uint8_t>(ARROWS) = (F<uint8_t>(UPGRADES) & 0x20) ? 60 : 30;
        if (F<uint32_t>(ITEMS) & (1u << 8)) F<uint8_t>(POWDER) = (F<uint8_t>(UPGRADES) & 0x08) ? 40 : 20;
    }

    section("Player");
    label("Name");
    if (ui_input_text("##name", g_name, 9 * 3, 0, NULL, "Name")) g_name_dirty = true;
    if (g_name_dirty && !ImGui::IsItemActive()) { write_name(g_name); g_name_dirty = false; }

    int containers = __builtin_popcount(F<uint16_t>(CONTAINERS) & 0x1FF);
    if (slider("Heart containers", &containers, 0, 9)) F<uint16_t>(CONTAINERS) = (uint16_t)low_bits(containers);
    int pieces = __builtin_popcountll(F<uint64_t>(PIECES) & 0xFFFFFFFFull);
    if (slider("Pieces of heart", &pieces, 0, 32)) F<uint64_t>(PIECES) = low_bits(pieces);
    int mh = max_hp();
    int hp = F<int16_t>(HP);
    if (hp > mh) { hp = mh; F<int16_t>(HP) = (int16_t)hp; }
    float hearts = hp / 4.0f;
    ImGui::PushID("hp");
    label("Health");
    char fmt[64];
    snprintf(fmt, sizeof fmt, "%%.2f / %.0f hearts", mh / 4.0f);
    if (ImGui::SliderFloat("##hp", &hearts, 0.25f, mh / 4.0f, fmt, ImGuiSliderFlags_AlwaysClamp))
        F<int16_t>(HP) = (int16_t)fmaxf(1, roundf(hearts * 4));
    ImGui::PopID();
    int rupees = (int)F<uint32_t>(RUPEES);
    if (slider("Rupees", &rupees, 0, 999)) F<uint32_t>(RUPEES) = (uint32_t)rupees;
    int shells = __builtin_popcountll(F<uint64_t>(SHELLS) & low_bits(50));
    if (slider("Secret Seashells", &shells, 0, 50)) F<uint64_t>(SHELLS) = low_bits(shells);
    int leaves = __builtin_popcount(F<uint8_t>(LEAVES) & 0x1F);
    if (slider("Golden Leaves", &leaves, 0, 5)) F<uint8_t>(LEAVES) = (uint8_t)low_bits(leaves);
    {
        const char *tunics[] = {"Green", "Red", "Blue", "Red + Blue"};
        int t = (F<uint8_t>(UPGRADES) >> 6) & 3;
        ImGui::PushID("tunic");
        label("Tunics owned");
        if (ImGui::BeginCombo("##t", tunics[t])) {
            for (int i = 0; i < 4; i++)
                if (ImGui::Selectable(tunics[i], i == t)) F<uint8_t>(UPGRADES) = (uint8_t)((F<uint8_t>(UPGRADES) & 0x3F) | (i << 6));
            ImGui::EndCombo();
        }
        ImGui::PopID();
    }

    section("Equipment");
    static const char *sword[] = {"None", "Sword", "Level 2 Sword"};
    static const char *shield[] = {"None", "Shield", "Mirror Shield"};
    static const char *bracelet[] = {"None", "Power Bracelet", "Level 2 Bracelet"};
    level("Sword", 0, 0, sword);
    level("Shield", 1, 1, shield);
    level("Power Bracelet", 10, 2, bracelet);
    static const Bit items[] = {
        {"Bombs", ITEMS, 2, 32}, {"Bow", ITEMS, 3, 32}, {"Hookshot", ITEMS, 4, 32}, {"Boomerang", ITEMS, 5, 32},
        {"Magic Rod", ITEMS, 6, 32}, {"Shovel", ITEMS, 7, 32}, {"Magic Powder", ITEMS, 8, 32}, {"Roc's Feather", ITEMS, 9, 32},
        {"Pegasus Boots", ITEMS, 11, 32}, {"Ocarina", ITEMS, 12, 32}, {"Flippers", KEYITEMS, 0, 32},
        {"Secret Medicine", KEYITEMS, 1, 32}, {"Sleepy Toadstool", KEYITEMS, 15, 32}, {"Seashell Sensor", SENSOR, 0, 8},
    };
    ImGui::PushID("items");
    bit_grid(items, sizeof items / sizeof items[0], 3);
    ImGui::PopID();
    section("Ammo");
    bitbox("Bomb bag upgrade (60)", UPGRADES, 4, 8); ImGui::SameLine();
    bitbox("Quiver upgrade (60)", UPGRADES, 5, 8); ImGui::SameLine();
    bitbox("Powder upgrade (40)", UPGRADES, 3, 8);
    capacity("Bombs", BOMBS, 4, 30);
    capacity("Arrows", ARROWS, 5, 30);
    capacity("Magic Powder", POWDER, 3, 20);

    section("Ocarina songs");
    static const Bit songs[] = {{"Ballad of the Wind Fish", SONGS, 0, 8}, {"Manbo's Mambo", SONGS, 1, 8}, {"Frog's Song of Soul", SONGS, 2, 8}};
    ImGui::PushID("songs");
    bit_grid(songs, 3, 3);
    ImGui::PopID();

    section("Bottles");
    static const Bit bottles[] = {{"Bottle 1", ITEMS, 13, 32}, {"Bottle 2", ITEMS, 14, 32}, {"Bottle 3", ITEMS, 15, 32},
                                  {"Fairy in bottle 1", FAIRIES, 0, 8}, {"Fairy in bottle 2", FAIRIES, 1, 8}, {"Fairy in bottle 3", FAIRIES, 2, 8}};
    ImGui::PushID("bottles");
    bit_grid(bottles, 6, 3);
    ImGui::PopID();

    section("Instruments of the Sirens");
    static const Bit inst[] = {
        {"Full Moon Cello", KEYITEMS, 7, 32}, {"Conch Horn", KEYITEMS, 8, 32}, {"Sea Lily's Bell", KEYITEMS, 9, 32},
        {"Surf Harp", KEYITEMS, 10, 32}, {"Wind Marimba", KEYITEMS, 11, 32}, {"Coral Triangle", KEYITEMS, 12, 32},
        {"Evening Calm Organ", KEYITEMS, 13, 32}, {"Thunder Drum", KEYITEMS, 14, 32},
    };
    ImGui::PushID("inst");
    bit_grid(inst, 8, 4);
    ImGui::PopID();
    if (ImGui::Button("All instruments")) F<uint32_t>(KEYITEMS) |= 0x7F80;

    section("Dungeon keys");
    static const Bit keys[] = {{"Tail Key", KEYITEMS, 2, 32}, {"Slime Key", KEYITEMS, 3, 32}, {"Angler Key", KEYITEMS, 4, 32},
                               {"Face Key", KEYITEMS, 5, 32}, {"Bird Key", KEYITEMS, 6, 32}};
    ImGui::PushID("keys");
    bit_grid(keys, 5, 3);
    ImGui::PopID();

    section("Trading sequence");
    {
        static const char *trade[] = {"None", "Yoshi Doll", "Ribbon", "Dog Food", "Bananas", "Stick", "Honeycomb", "Pineapple",
                                      "Hibiscus", "Goat's Letter", "Broom", "Fishing Hook", "Necklace", "Mermaid's Scale",
                                      "Magnifying Lens"};
        int t = F<uint8_t>(TRADE);
        if (t > 14) t = 0;
        ImGui::PushID("trade");
        label("Current item");
        if (ImGui::BeginCombo("##tr", trade[t])) {
            for (int i = 0; i < 15; i++)
                if (ImGui::Selectable(trade[i], i == t)) F<uint8_t>(TRADE) = (uint8_t)i;
            ImGui::EndCombo();
        }
        ImGui::PopID();
    }
    section("Give any item");
    {   // the game's own AddItem (same path as an item pickup / Inventory.AddItemByKey event)
        static int item = 0, count = 1, index = -1;
        ImGui::PushID("give");
        label("Item");
        if (ImGui::BeginCombo("##item", kItemNames[item])) {
            for (int i = 0; i < (int)(sizeof kItemNames / sizeof kItemNames[0]); i++)
                if (ImGui::Selectable(kItemNames[i], i == item)) item = i;
            ImGui::EndCombo();
        }
        slider("Count", &count, 1, 99);
        label("Index (-1 = any)");
        ImGui::InputInt("##idx", &index);
        ImGui::Spacing();
        if (ImGui::Button("Give")) give_item_request(item, count, index);
        ImGui::SameLine();
        ImGui::TextDisabled("Heart pieces, seashells, golden leaves etc. use their index.");
        ImGui::PopID();
    }
    (void)scale;
    sync_header();
}

// ---- debug helpers (LARECOMP_SAVE_DUMP_AT=<frame>: log the live save at that frame)
extern "C" void save_editor_file_read(const char *path, uint64_t addr, int64_t off, int64_t size) {
    (void)path; (void)addr; (void)off; (void)size;
}

extern "C" void cheats_frame(void);      // cheats.mm
extern "C" void difficulty_frame(void);  // difficulty.mm
extern "C" void save_editor_frame(uint64_t frame) {
    cheats_frame();
    difficulty_frame();
    static int watch = -1;  // LARECOMP_WATCH_SAVE=<lo>,<hi> (save offsets): log code touching that range
    if (watch < 0) {
        watch = 0;
        unsigned lo, hi;
        if (ENV("LARECOMP_WATCH_SAVE") && sscanf(ENV("LARECOMP_WATCH_SAVE"), "%x,%x", &lo, &hi) == 2) {
            extern uint64_t g_watch_lo, g_watch_hi;
            g_watch_lo = LIVE_SAVE + lo;
            g_watch_hi = LIVE_SAVE + hi;
            extern void watch_arm(void);
            watch_arm();
        }
    }
    static long test_at = -2;  // LARECOMP_SAVE_MAX_AT=<frame>: press "Max out everything" (test hook)
    if (test_at == -2) test_at = getenv("LARECOMP_SAVE_MAX_AT") ? atol(getenv("LARECOMP_SAVE_MAX_AT")) : -1;
    if (test_at >= 0 && (long)frame == test_at && loaded()) {
        F<uint16_t>(CONTAINERS) = 0x1FF; F<uint64_t>(PIECES) = 0xFFFFFFFFull; F<uint32_t>(RUPEES) = 999;
        F<uint64_t>(SHELLS) = low_bits(50); F<uint8_t>(LEAVES) = 0x1F; F<uint32_t>(ITEMS) |= 0xFFFF; F<uint8_t>(UPGRADES) |= 0x3F;
        F<uint8_t>(BOMBS) = 60; F<uint8_t>(ARROWS) = 60; F<uint8_t>(POWDER) = 40; F<uint8_t>(SONGS) = 7;
        F<uint32_t>(KEYITEMS) |= 0x7FFF; F<uint8_t>(SENSOR) |= 1; F<int16_t>(HP) = (int16_t)max_hp();
        sync_header();
        LOG("[save] test: maxed out\n");
    }
    static long poke_done;  // LARECOMP_POKE_SAVE=off=val,...: write live-save bytes (hex offsets) once after load
    if (!poke_done && loaded() && ENV("LARECOMP_POKE_SAVE") && frame > 2600) {
        poke_done = 1;
        for (const char *p = ENV("LARECOMP_POKE_SAVE"); *p;) {
            unsigned off = 0, val = 0;
            if (sscanf(p, "%x=%x", &off, &val) == 2 && off < 0x5EE0) *(uint8_t *)(uintptr_t)(LIVE_SAVE + off) = (uint8_t)val;
            while (*p && *p != ',') p++;
            if (*p) p++;
        }
        LOG("[save] poked %s\n", ENV("LARECOMP_POKE_SAVE"));
    }
    if (loaded()) {  // LARECOMP_LOG_FLAGS: log event-flag bit changes; LARECOMP_SET_FLAGS=i,j,..: force those bits on
        static uint8_t prev[256];
        static bool have_prev;
        uint8_t *fl = (uint8_t *)(uintptr_t)(LIVE_SAVE + 0x5DC0);
        if (const char *sf = ENV("LARECOMP_SET_FLAGS")) {
            for (const char *p = sf; *p;) {
                int i = atoi(p);
                if (i >= 0 && i < 2048 && !(fl[i >> 3] & (1 << (i & 7)))) {
                    fl[i >> 3] |= (uint8_t)(1 << (i & 7));
                    LOG("[flags] forced %d on\n", i);
                }
                while (*p && *p != ',') p++;
                if (*p) p++;
            }
        }
        if (ENV("LARECOMP_LOG_FLAGS")) {
            if (have_prev)
                for (int i = 0; i < 2048; i++)
                    if ((fl[i >> 3] ^ prev[i >> 3]) & (1 << (i & 7)))
                        LOG("[flags] frame %lu: flag %d -> %d\n", (unsigned long)frame, i, (fl[i >> 3] >> (i & 7)) & 1);
            memcpy(prev, fl, 256);
            have_prev = true;
        }
    }
    if (ENV("LARECOMP_FIND_FLAGS") && frame == 3000) {  // locate the event-flag bitfield (ptr, byte capacity)
        for (uint64_t a = 0x7001C00000ull; a < 0x7001D00000ull; a += 8) {
            uint64_t v = *(uint64_t *)(uintptr_t)a;
            if (v >= LIVE_SAVE && v < LIVE_SAVE + 0x5EE0) {
                uint32_t cap = *(uint32_t *)(uintptr_t)(a + 8);
                if (cap > 16 && cap < 0x1000) LOG("[flags] ptr at %llx -> save+%#llx, next u32 %u\n", (unsigned long long)a,
                                                  (unsigned long long)(v - LIVE_SAVE), cap);
            }
        }
    }
    static long at = -2;
    if (at == -2) at = getenv("LARECOMP_SAVE_DUMP_AT") ? atol(getenv("LARECOMP_SAVE_DUMP_AT")) : -1;
    if (at < 0 || (long)frame != at) return;
    const uint8_t *L = S();
    LOG("[save] live: version %u name %c%c%c%c rupees %u health %d items %08x keys %08x\n", *(const uint32_t *)L, L[0x5388],
        L[0x538a], L[0x538c], L[0x538e], *(const uint32_t *)(L + RUPEES), *(const int16_t *)(L + HP),
        *(const uint32_t *)(L + ITEMS), *(const uint32_t *)(L + KEYITEMS));
}
