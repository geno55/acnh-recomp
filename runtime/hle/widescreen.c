// Widescreen: the camera code's 16:9 aspect literal loads are patched (tools/patches.py) to call
// rt_aspect_site(); the renderer sets the wide factor (output aspect / 16:9) each frame.
#include <stdbool.h>
#include <stdlib.h>

#include "../hle.h"

static float g_wide = 1.0f;  // output aspect divided by 16:9 (1 = normal)

void widescreen_set_factor(float f) { g_wide = f; }
float widescreen_factor(void) { return g_wide; }

// Off in rooms that should keep 16:9 framing (interiors, dungeons) -- see widescreen_update.
static bool g_allowed = true;
bool widescreen_allowed(void) { return g_allowed && !getenv("LARECOMP_NO_WIDESCREEN"); }
void widescreen_set_allowed(bool on) { g_allowed = on; }

float rt_aspect_site(int site) {
    static long mask = -2;
    if (mask == -2) mask = getenv("LARECOMP_ASPECT_SITES") ? strtol(getenv("LARECOMP_ASPECT_SITES"), NULL, 0) : -1;
    float base = 16.0f / 9.0f;
    if (mask != -1 && !(mask & (1L << site))) return base;
    return base * g_wide;
}
