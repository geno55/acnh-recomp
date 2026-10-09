// Difficulty tab: damage taken multiplier / one-hit KO (applied where the game computes Link's damage, see
// tools/patches.py DAMAGE_*_SITES) and the game's own Hero Mode flag (PlayerStatus+0x120 = save 0x55E0: double
// damage and no recovery hearts from enemies, grass or pots). Settings persist in larecomp.ini (g_settings.diff_*).
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../settings.h"
int game_in_play(void);
}

#define LIVE_SAVE 0x7001CBB220ull
#define HERO_FLAG (LIVE_SAVE + 0x55E0)  // PlayerStatus (save+0x54C0) + 0x120

extern "C" int rt_hero_mode(void) { return *(volatile uint8_t *)(uintptr_t)HERO_FLAG == 1; }

// damage in quarter hearts before the Hero Mode shift; returns the damage to subtract
extern "C" int32_t rt_damage(int32_t dmg, int32_t shift) {
    static int envd = -1;  // LARECOMP_DAMAGE=<mult> / ohko: test override
    if (envd < 0) {
        const char *e = getenv("LARECOMP_DAMAGE");
        envd = e != NULL;
        if (e) {
            if (!strcmp(e, "ohko")) g_settings.diff_ohko = true;
            else g_settings.diff_damage = (float)atof(e);
        }
    }
    int32_t base = dmg << (shift & 31);
    if (base <= 0) return base;  // healing / zero: untouched
    if (g_settings.diff_ohko) return 999;
    float m = g_settings.diff_damage > 0 ? g_settings.diff_damage : 1.0f;
    int32_t r = (int32_t)lroundf((float)base * m);
    if (ENV("LARECOMP_LOG_DAMAGE")) LOG("[difficulty] damage %d (shift %d) -> %d\n", dmg, shift, r < 1 ? 1 : r);
    return r < 1 ? 1 : r;  // at least a quarter heart
}

// Once per presented frame (from save_editor_frame).
extern "C" void difficulty_frame(void) {
    if (!game_in_play()) return;
    if (g_settings.diff_hero && *(uint8_t *)(uintptr_t)HERO_FLAG != 1) *(uint8_t *)(uintptr_t)HERO_FLAG = 1;
}

static void preset(const char *name, float dmg, bool ohko, bool hero, const char *desc) {
    bool on = fabsf(g_settings.diff_damage - dmg) < 0.01f && g_settings.diff_ohko == ohko && g_settings.diff_hero == hero;
    if (on) ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
    if (ImGui::Button(name, ImVec2(160, 0))) {
        g_settings.diff_damage = dmg;
        g_settings.diff_ohko = ohko;
        g_settings.diff_hero = hero;
        settings_save();
    }
    if (on) ImGui::PopStyleColor();
    ImGui::SameLine();
    ImGui::TextDisabled("%s", desc);
}

extern "C" void difficulty_draw(float scale) {
    (void)scale;
    ImGui::SeparatorText("Presets");
    preset("Easy", 0.5f, false, false, "half damage");
    preset("Normal", 1.0f, false, false, "the game as designed");
    preset("Hard", 2.0f, false, false, "double damage, recovery hearts still drop");
    preset("Hero", 1.0f, false, true, "the game's Hero Mode: double damage, no recovery hearts");
    preset("Brutal", 2.0f, false, true, "Hero Mode + double damage (4x)");
    preset("One hit", 1.0f, true, false, "any hit is fatal");
    ImGui::Spacing();
    ImGui::SeparatorText("Custom");
    float d = g_settings.diff_damage;
    ImGui::SetNextItemWidth(320);
    if (ImGui::SliderFloat("Damage taken", &d, 0.25f, 4.0f, "%.2fx")) {
        g_settings.diff_damage = roundf(d * 4) / 4;
        settings_save();
    }
    if (ImGui::Checkbox("One-hit KO", &g_settings.diff_ohko)) settings_save();
    if (ImGui::Checkbox("Hero Mode", &g_settings.diff_hero)) settings_save();
    ImGui::SameLine();
    ImGui::TextDisabled("(sets the loaded save's Hero Mode flag; turning this off leaves the save as it is)");
    if (game_in_play() && !g_settings.diff_hero && rt_hero_mode()) {
        if (ImGui::Button("Turn Hero Mode off for this save")) *(uint8_t *)(uintptr_t)HERO_FLAG = 0;
    }
    ImGui::Spacing();
    ImGui::TextDisabled("Damage is rounded to quarter hearts (at least 1/4 heart per hit).");
}
