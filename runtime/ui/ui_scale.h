// Per-OS text size for the start screen. Layout scales with the window, but the default window covers far less
// of a typical Windows monitor (100% scaling, e.g. 5120x1440) than of a Retina Mac, so text reads smaller there.
// macOS is the reference (1.0). LARECOMP_UI_TEXT_SCALE=<factor> overrides for tuning.
#pragma once
#include <stdlib.h>

#ifdef _WIN32
#define UI_TEXT_SCALE_DEFAULT 1.5f
#else
#define UI_TEXT_SCALE_DEFAULT 1.0f
#endif

static inline float ui_text_scale(void) {
    static float s = -1;
    if (s < 0) {
        const char *e = getenv("LARECOMP_UI_TEXT_SCALE");
        s = e ? (float)atof(e) : UI_TEXT_SCALE_DEFAULT;
        if (s <= 0) s = UI_TEXT_SCALE_DEFAULT;
    }
    return s;
}
