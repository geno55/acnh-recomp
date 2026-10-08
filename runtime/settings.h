// User settings (larecomp.ini next to the executable's working directory), edited from the in-game menu.
#pragma once
#include <stdbool.h>

enum { ASPECT_UNLOCKED = 0, ASPECT_ORIGINAL = 1 };

typedef struct {
    int aspect;          // ASPECT_*: unlocked = fill the window (wider/taller views), original = 16:9 with bars
    bool fullscreen;
    float volume;        // master volume, 1 = 100%
    bool reverb;         // room reverb effect
    bool movie_audio;
    bool show_fps;
    bool inv_keys;       // randomizer: show every dungeon's keys on the pause menu's Items page
    bool tracker;        // randomizer: check tracker on the pause menu's Map page
    // cheats (runtime/ui/cheats.mm), applied every frame while a save is loaded
    bool cheat_hearts;   // health kept full
    bool cheat_ammo;     // bombs / arrows / magic powder kept full (for the bags Link owns)
    bool cheat_rupees;   // rupees kept at 999
    // difficulty (runtime/ui/difficulty.mm)
    float diff_damage;   // damage taken multiplier (1 = normal)
    bool diff_ohko;      // any hit kills
    bool diff_hero;      // Hero Mode flag forced on in the loaded save (2x damage, no recovery hearts)
    char rando_seed[128];  // active randomizer seed (rando/<name>/), empty = vanilla
} Settings;

extern Settings g_settings;

void settings_load(void);
void settings_save(void);
