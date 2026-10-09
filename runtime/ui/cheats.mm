// Cheats tab: toggles applied to the live save every frame while a save is loaded (layout: notes/save_format.md),
// plus one-shot buttons. Settings persist in larecomp.ini (g_settings.cheat_*).
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../settings.h"
int game_in_play(void);
}

#define LIVE_SAVE 0x7001CBB220ull  // main + 0x1CBB220
template <typename T> static T &F(uint32_t off) { return *(T *)(uintptr_t)(LIVE_SAVE + off); }

enum : uint32_t {
    RUPEES = 0x5540, HP = 0x5544, PIECES = 0x5550, CONTAINERS = 0x5558, UPGRADES = 0x555C, BOMBS = 0x555E,
    ARROWS = 0x555F, POWDER = 0x5560, ITEMS = 0x5568,
};

static int max_hp(void) {  // quarter-hearts, as GetMaxHealth() computes it
    return 12 + 4 * (__builtin_popcount(F<uint16_t>(CONTAINERS) & 0x1FF) + __builtin_popcountll(F<uint64_t>(PIECES)) / 4);
}

static void fill_ammo(uint32_t count_off, int item_bit, int up_bit, int base_cap) {
    if (!((F<uint32_t>(ITEMS) >> item_bit) & 1)) return;  // only bags Link owns
    int cap = ((F<uint8_t>(UPGRADES) >> up_bit) & 1) ? base_cap * 2 : base_cap;
    if (F<uint8_t>(count_off) != cap) F<uint8_t>(count_off) = (uint8_t)cap;
}

// Once per presented frame (render thread), from save_editor_frame.
extern "C" void cheats_frame(void) {
    if (!game_in_play()) return;
    static int env = -1;  // LARECOMP_CHEATS=hearts,ammo,rupees: force on for tests (not saved)
    if (env < 0) {
        const char *e = getenv("LARECOMP_CHEATS");
        env = e != NULL;
        if (e) {
            g_settings.cheat_hearts |= strstr(e, "hearts") != NULL;
            g_settings.cheat_ammo |= strstr(e, "ammo") != NULL;
            g_settings.cheat_rupees |= strstr(e, "rupees") != NULL;
        }
    }
    if (g_settings.cheat_hearts) {
        int m = max_hp();
        if (F<int16_t>(HP) > 0 && F<int16_t>(HP) < m) F<int16_t>(HP) = (int16_t)m;  // (0 = dying/respawning: leave it)
    }
    if (g_settings.cheat_ammo) {
        fill_ammo(BOMBS, 2, 4, 30);
        fill_ammo(ARROWS, 3, 5, 30);
        fill_ammo(POWDER, 8, 3, 20);
    }
    if (g_settings.cheat_rupees && F<uint32_t>(RUPEES) != 999) F<uint32_t>(RUPEES) = 999;
}

static bool toggle(const char *label, const char *desc, bool *v) {
    bool changed = ImGui::Checkbox(label, v);
    ImGui::SameLine();
    ImGui::TextDisabled("%s", desc);
    if (changed) settings_save();
    return changed;
}

extern "C" void cheats_draw(float scale) {
    (void)scale;
    if (!game_in_play()) {
        ImGui::TextDisabled("Load a save file and get into the game to use cheats.");
        return;
    }
    ImGui::SeparatorText("Always on (saved)");
    toggle("Infinite hearts", "health refills to full", &g_settings.cheat_hearts);
    toggle("Infinite ammo", "bombs, arrows and magic powder stay full (for bags you own)", &g_settings.cheat_ammo);
    toggle("Infinite rupees", "999 rupees", &g_settings.cheat_rupees);
    toggle("Hookshot anything", "latches onto any wall or object (seeds made with it: on)", &g_settings.cheat_hookshot);
    ImGui::Spacing();
    ImGui::SeparatorText("One-time");
    if (ImGui::Button("Max hearts (20)")) {
        F<uint16_t>(CONTAINERS) = 0x1FF;
        F<uint64_t>(PIECES) = 0xFFFFFFFFull;
        F<int16_t>(HP) = (int16_t)max_hp();
    }
    ImGui::SameLine();
    if (ImGui::Button("Refill hearts")) F<int16_t>(HP) = (int16_t)max_hp();
    ImGui::SameLine();
    if (ImGui::Button("Max capacity (bombs/arrows/powder)")) {
        F<uint8_t>(UPGRADES) |= 0x38;  // bits 3-5: powder 40, bombs 60, arrows 60
        fill_ammo(BOMBS, 2, 4, 30);
        fill_ammo(ARROWS, 3, 5, 30);
        fill_ammo(POWDER, 8, 3, 20);
    }
    ImGui::Spacing();
    ImGui::SeparatorText("Companion");
    {  // save+0x555D: the follower (verified: setting it spawns that companion at the next screen / room load)
        static const char *names[] = {"None", "BowWow", "Marin", "Ghost", "Flying Rooster"};
        int cur = F<uint8_t>(0x555D);
        if (cur < 0 || cur > 4) cur = 0;
        ImGui::SetNextItemWidth(260);
        if (ImGui::Combo("##companion", &cur, names, 5)) F<uint8_t>(0x555D) = (uint8_t)cur;
        ImGui::SameLine();
        ImGui::TextDisabled("joins at the next screen change; story events may expect a specific companion");
    }
    ImGui::Spacing();
    ImGui::TextDisabled("Items, songs, instruments and anything else: Save Editor tab (incl. \"Give any item\").");
}
