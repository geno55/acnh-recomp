// Mirror mode (Gameplay tab, g_settings.mirror_mode): the world is shown mirrored left to right, the HUD and menus
// aren't. Each frame the game composites its finished scene into the window image with one unblended full-screen
// draw that samples a window-sized image, then draws the HUD on top (blended); the renderers (runtime/nvn/renderer.m,
// vulkan/exec.c) mirror that composite (ShaderKey flip_x). While the mirrored world is on screen the stick and d-pad
// swap left and right (runtime/hle/input.c); the pause menu shows no composite (its backdrop is a small blurred copy),
// so there they don't.
#include <stdbool.h>
#include <stdint.h>

#include "../settings.h"

uint64_t renderer_present_count(void);

static uint64_t g_world_frame = ~0ull;  // the mirrored scene was drawn

// The renderer found the scene composite (composite): mirror it?
bool mirror_draw(bool composite) {
    if (!g_settings.mirror_mode || !composite) return false;
    g_world_frame = renderer_present_count();
    return true;
}

// The stick / d-pad swap left and right: mirror mode and the mirrored world on screen (this frame or the last two).
bool mirror_input(void) {
    return g_settings.mirror_mode && g_world_frame != ~0ull && renderer_present_count() - g_world_frame <= 2;
}
